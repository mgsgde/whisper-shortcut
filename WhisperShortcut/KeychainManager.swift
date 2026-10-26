import Foundation
import Security

// Protocol for dependency injection and testing.
//
// Every credential goes through the same four operations keyed by `KeychainCredential`, so a
// newly added secret gets the full lifecycle (save/read/delete/presence) for free.
extension KeychainManaging {
  /// Default for implementations without a cache.
  func getUncached(_ credential: KeychainCredential) -> String? { get(credential) }
}

protocol KeychainManaging {
  func save(_ value: String, for credential: KeychainCredential) -> Bool
  func get(_ credential: KeychainCredential) -> String?
  /// Like `get`, but skips the in-memory cache and re-reads the Keychain item. For credentials a
  /// second process may rotate (the ChatGPT plan refresh token).
  func getUncached(_ credential: KeychainCredential) -> String?
  @discardableResult func delete(_ credential: KeychainCredential) -> Bool
  /// True when an item exists, without reading its data.
  func has(_ credential: KeychainCredential) -> Bool
  /// True when a stored value exists *and* is non-empty. Reads the value, so prefer `has` when
  /// only presence matters.
  func hasNonEmpty(_ credential: KeychainCredential) -> Bool

  /// A secret addressed by a raw Keychain account name. IMAP passwords use `imap:` plus the email.
  /// Same cache, lock, accessibility class, and update-then-add path as the typed credentials.
  func saveSecret(_ value: String, account: String) -> Bool
  func secret(account: String) -> String?
  @discardableResult func deleteSecret(account: String) -> Bool

  // The custom-transcription headers are the one credential with a shape of its own (a JSON
  // array), so they keep dedicated accessors on top of the generic string storage.
  func saveCustomTranscriptionHeaders(_ headers: [[String: String]]) -> Bool
  func getCustomTranscriptionHeaders() -> [[String: String]]
}

class KeychainManager: KeychainManaging {
  static let shared = KeychainManager()

  // MARK: - Constants
  private enum Constants {
    static let serviceName = "com.whispershortcut.openai"
  }

  // MARK: - In-memory cache
  //
  // `SecItemCopyMatching` is a synchronous mach IPC round-trip to `securityd`
  // that can block for seconds. Many `hasValid*` / `get*` calls run straight
  // from SwiftUI view bodies and `.onAppear` (model pickers, credential
  // badges), so an uncached read on the main thread wedges the UI — observed
  // as a hang (hang-20260619-090717.txt: SecItemCopyMatching under
  // `_AppearanceActionModifier` on the main thread).
  //
  // We therefore memoize BOTH hits and misses. The previous cache stored only
  // hits, so an *unconfigured* provider (xAI/OpenAI for many users) re-queried
  // securityd on every single call. `knownAbsentAccounts` caches the misses;
  // `valueCache` / `knownPresentAccounts` cache the hits. All app writes go
  // through `saveKey`/`deleteKey`, which keep the cache coherent. A lock guards
  // it because `.shared` is read from background tasks (chat providers) as well
  // as the main thread.
  private let lock = NSLock()
  private var valueCache: [String: String] = [:]
  private var knownPresentAccounts: Set<String> = []
  private var knownAbsentAccounts: Set<String> = []

  private let store: KeychainItemStore
  /// nil = probe the real keychain (`dataProtectionAvailable`). Tests pin it.
  private let dataProtectionOverride: Bool?

  init(store: KeychainItemStore = SystemKeychainItemStore(), dataProtection: Bool? = nil) {
    self.store = store
    self.dataProtectionOverride = dataProtection
  }

  // MARK: - Storage backend
  //
  // Items live in the *data protection* keychain (`kSecUseDataProtectionKeychain`), not the legacy
  // file-based login keychain. The legacy keychain keys its ACL to the individual signed binary,
  // so every rebuild, Developer ID build or App Store build is a "different app" and the user got
  // "WhisperShortcut wants to use your confidential information" password prompts again and again.
  // The data protection keychain keys access on the keychain access group instead
  // (`TeamID.bundleID`, from the `keychain-access-groups` entitlement), which Debug, Developer ID
  // and App Store builds of the same team share, so no per-binary prompts.
  //
  // Existing items are migrated lazily and once per item: the first `readSecret` that misses in the
  // data protection store reads the legacy item and copies it over. That legacy read may show the
  // ACL prompt one final time per item.
  //
  // `migrateLegacyItemsIfNeeded` runs that migration eagerly for every legacy item once at launch,
  // so the user sees one burst of prompts at the first launch after the update and never again,
  // instead of scattered prompts as each credential is first used.
  //
  // The legacy copy is deliberately KEPT, and nothing but an explicit user delete (`deleteItem`)
  // ever deletes from the legacy store. Two reasons:
  // - On macOS a `SecItemDelete` without `kSecUseDataProtectionKeychain` also deletes the matching
  //   data protection item. Measured on 2026-10-19 in keychain-2.db: every migrated or freshly saved
  //   item was added and then removed in the very next commit by the "legacy cleanup" delete, so
  //   the migration wiped the API keys from both stores.
  // - Builds without the entitlement (older versions after a downgrade, ad-hoc builds, the test
  //   host) read only the legacy store. Keeping it lets them still find the keys.
  // A stale legacy copy is harmless: reads check the data protection store first and migrate only
  // when it has no item, so a legacy value never overwrites a newer one.
  //
  // Builds without the entitlement (ad-hoc signed builds, the test host, an App Store build without
  // it) get errSecMissingEntitlement (-34018) from data protection writes. `dataProtectionAvailable`
  // checks for the entitlement once and falls back to the legacy keychain for the whole process, so
  // those builds behave as before.
  //
  // The check reads the entitlement itself. A read-only probe is not enough: the App Store test host
  // (no keychain-access-groups) got errSecItemNotFound from a data protection READ, took the data
  // protection path, and then every WRITE failed with -34018 (measured 2026-10-19), so a key saved
  // in such a build would not survive a restart.
  private static let dataProtectionAvailable: Bool = {
    // static let: initialised exactly once, thread-safely, on first use.
    let groups = SecTaskCreateFromSelf(nil).flatMap {
      SecTaskCopyValueForEntitlement($0, "keychain-access-groups" as CFString, nil) as? [String]
    }
    guard let groups, !groups.isEmpty else {
      DebugLogger.log("KEYCHAIN: build lacks keychain-access-groups entitlement; using the legacy login keychain")
      return false
    }
    return true
  }()

  private var usesDataProtection: Bool { dataProtectionOverride ?? Self.dataProtectionAvailable }

  // MARK: - Test/dev credential injection
  //
  // Live roundtrip tests (and headless CI) must reach real provider APIs
  // without touching the login Keychain. The `xctest` binary is a *different*
  // signed executable than the trusted app, so any Keychain read from a test
  // pops the macOS "WhisperShortcut wants to use your confidential
  // information" ACL prompt. When one of these environment variables is set,
  // it takes precedence and the Keychain is never queried for that account.
  //
  // Each account accepts the project's `WHISPERSHORTCUT_*` name first, then the provider's
  // conventional name (OPENAI_API_KEY, XAI_API_KEY, …), and finally the same names read from the
  // gitignored `.env` at the repo root.
  //
  // The `.env` fallback is what actually makes this work under `xcodebuild test`. `run-tests.sh`
  // exports the keys before invoking xcodebuild, but the test host does **not** inherit the calling
  // shell's environment — measured: with all four keys exported, `ProcessInfo.environment` inside a
  // test saw none of them. Neither `inheritEnvironmentVariables` in the test plan nor xcodebuild's
  // `TEST_RUNNER_`-prefixed settings changed that. The failure was silent in the worst way: the live
  // roundtrip tests are `.enabled(if: hasNonEmpty(...))`, so instead of failing they quietly
  // *skipped*, and only passed on a developer machine because the keys happened to be in that
  // machine's login Keychain. On CI or a fresh checkout the provider roundtrips covered nothing.
  //
  // Gated to DEBUG so the shipped Release build never reads either source; GUI launches don't
  // inherit a shell environment anyway, so this is inert in production.
  //
  // The variable names live on `KeychainCredential.environmentVariableNames`.
  private func environmentOverride(for credential: KeychainCredential) -> String? {
    #if DEBUG
    let env = ProcessInfo.processInfo.environment
    for name in credential.environmentVariableNames {
      if let value = env[name], !value.isEmpty { return value }
    }
    let dotEnv = Self.dotEnvValues
    for name in credential.environmentVariableNames {
      if let value = dotEnv[name], !value.isEmpty { return value }
    }
    return nil
    #else
    return nil
    #endif
  }

  #if DEBUG
  /// Key/value pairs from the gitignored `.env` at the repo root, parsed once.
  ///
  /// The repo root is derived from this file's compile-time path rather than the working directory,
  /// which under `xcodebuild test` is not the checkout. Empty when the file is absent — a machine
  /// without `.env` still falls through to the Keychain, and a test whose provider key is missing
  /// everywhere still skips rather than failing.
  private static let dotEnvValues: [String: String] = {
    let repoRoot = URL(fileURLWithPath: #filePath)   // …/WhisperShortcut/KeychainManager.swift
      .deletingLastPathComponent()                    // …/WhisperShortcut
      .deletingLastPathComponent()                    // repo root
    guard let contents = try? String(contentsOf: repoRoot.appendingPathComponent(".env"), encoding: .utf8)
    else { return [:] }

    var result: [String: String] = [:]
    for rawLine in contents.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#"),
            let separator = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
      var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      // Tolerate quoted values — `KEY="sk-..."` is a normal way to write a .env line.
      if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\""))
          || (value.hasPrefix("'") && value.hasSuffix("'")) {
        value = String(value.dropFirst().dropLast())
      }
      guard !key.isEmpty, !value.isEmpty else { continue }
      result[key] = value
    }
    return result
  }()
  #endif

  // MARK: - Credential Storage
  //
  // These four operations are the entire public surface. Each one derives the Keychain account
  // name from the credential, so the account strings exist in exactly one place
  // (`KeychainCredential`).

  func save(_ value: String, for credential: KeychainCredential) -> Bool {
    writeSecret(value, account: credential.accountName)
  }

  func saveSecret(_ value: String, account: String) -> Bool {
    writeSecret(value, account: account)
  }

  /// Marks `account` present in the cache with `value`: lock, write `valueCache` /
  /// `knownPresentAccounts` / `knownAbsentAccounts`, unlock. Every path that just confirmed or
  /// obtained a Keychain item's value (a successful write, a successful read, a migrated-on-read
  /// item, the eager legacy migration sweep) repeated this same four-line block (R85).
  private func cachePresent(_ account: String, _ value: String) {
    lock.lock()
    valueCache[account] = value
    knownPresentAccounts.insert(account)
    knownAbsentAccounts.remove(account)
    lock.unlock()
  }

  private func writeSecret(_ value: String, account accountName: String) -> Bool {
    guard let data = value.data(using: .utf8) else {
      return false
    }

    // ThisDeviceOnly so a Keychain dump / iCloud Keychain sync cannot take the
    // API keys off this Mac. Included on UPDATE as well as add so items written
    // before this accessibility class are repaired in place rather than left
    // at the older AfterFirstUnlock (syncable) class forever.
    let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    // Update-in-place first, add only if the item doesn't exist yet. The previous
    // delete-then-add sequence was destructive: when SecItemAdd failed (locked/broken
    // login keychain, sandbox denial), the old key was already deleted — observed in the
    // wild as "my API keys disappear".
    let status = upsert(account: accountName, data: data, accessibility: accessibility, updateFirst: true)

    // No legacy cleanup here: an unflagged delete would take this new data protection item with
    // it (see "Storage backend"). A stale legacy copy is never migrated over an existing item.

    // Cache the value even when persisting failed: the key then still works for this
    // session (the UI warns that it won't survive a restart) instead of vanishing.
    cachePresent(accountName, value)
    lock.lock()
    if status == errSecSuccess {
      lastWriteErrors.removeValue(forKey: accountName)
    } else {
      lastWriteErrors[accountName] = status
    }
    lock.unlock()
    if status != errSecSuccess {
      DebugLogger.logError("KEYCHAIN: save failed for account \(accountName): status=\(status)")
    }
    return status == errSecSuccess
  }

  /// Writes `data` to `account`'s Keychain item, trying one order (update vs. add) first and
  /// falling back to the other if that attempt reports the item in the opposite state. Both
  /// `writeSecret` and `migrateLegacyItem` had their own copy-pasted two-call sequence (R85).
  /// `updateFirst: true` (writeSecret's hot path: the item usually already exists) tries
  /// `SecItemUpdate` then `SecItemAdd` on `errSecItemNotFound`; `updateFirst: false`
  /// (`migrateLegacyItem`: the item is being copied in for the first time, so it usually does
  /// *not* exist yet) tries `SecItemAdd` then `SecItemUpdate` on `errSecDuplicateItem`.
  private func upsert(account accountName: String, data: Data, accessibility: CFString, updateFirst: Bool) -> OSStatus {
    let match = itemQuery(account: accountName)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: accessibility,
    ]
    func update() -> OSStatus { store.update(match, attributes) }
    func add() -> OSStatus {
      var attrs = match
      attrs[kSecValueData as String] = data
      attrs[kSecAttrAccessible as String] = accessibility
      return store.add(attrs)
    }
    if updateFirst {
      var status = update()
      if status == errSecItemNotFound { status = add() }
      return status
    } else {
      var status = add()
      if status == errSecDuplicateItem { status = update() }
      return status
    }
  }

  /// OSStatus of the most recent failed write per account, cleared on the next successful
  /// write. Lets the settings UI tell the user their key could NOT be stored (broken login
  /// keychain etc.) instead of silently losing it.
  private var lastWriteErrors: [String: OSStatus] = [:]

  func lastWriteError(for credential: KeychainCredential) -> OSStatus? {
    lock.lock(); defer { lock.unlock() }
    return lastWriteErrors[credential.accountName]
  }

  func get(_ credential: KeychainCredential) -> String? {
    if let injected = environmentOverride(for: credential) { return injected }
    return readSecret(account: credential.accountName)
  }

  func getUncached(_ credential: KeychainCredential) -> String? {
    if let injected = environmentOverride(for: credential) { return injected }
    return readSecret(account: credential.accountName, bypassCache: true)
  }

  func secret(account: String) -> String? {
    readSecret(account: account)
  }

  private func readSecret(account accountName: String, bypassCache: Bool = false) -> String? {

    if !bypassCache {
      lock.lock()
      if let cached = valueCache[accountName] { lock.unlock(); return cached }
      if knownAbsentAccounts.contains(accountName) { lock.unlock(); return nil }
      lock.unlock()
    }

    var query = itemQuery(account: accountName)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = store.copyMatching(query, &result)

    if status == errSecSuccess, let data = result as? Data,
      let apiKey = String(data: data, encoding: .utf8)
    {
      cachePresent(accountName, apiKey)
      return apiKey
    } else {
      if status == errSecItemNotFound {
        if usesDataProtection, let migrated = migrateLegacyItem(account: accountName) {
          cachePresent(accountName, migrated)
          return migrated
        }
        lock.lock()
        knownAbsentAccounts.insert(accountName)
        valueCache.removeValue(forKey: accountName)
        knownPresentAccounts.remove(accountName)
        lock.unlock()
      } else {
        DebugLogger.logError("KEYCHAIN: SecItemCopyMatching failed for account \(accountName): status=\(status)")
      }
      return nil
    }
  }

  /// Eagerly migrates every legacy item for our service. Listing uses attributes only (no prompt);
  /// each `migrateLegacyItem` read may prompt once. No-op in builds that use the legacy keychain.
  func migrateLegacyItemsIfNeeded() {
    guard usesDataProtection else { return }
    let list: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Constants.serviceName,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnAttributes as String: true,
    ]
    var result: AnyObject?
    let status = store.copyMatching(list, &result)
    if status != errSecSuccess {
      if status != errSecItemNotFound {
        DebugLogger.logError("KEYCHAIN: legacy listing failed: status=\(status)")
      }
      return
    }
    guard let items = result as? [[String: Any]] else { return }

    var migrated = 0
    var alreadyPresent = 0
    for item in items {
      guard let account = item[kSecAttrAccount as String] as? String else { continue }
      var exists = itemQuery(account: account)
      exists[kSecReturnAttributes as String] = true
      exists[kSecMatchLimit as String] = kSecMatchLimitOne
      var existing: AnyObject?
      if store.copyMatching(exists, &existing) == errSecSuccess {
        // Already in the new store: never migrate the (possibly stale) legacy copy over it, and
        // never delete it either (an unflagged delete also removes the new item).
        alreadyPresent += 1
        continue
      }
      if let value = migrateLegacyItem(account: account) {
        cachePresent(account, value)
        migrated += 1
      }
    }
    DebugLogger.log("KEYCHAIN: legacy migration: \(migrated) migrated, \(alreadyPresent) already present")
  }

  /// One-time move of an item from the legacy login keychain into the data protection keychain.
  /// Returns the legacy value (also when the copy failed, so the key still works this session),
  /// or nil when the legacy store has no such item. The legacy copy stays: deleting it would also
  /// delete the item just written (see "Storage backend"), and older builds still read it.
  private func migrateLegacyItem(account accountName: String) -> String? {
    var query = itemQuery(account: accountName, legacy: true)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let readStatus = store.copyMatching(query, &result)
    guard readStatus == errSecSuccess, let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      if readStatus != errSecItemNotFound {
        DebugLogger.logError("KEYCHAIN: legacy read failed for account \(accountName): status=\(readStatus)")
      }
      return nil
    }

    let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    // Add-first: unlike writeSecret's hot path, this item is being copied in from the legacy
    // store for the first time, so it is not expected to exist yet in the data protection store.
    let writeStatus = upsert(account: accountName, data: data, accessibility: accessibility, updateFirst: false)
    if writeStatus == errSecSuccess {
      DebugLogger.log("KEYCHAIN: migrated account \(accountName) to the data protection keychain")
    } else {
      DebugLogger.logError(
        "KEYCHAIN: migration write failed for account \(accountName): status=\(writeStatus); legacy item kept")
    }
    return value
  }

  @discardableResult
  func delete(_ credential: KeychainCredential) -> Bool {
    deleteItem(account: credential.accountName)
  }

  @discardableResult
  func deleteSecret(account: String) -> Bool {
    deleteItem(account: account)
  }

  private func deleteItem(account accountName: String) -> Bool {
    // The one place that deletes from the legacy store: the user removed the key, so it must go
    // from both stores, or the next read would migrate the legacy copy back. (The unflagged legacy
    // delete may already remove the data protection item too; the flagged delete covers the rest.)
    if usesDataProtection {
      store.delete(itemQuery(account: accountName, legacy: true))
    }
    let status = store.delete(itemQuery(account: accountName))
    lock.lock()
    valueCache.removeValue(forKey: accountName)
    knownPresentAccounts.remove(accountName)
    knownAbsentAccounts.insert(accountName)
    lock.unlock()
    return status == errSecSuccess || status == errSecItemNotFound
  }

  func has(_ credential: KeychainCredential) -> Bool {
    let accountName = credential.accountName
    lock.lock()
    if knownPresentAccounts.contains(accountName) || valueCache[accountName] != nil {
      lock.unlock(); return true
    }
    if knownAbsentAccounts.contains(accountName) { lock.unlock(); return false }
    lock.unlock()

    // Check if key exists in keychain without reading the data
    var query = itemQuery(account: accountName)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    var status = store.copyMatching(query, &result)
    if status == errSecItemNotFound && usesDataProtection {
      // Not migrated yet? An attributes-only legacy query never touches the secret data, so it
      // does not trigger the ACL prompt. The actual migration happens on the next read.
      var legacy = itemQuery(account: accountName, legacy: true)
      legacy[kSecReturnAttributes as String] = true
      legacy[kSecMatchLimit as String] = kSecMatchLimitOne
      status = store.copyMatching(legacy, &result)
    }
    lock.lock()
    if status == errSecSuccess {
      knownPresentAccounts.insert(accountName)
    } else if status == errSecItemNotFound {
      knownAbsentAccounts.insert(accountName)
    }
    lock.unlock()
    return status == errSecSuccess
  }

  /// `legacy: true` targets the old file-based login keychain (migration and `deleteItem` only).
  /// Beware: on macOS such an unflagged query is not confined to the legacy store for deletes. No
  /// `kSecAttrAccessGroup`: the default is the first group of the entitlement.
  private func itemQuery(account accountName: String, legacy: Bool = false) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Constants.serviceName,
      kSecAttrAccount as String: accountName,
    ]
    if usesDataProtection && !legacy {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    return query
  }

  // MARK: - Custom Transcription Headers
  //
  // The only credential that isn't a bare string: a JSON array of header dictionaries, stored
  // as its serialized form.

  func saveCustomTranscriptionHeaders(_ headers: [[String: String]]) -> Bool {
    guard let data = try? JSONEncoder().encode(headers),
          let jsonString = String(data: data, encoding: .utf8) else {
      return false
    }
    return save(jsonString, for: .customTranscriptionHeaders)
  }

  func getCustomTranscriptionHeaders() -> [[String: String]] {
    guard let jsonString = get(.customTranscriptionHeaders),
          let data = jsonString.data(using: .utf8),
          let headers = try? JSONDecoder().decode([[String: String]].self, from: data) else {
      return []
    }
    return headers
  }

  // MARK: - Convenience

  /// True when the credential is stored *and* non-empty. Most callers care about this rather
  /// than bare presence — an empty string in the Keychain is not a usable key.
  func hasNonEmpty(_ credential: KeychainCredential) -> Bool {
    guard let value = get(credential) else { return false }
    return !value.isEmpty
  }
}

// MARK: - SecItem seam

/// The four `SecItem*` calls `KeychainManager` makes, so tests can substitute a store that models
/// how macOS routes queries between the legacy and the data protection keychain.
protocol KeychainItemStore {
  func copyMatching(_ query: [String: Any], _ result: inout AnyObject?) -> OSStatus
  func add(_ attributes: [String: Any]) -> OSStatus
  func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
  @discardableResult func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainItemStore: KeychainItemStore {
  func copyMatching(_ query: [String: Any], _ result: inout AnyObject?) -> OSStatus {
    SecItemCopyMatching(query as CFDictionary, &result)
  }
  func add(_ attributes: [String: Any]) -> OSStatus {
    SecItemAdd(attributes as CFDictionary, nil)
  }
  func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
    SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  }
  @discardableResult func delete(_ query: [String: Any]) -> OSStatus {
    SecItemDelete(query as CFDictionary)
  }
}

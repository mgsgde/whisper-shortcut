import Foundation
import Security

// Protocol for dependency injection and testing.
//
// Every credential goes through the same four operations keyed by `KeychainCredential`, so a
// newly added secret gets the full lifecycle (save/read/delete/presence) for free.
protocol KeychainManaging {
  func save(_ value: String, for credential: KeychainCredential) -> Bool
  func get(_ credential: KeychainCredential) -> String?
  @discardableResult func delete(_ credential: KeychainCredential) -> Bool
  /// True when an item exists, without reading its data.
  func has(_ credential: KeychainCredential) -> Bool
  /// True when a stored value exists *and* is non-empty. Reads the value, so prefer `has` when
  /// only presence matters.
  func hasNonEmpty(_ credential: KeychainCredential) -> Bool

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

  private init() {}

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
    let accountName = credential.accountName
    guard let data = value.data(using: .utf8) else {
      return false
    }

    // Update-in-place first, add only if the item doesn't exist yet. The previous
    // delete-then-add sequence was destructive: when SecItemAdd failed (locked/broken
    // login keychain, sandbox denial), the old key was already deleted — observed in the
    // wild as "my API keys disappear".
    let match: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Constants.serviceName,
      kSecAttrAccount as String: accountName,
    ]
    var status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var add = match
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      status = SecItemAdd(add as CFDictionary, nil)
    }

    lock.lock()
    // Cache the value even when persisting failed: the key then still works for this
    // session (the UI warns that it won't survive a restart) instead of vanishing.
    valueCache[accountName] = value
    knownPresentAccounts.insert(accountName)
    knownAbsentAccounts.remove(accountName)
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
    let accountName = credential.accountName

    lock.lock()
    if let cached = valueCache[accountName] { lock.unlock(); return cached }
    if knownAbsentAccounts.contains(accountName) { lock.unlock(); return nil }
    lock.unlock()

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Constants.serviceName,
      kSecAttrAccount as String: accountName,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    if status == errSecSuccess, let data = result as? Data,
      let apiKey = String(data: data, encoding: .utf8)
    {
      lock.lock()
      valueCache[accountName] = apiKey
      knownPresentAccounts.insert(accountName)
      knownAbsentAccounts.remove(accountName)
      lock.unlock()
      return apiKey
    } else {
      if status == errSecItemNotFound {
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

  @discardableResult
  func delete(_ credential: KeychainCredential) -> Bool {
    let accountName = credential.accountName
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Constants.serviceName,
      kSecAttrAccount as String: accountName,
    ]
    let status = SecItemDelete(query as CFDictionary)
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
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Constants.serviceName,
      kSecAttrAccount as String: accountName,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    lock.lock()
    if status == errSecSuccess {
      knownPresentAccounts.insert(accountName)
    } else if status == errSecItemNotFound {
      knownAbsentAccounts.insert(accountName)
    }
    lock.unlock()
    return status == errSecSuccess
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

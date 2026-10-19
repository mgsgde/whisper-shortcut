import Testing
import Foundation
import Security
@testable import WhisperShortcut_AppStore

/// Locks the data protection keychain migration against the bug that wiped every API key on
/// 2026-10-19: on macOS a `SecItemDelete` without `kSecUseDataProtectionKeychain` also deletes the
/// matching data protection item, so "delete the legacy copy" right after writing the new one
/// deleted both. `RoutingKeychainStore` models that routing (measured in keychain-2.db), so these
/// tests run hermetically in the test host, which has no keychain entitlement.
@Suite("Keychain data protection migration")
struct KeychainMigrationTests {

  /// Two stores keyed by account. Flagged queries hit the data protection store; unflagged reads and
  /// writes hit the legacy store; an unflagged DELETE removes the item from both.
  final class RoutingKeychainStore: KeychainItemStore {
    var dataProtection: [String: Data] = [:]
    var legacy: [String: Data] = [:]

    private func isDP(_ query: [String: Any]) -> Bool {
      (query[kSecUseDataProtectionKeychain as String] as? Bool) == true
    }
    private func account(_ query: [String: Any]) -> String? {
      query[kSecAttrAccount as String] as? String
    }

    func copyMatching(_ query: [String: Any], _ result: inout AnyObject?) -> OSStatus {
      let items = isDP(query) ? dataProtection : legacy
      if (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String) {
        guard !items.isEmpty else { return errSecItemNotFound }
        result = items.keys.map { [kSecAttrAccount as String: $0] } as NSArray
        return errSecSuccess
      }
      guard let account = account(query), let data = items[account] else { return errSecItemNotFound }
      if (query[kSecReturnData as String] as? Bool) == true {
        result = data as NSData
      } else {
        result = [kSecAttrAccount as String: account] as NSDictionary
      }
      return errSecSuccess
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
      guard let account = account(attributes),
        let data = attributes[kSecValueData as String] as? Data
      else { return errSecParam }
      if isDP(attributes) {
        guard dataProtection[account] == nil else { return errSecDuplicateItem }
        dataProtection[account] = data
      } else {
        guard legacy[account] == nil else { return errSecDuplicateItem }
        legacy[account] = data
      }
      return errSecSuccess
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
      guard let account = account(query),
        let data = attributes[kSecValueData as String] as? Data
      else { return errSecParam }
      if isDP(query) {
        guard dataProtection[account] != nil else { return errSecItemNotFound }
        dataProtection[account] = data
      } else {
        guard legacy[account] != nil else { return errSecItemNotFound }
        legacy[account] = data
      }
      return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
      guard let account = account(query) else { return errSecParam }
      let existed: Bool
      if isDP(query) {
        existed = dataProtection.removeValue(forKey: account) != nil
      } else {
        // The macOS behavior that caused the wipe: unflagged deletes reach both stores.
        let a = legacy.removeValue(forKey: account) != nil
        let b = dataProtection.removeValue(forKey: account) != nil
        existed = a || b
      }
      return existed ? errSecSuccess : errSecItemNotFound
    }
  }

  // Raw account names, not `KeychainCredential`s: `get(_:)` prefers DEBUG env / `.env` overrides.
  private let account = "test-migration-key"

  @Test("Lazy migration copies the key and keeps it in both stores")
  func lazyMigrationKeepsBothCopies() {
    let store = RoutingKeychainStore()
    store.legacy[account] = Data("sk-legacy".utf8)
    let manager = KeychainManager(store: store, dataProtection: true)

    #expect(manager.secret(account: account) == "sk-legacy")
    #expect(store.dataProtection[account] == Data("sk-legacy".utf8))
    #expect(store.legacy[account] == Data("sk-legacy".utf8), "older builds still read the legacy copy")

    // A fresh process (empty cache) still finds it.
    #expect(KeychainManager(store: store, dataProtection: true).secret(account: account) == "sk-legacy")
  }

  @Test("Eager launch migration survives a second launch")
  func eagerMigrationIsIdempotent() {
    let store = RoutingKeychainStore()
    store.legacy[account] = Data("sk-legacy".utf8)

    KeychainManager(store: store, dataProtection: true).migrateLegacyItemsIfNeeded()
    KeychainManager(store: store, dataProtection: true).migrateLegacyItemsIfNeeded()

    #expect(store.dataProtection[account] == Data("sk-legacy".utf8))
    #expect(KeychainManager(store: store, dataProtection: true).secret(account: account) == "sk-legacy")
  }

  @Test("Saving a key in a data protection build keeps it, and a stale legacy copy never wins")
  func saveSurvivesAndBeatsStaleLegacy() {
    let store = RoutingKeychainStore()
    store.legacy[account] = Data("sk-old".utf8)
    let manager = KeychainManager(store: store, dataProtection: true)

    #expect(manager.saveSecret("sk-new", account: account))
    #expect(store.dataProtection[account] == Data("sk-new".utf8))

    let relaunched = KeychainManager(store: store, dataProtection: true)
    relaunched.migrateLegacyItemsIfNeeded()
    #expect(relaunched.secret(account: account) == "sk-new")
    #expect(store.dataProtection[account] == Data("sk-new".utf8))
  }

  @Test("Deleting a key removes it from both stores, so it is not migrated back")
  func deleteRemovesBothCopies() {
    let store = RoutingKeychainStore()
    store.legacy[account] = Data("sk-legacy".utf8)
    let manager = KeychainManager(store: store, dataProtection: true)
    _ = manager.secret(account: account)

    #expect(manager.deleteSecret(account: account))
    #expect(store.dataProtection[account] == nil)
    #expect(store.legacy[account] == nil)
    #expect(KeychainManager(store: store, dataProtection: true).secret(account: account) == nil)
  }

  @Test("Builds without the entitlement keep using the legacy store")
  func legacyOnlyBuild() {
    let store = RoutingKeychainStore()
    let manager = KeychainManager(store: store, dataProtection: false)

    #expect(manager.saveSecret("sk-x", account: account))
    #expect(store.legacy[account] == Data("sk-x".utf8))
    #expect(store.dataProtection.isEmpty)
    #expect(KeychainManager(store: store, dataProtection: false).secret(account: account) == "sk-x")
  }
}

import Foundation
import Security

/// Result of one Keychain read. `failed` is not "missing": a locked keychain must not mint a new token.
enum MCPTokenRead: Equatable {
  case found(String)
  case notFound
  case failed(OSStatus)
}

/// Where the token `load` decided to use. Logged; never accompanied by the token itself.
enum MCPTokenSource: String, Equatable {
  case shared
  case localPromoted
  case generated
  case localOnly
  case failed
}

/// What to use and what still has to be written. `writeShared` / `writeLocal` are nil when that
/// store already holds the chosen token (or must not be touched).
struct MCPTokenResolution: Equatable {
  var token: String?
  var writeShared: String?
  var writeLocal: String?
  var source: MCPTokenSource
}

/// Reads and writes one MCP bearer token. `accessGroup == nil` is this build's default group
/// (today's per-build item). A non-nil group is the team-wide shared item.
protocol MCPTokenKeychain {
  func read(account: String, accessGroup: String?) -> MCPTokenRead
  func write(_ value: String, account: String, accessGroup: String?) -> OSStatus
}

/// SecItem for the shared group, and `KeychainManager` for the per-build item.
struct SystemMCPTokenKeychain: MCPTokenKeychain {
  /// Distinct from `KeychainManager`'s service so a shared item can never be read as an API key.
  static let service = "com.whispershortcut.mcp"

  func read(account: String, accessGroup: String?) -> MCPTokenRead {
    guard let accessGroup else { return Self.readLocal(account: account) }
    var result: AnyObject?
    let query = Self.query(account: account, accessGroup: accessGroup, returningData: true)
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess {
      guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
        return .failed(errSecDecode)
      }
      return .found(value)
    }
    if status == errSecItemNotFound { return .notFound }
    return .failed(status)
  }

  func write(_ value: String, account: String, accessGroup: String?) -> OSStatus {
    guard let accessGroup else {
      // `saveSecret` only reports success. A refusal is not `errSecDuplicateItem`; that race
      // belongs to the shared group, whose add can lose to the other build.
      return KeychainManager.shared.saveSecret(value, account: account) ? errSecSuccess : errSecNotAvailable
    }
    guard let data = value.data(using: .utf8) else { return errSecParam }
    let match = Self.query(account: account, accessGroup: accessGroup, returningData: false)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    var status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var add = match
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      status = SecItemAdd(add as CFDictionary, nil)
    }
    return status
  }

  private static func readLocal(account: String) -> MCPTokenRead {
    switch KeychainManager.shared.secretLookup(account: account) {
    case .found(let value): return .found(value)
    case .notFound: return .notFound
    case .failed(let status): return .failed(status)
    }
  }

  private static func query(account: String, accessGroup: String, returningData: Bool) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: accessGroup,
      kSecUseDataProtectionKeychain as String: true,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
    if returningData {
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
    }
    return query
  }
}

/// Resolves the read and write bearer tokens so every build of this team presents the same pair,
/// and falls back to the per-build item when the shared keychain group is not entitled.
final class MCPSharedTokenStore {
  private let keychain: MCPTokenKeychain
  private let sharedGroup: String?

  /// Set when `load` returns nil because a keychain read failed, not because a new token could
  /// not be saved. Callers must not treat that as "mint next time" and must not cache it.
  private(set) var lastReadFailureStatus: OSStatus?

  /// True when `load` returned the shared token and this build's local copy differed or was
  /// missing, so client configs that still hold the old local token need one repair.
  private(set) var adoptedSharedToken = false

  init(keychain: MCPTokenKeychain, sharedGroup: String?) {
    self.keychain = keychain
    self.sharedGroup = sharedGroup
  }

  /// The `keychain-access-groups` entry ending in `.whispershortcut.shared`, or nil when this
  /// build has no shared group (App Store, ad-hoc). Cached for the process: the entitlement
  /// does not change while we run.
  static func sharedAccessGroup() -> String? {
    cachedSharedAccessGroup
  }

  private static let cachedSharedAccessGroup: String? = {
    guard let task = SecTaskCreateFromSelf(nil) else { return nil }
    let entitlement = "keychain-access-groups" as CFString
    guard let raw = SecTaskCopyValueForEntitlement(task, entitlement, nil) else {
      return nil
    }
    let groups = raw as? [String] ?? (raw as? [Any])?.compactMap { $0 as? String } ?? []
    return groups.first { $0.hasSuffix(".whispershortcut.shared") }
  }()

  /// 32 random bytes, hex. nil when the system RNG refuses.
  static func generateToken() -> String? {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      DebugLogger.logError("MCP-SERVER: Could not generate a token (SecRandomCopyBytes status=\(status))")
      return nil
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// Pure. `shared == nil` means this process has no shared access group. An empty `found` is
  /// missing. A `failed` read never mints a replacement.
  static func resolve(
    shared: MCPTokenRead?, local: MCPTokenRead, generate: () -> String?
  ) -> MCPTokenResolution {
    guard let shared else {
      return resolveLocalOnly(local, generate: generate)
    }
    switch shared {
    case .found(let value) where !value.isEmpty:
      return MCPTokenResolution(
        token: value, writeShared: nil, writeLocal: localMirror(of: value, local: local), source: .shared)
    case .failed:
      // The shared item is unreadable. Keep serving this build's own token.
      return resolveLocalOnly(local, generate: generate)
    case .found, .notFound:
      if let existing = storedToken(local) {
        return MCPTokenResolution(token: existing, writeShared: existing, writeLocal: nil, source: .localPromoted)
      }
      if case .failed = local {
        return MCPTokenResolution(token: nil, writeShared: nil, writeLocal: nil, source: .failed)
      }
      guard let fresh = generate() else {
        return MCPTokenResolution(token: nil, writeShared: nil, writeLocal: nil, source: .failed)
      }
      return MCPTokenResolution(token: fresh, writeShared: fresh, writeLocal: fresh, source: .generated)
    }
  }

  /// nil only when no token could be stored anywhere. A shared write that loses a race re-reads
  /// the winner. Any other shared write failure still returns the token when it lives somewhere.
  func load(account: String) -> String? {
    adoptedSharedToken = false
    lastReadFailureStatus = nil
    var loggedSource: MCPTokenSource = .failed
    defer {
      DebugLogger.log("MCP-SERVER: Token load account=\(account) source=\(loggedSource.rawValue)")
    }

    let sharedRead: MCPTokenRead?
    if let sharedGroup {
      sharedRead = keychain.read(account: account, accessGroup: sharedGroup)
    } else {
      sharedRead = nil
    }
    if let sharedRead, case .failed(let status) = sharedRead {
      DebugLogger.logError("MCP-SERVER: Shared keychain read failed for \(account): status=\(status)")
    }

    let localRead = keychain.read(account: account, accessGroup: nil)
    let resolution = Self.resolve(shared: sharedRead, local: localRead, generate: Self.generateToken)
    loggedSource = resolution.source

    var token = resolution.token
    guard token != nil else {
      if case .failed(let status) = localRead { lastReadFailureStatus = status }
      return nil
    }

    let alreadyInShared = resolution.source == .shared
    let alreadyInLocal = resolution.source == .localOnly || resolution.source == .localPromoted
    var wroteShared = false
    var wroteLocal = false
    var localToWrite = resolution.writeLocal

    if let value = resolution.writeShared, let group = sharedGroup {
      let status = keychain.write(value, account: account, accessGroup: group)
      if status == errSecSuccess {
        wroteShared = true
      } else if status == errSecDuplicateItem {
        switch keychain.read(account: account, accessGroup: group) {
        case .found(let winner) where !winner.isEmpty:
          token = winner
          wroteShared = true
          localToWrite = winner
          DebugLogger.log("MCP-SERVER: Shared keychain write raced for \(account); using the stored token")
        default:
          DebugLogger.logError(
            "MCP-SERVER: Shared keychain write raced for \(account) but the stored token could not be read")
          if !alreadyInLocal {
            token = nil
            localToWrite = nil
          }
        }
      } else {
        DebugLogger.logError("MCP-SERVER: Shared keychain write failed for \(account): status=\(status)")
      }
    }

    if let value = localToWrite {
      let status = keychain.write(value, account: account, accessGroup: nil)
      if status == errSecSuccess {
        wroteLocal = true
      } else {
        DebugLogger.logError(
          "MCP-SERVER: Could not store the token in the Keychain (account \(account)): status=\(status)")
      }
    }

    let persisted = alreadyInShared || alreadyInLocal || wroteShared || wroteLocal
    guard persisted, let token else { return nil }
    if resolution.source == .shared, resolution.writeLocal != nil {
      adoptedSharedToken = true
    }
    return token
  }

  /// Explicit regenerate. Writes the shared item when this build has the group, and always the
  /// local item. True when at least one write landed, so a client can be given the new token.
  @discardableResult
  func store(_ token: String, account: String) -> Bool {
    var persisted = false
    if let group = sharedGroup {
      var status = keychain.write(token, account: account, accessGroup: group)
      // Regenerate wants THIS token in the shared item. A duplicate means the item appeared
      // between the update and the add; the second call updates it.
      if status == errSecDuplicateItem {
        status = keychain.write(token, account: account, accessGroup: group)
      }
      if status == errSecSuccess {
        persisted = true
      } else {
        DebugLogger.logError("MCP-SERVER: Shared keychain write failed for \(account): status=\(status)")
      }
    }
    let localStatus = keychain.write(token, account: account, accessGroup: nil)
    if localStatus == errSecSuccess {
      persisted = true
    } else {
      DebugLogger.logError(
        "MCP-SERVER: Could not store the token in the Keychain (account \(account)): status=\(localStatus)")
    }
    return persisted
  }

  /// No shared group, or the shared read failed: today's per-build behaviour.
  private static func resolveLocalOnly(_ local: MCPTokenRead, generate: () -> String?) -> MCPTokenResolution {
    if let existing = storedToken(local) {
      return MCPTokenResolution(token: existing, writeShared: nil, writeLocal: nil, source: .localOnly)
    }
    if case .failed = local {
      return MCPTokenResolution(token: nil, writeShared: nil, writeLocal: nil, source: .failed)
    }
    guard let fresh = generate() else {
      return MCPTokenResolution(token: nil, writeShared: nil, writeLocal: nil, source: .failed)
    }
    return MCPTokenResolution(token: fresh, writeShared: nil, writeLocal: fresh, source: .generated)
  }

  /// Copy the shared token into this build's group when the local item is missing or different.
  /// A failed local read is left alone: it may already hold the same secret.
  private static func localMirror(of shared: String, local: MCPTokenRead) -> String? {
    switch local {
    case .found(let value) where value == shared:
      return nil
    case .failed:
      return nil
    case .found, .notFound:
      return shared
    }
  }

  private static func storedToken(_ read: MCPTokenRead) -> String? {
    if case .found(let value) = read, !value.isEmpty { return value }
    return nil
  }
}

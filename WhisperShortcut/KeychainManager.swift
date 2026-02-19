import Foundation
import Security

// Protocol for dependency injection and testing
protocol KeychainManaging {
  func saveAPIKey(_ apiKey: String) -> Bool
  func getAPIKey() -> String?
  func deleteAPIKey() -> Bool
  func hasAPIKey() -> Bool
  func saveGoogleAPIKey(_ apiKey: String) -> Bool
  func getGoogleAPIKey() -> String?
  func deleteGoogleAPIKey() -> Bool
  func hasGoogleAPIKey() -> Bool
  /// Returns true if a non-empty Google API key is stored.
  func hasValidGoogleAPIKey() -> Bool
}

class KeychainManager: KeychainManaging {
  static let shared = KeychainManager()

  // MARK: - Constants
  private enum Constants {
    static let serviceName = "com.whispershortcut.openai"
    static let accountName = "api-key"
    static let googleAccountName = "google-api-key"
  }

  private var cachedAPIKey: String?
  private var cachedGoogleAPIKey: String?

  private init() {}

  // MARK: - Generic Keychain Operations
  
  private func saveKey(_ apiKey: String, accountName: String, cache: inout String?) -> Bool {
    clearCache(accountName: accountName, cache: &cache)
    _ = deleteKey(accountName: accountName, cache: &cache)
    guard let data = apiKey.data(using: .utf8) else {
      return false
    }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Constants.serviceName,
      kSecAttrAccount as String: accountName,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]

    let status = SecItemAdd(query as CFDictionary, nil)
    return status == errSecSuccess
  }
  
  private func getKey(accountName: String, cache: inout String?) -> String? {
    if let cached = cache { return cached }

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
      cache = apiKey
      return apiKey
    } else {
      return nil
    }
  }
  
  private func deleteKey(accountName: String, cache: inout String?) -> Bool {
    clearCache(accountName: accountName, cache: &cache)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Constants.serviceName,
      kSecAttrAccount as String: accountName,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
  
  private func hasKey(accountName: String, cache: String?) -> Bool {
    // Check if cached key exists first
    if cache != nil { return true }

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
    return status == errSecSuccess
  }
  
  private func clearCache(accountName: String, cache: inout String?) {
    cache = nil
  }

  // MARK: - API Key Management

  func saveAPIKey(_ apiKey: String) -> Bool {
    return saveKey(apiKey, accountName: Constants.accountName, cache: &cachedAPIKey)
  }

  func getAPIKey() -> String? {
    return getKey(accountName: Constants.accountName, cache: &cachedAPIKey)
  }

  func deleteAPIKey() -> Bool {
    return deleteKey(accountName: Constants.accountName, cache: &cachedAPIKey)
  }

  func hasAPIKey() -> Bool {
    return hasKey(accountName: Constants.accountName, cache: cachedAPIKey)
  }

  // MARK: - Google API Key Management

  func saveGoogleAPIKey(_ apiKey: String) -> Bool {
    return saveKey(apiKey, accountName: Constants.googleAccountName, cache: &cachedGoogleAPIKey)
  }

  func getGoogleAPIKey() -> String? {
    return getKey(accountName: Constants.googleAccountName, cache: &cachedGoogleAPIKey)
  }

  func deleteGoogleAPIKey() -> Bool {
    return deleteKey(accountName: Constants.googleAccountName, cache: &cachedGoogleAPIKey)
  }

  func hasGoogleAPIKey() -> Bool {
    return hasKey(accountName: Constants.googleAccountName, cache: cachedGoogleAPIKey)
  }

  func hasValidGoogleAPIKey() -> Bool {
    guard let key = getGoogleAPIKey() else { return false }
    return !key.isEmpty
  }
}

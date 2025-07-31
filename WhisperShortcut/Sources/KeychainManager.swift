import Foundation
import LocalAuthentication
import Security

// Protocol for dependency injection and testing
protocol KeychainManaging {
  func saveAPIKey(_ apiKey: String) -> Bool
  func getAPIKey() -> String?
  func deleteAPIKey() -> Bool
  func hasAPIKey() -> Bool
}

class KeychainManager: KeychainManaging {
  static let shared = KeychainManager()
  private let serviceName = "com.whispershortcut.openai"
  private let accountName = "api-key"
  private var cachedAPIKey: String?
  private init() {}

  // MARK: - API Key Management

  func saveAPIKey(_ apiKey: String) -> Bool {
    clearCache()
    _ = deleteAPIKey()
    guard let data = apiKey.data(using: .utf8) else {
      print("❌ Failed to convert API key to data")
      return false
    }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: accountName,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]

    let status = SecItemAdd(query as CFDictionary, nil)

    if status == errSecSuccess {
      print("✅ API key saved to Keychain successfully")
      return true
    } else {
      print("❌ Failed to save API key to Keychain: \(status)")
      return false
    }
  }

  func getAPIKey() -> String? {
    if let cached = cachedAPIKey { return cached }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: accountName,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    if status == errSecSuccess, let data = result as? Data,
      let apiKey = String(data: data, encoding: .utf8)
    {
      print("✅ API key retrieved from Keychain")
      cachedAPIKey = apiKey
      return apiKey
    } else {
      print("⚠️ No API key found in Keychain or error: \(status)")
      return nil
    }
  }

  func deleteAPIKey() -> Bool {
    clearCache()
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: accountName,
    ]
    let status = SecItemDelete(query as CFDictionary)

    if status == errSecSuccess || status == errSecItemNotFound {
      print("✅ API key deleted from Keychain (or was not found)")
      return true
    } else {
      print("❌ Failed to delete API key from Keychain: \(status)")
      return false
    }
  }

  func hasAPIKey() -> Bool {
    // Check if cached key exists first
    if cachedAPIKey != nil { return true }

    // Check if key exists in keychain without reading the data
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: accountName,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    return status == errSecSuccess
  }

  private func clearCache() {
    cachedAPIKey = nil
  }
}

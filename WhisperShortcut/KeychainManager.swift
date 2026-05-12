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
  func saveXAIAPIKey(_ apiKey: String) -> Bool
  func getXAIAPIKey() -> String?
  func deleteXAIAPIKey() -> Bool
  func hasValidXAIAPIKey() -> Bool
  func saveGoogleCalendarRefreshToken(_ token: String) -> Bool
  func getGoogleCalendarRefreshToken() -> String?
  func deleteGoogleCalendarRefreshToken() -> Bool
  func hasGoogleCalendarRefreshToken() -> Bool
  func saveTrelloToken(_ token: String) -> Bool
  func getTrelloToken() -> String?
  func deleteTrelloToken() -> Bool
  func hasTrelloToken() -> Bool
  func saveTrelloAPIKey(_ apiKey: String) -> Bool
  func getTrelloAPIKey() -> String?
  func deleteTrelloAPIKey() -> Bool
  func hasValidTrelloAPIKey() -> Bool
}

class KeychainManager: KeychainManaging {
  static let shared = KeychainManager()

  // MARK: - Constants
  private enum Constants {
    static let serviceName = "com.whispershortcut.openai"
    static let accountName = "api-key"
    static let googleAccountName = "google-api-key"
    static let xaiAccountName = "xai-api-key"
    static let googleCalendarRefreshTokenAccountName = "google-calendar-refresh-token"
    static let trelloTokenAccountName = "trello-token"
    static let trelloAPIKeyAccountName = "trello-api-key"
  }

  private var cachedAPIKey: String?
  private var cachedGoogleAPIKey: String?
  private var cachedXAIAPIKey: String?
  private var cachedGoogleCalendarRefreshToken: String?
  private var cachedTrelloToken: String?
  private var cachedTrelloAPIKey: String?

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
    if status != errSecSuccess {
      DebugLogger.logError("KEYCHAIN: SecItemAdd failed for account \(accountName): status=\(status)")
    }
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
      if status != errSecItemNotFound {
        DebugLogger.logError("KEYCHAIN: SecItemCopyMatching failed for account \(accountName): status=\(status)")
      }
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

  // MARK: - xAI API Key Management

  func saveXAIAPIKey(_ apiKey: String) -> Bool {
    return saveKey(apiKey, accountName: Constants.xaiAccountName, cache: &cachedXAIAPIKey)
  }

  func getXAIAPIKey() -> String? {
    return getKey(accountName: Constants.xaiAccountName, cache: &cachedXAIAPIKey)
  }

  func deleteXAIAPIKey() -> Bool {
    return deleteKey(accountName: Constants.xaiAccountName, cache: &cachedXAIAPIKey)
  }

  func hasValidXAIAPIKey() -> Bool {
    guard let key = getXAIAPIKey() else { return false }
    return !key.isEmpty
  }

  // MARK: - Google Calendar Refresh Token Management

  func saveGoogleCalendarRefreshToken(_ token: String) -> Bool {
    return saveKey(token, accountName: Constants.googleCalendarRefreshTokenAccountName, cache: &cachedGoogleCalendarRefreshToken)
  }

  func getGoogleCalendarRefreshToken() -> String? {
    return getKey(accountName: Constants.googleCalendarRefreshTokenAccountName, cache: &cachedGoogleCalendarRefreshToken)
  }

  func deleteGoogleCalendarRefreshToken() -> Bool {
    return deleteKey(accountName: Constants.googleCalendarRefreshTokenAccountName, cache: &cachedGoogleCalendarRefreshToken)
  }

  func hasGoogleCalendarRefreshToken() -> Bool {
    return hasKey(accountName: Constants.googleCalendarRefreshTokenAccountName, cache: cachedGoogleCalendarRefreshToken)
  }

  // MARK: - Trello Token Management

  func saveTrelloToken(_ token: String) -> Bool {
    return saveKey(token, accountName: Constants.trelloTokenAccountName, cache: &cachedTrelloToken)
  }

  func getTrelloToken() -> String? {
    return getKey(accountName: Constants.trelloTokenAccountName, cache: &cachedTrelloToken)
  }

  func deleteTrelloToken() -> Bool {
    return deleteKey(accountName: Constants.trelloTokenAccountName, cache: &cachedTrelloToken)
  }

  func hasTrelloToken() -> Bool {
    return hasKey(accountName: Constants.trelloTokenAccountName, cache: cachedTrelloToken)
  }

  // MARK: - Trello API Key Management
  // The API key is the user's own Trello Power-Up key (from
  // trello.com/power-ups/admin). It is *not* a Trello secret — Trello hands it
  // out for any Power-Up the user creates — but we keep it in Keychain so it's
  // not stored in plain UserDefaults.

  func saveTrelloAPIKey(_ apiKey: String) -> Bool {
    return saveKey(apiKey, accountName: Constants.trelloAPIKeyAccountName, cache: &cachedTrelloAPIKey)
  }

  func getTrelloAPIKey() -> String? {
    return getKey(accountName: Constants.trelloAPIKeyAccountName, cache: &cachedTrelloAPIKey)
  }

  func deleteTrelloAPIKey() -> Bool {
    return deleteKey(accountName: Constants.trelloAPIKeyAccountName, cache: &cachedTrelloAPIKey)
  }

  func hasValidTrelloAPIKey() -> Bool {
    guard let key = getTrelloAPIKey() else { return false }
    return !key.isEmpty
  }
}

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
  func saveAnthropicAPIKey(_ apiKey: String) -> Bool
  func getAnthropicAPIKey() -> String?
  func deleteAnthropicAPIKey() -> Bool
  func hasValidAnthropicAPIKey() -> Bool
  func saveOpenAIAPIKey(_ apiKey: String) -> Bool
  func getOpenAIAPIKey() -> String?
  func deleteOpenAIAPIKey() -> Bool
  func hasValidOpenAIAPIKey() -> Bool
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
  func saveCustomTranscriptionBearerToken(_ token: String) -> Bool
  func getCustomTranscriptionBearerToken() -> String?
  func saveCustomTranscriptionHeaders(_ headers: [[String: String]]) -> Bool
  func getCustomTranscriptionHeaders() -> [[String: String]]
  func saveCustomOpenAIChatAPIKey(_ apiKey: String) -> Bool
  func getCustomOpenAIChatAPIKey() -> String?
}

class KeychainManager: KeychainManaging {
  static let shared = KeychainManager()

  // MARK: - Constants
  private enum Constants {
    static let serviceName = "com.whispershortcut.openai"
    static let accountName = "api-key"
    static let googleAccountName = "google-api-key"
    static let xaiAccountName = "xai-api-key"
    static let anthropicAccountName = "anthropic-api-key"
    static let openAIAccountName = "openai-api-key"
    static let googleCalendarRefreshTokenAccountName = "google-calendar-refresh-token"
    static let trelloTokenAccountName = "trello-token"
    static let trelloAPIKeyAccountName = "trello-api-key"
    static let customTranscriptionBearerTokenAccountName = "custom-transcription-bearer-token"
    static let customTranscriptionHeadersAccountName = "custom-transcription-headers"
    static let customOpenAIChatAPIKeyAccountName = "custom-openai-chat-api-key"
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
  // Set them in the test plan (Configurations ▸ Environment Variables) or pass
  // them on the xcodebuild command line. Each account accepts the project's
  // `WHISPERSHORTCUT_*` name first, then the provider's conventional name, so
  // a key already exported in the shell (OPENAI_API_KEY, XAI_API_KEY, …) is
  // picked up automatically.
  //
  // Gated to DEBUG so the shipped Release build never reads them; GUI launches
  // don't inherit a shell environment anyway, so this is inert in production.
  private static let environmentKeyNames: [String: [String]] = [
    Constants.googleAccountName: ["WHISPERSHORTCUT_GOOGLE_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"],
    Constants.xaiAccountName: ["WHISPERSHORTCUT_XAI_API_KEY", "XAI_API_KEY"],
    Constants.anthropicAccountName: ["WHISPERSHORTCUT_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY"],
    Constants.openAIAccountName: ["WHISPERSHORTCUT_OPENAI_API_KEY", "OPENAI_API_KEY"],
  ]

  private func environmentOverride(for accountName: String) -> String? {
    #if DEBUG
    guard let varNames = Self.environmentKeyNames[accountName] else { return nil }
    let env = ProcessInfo.processInfo.environment
    for name in varNames {
      if let value = env[name], !value.isEmpty { return value }
    }
    return nil
    #else
    return nil
    #endif
  }

  // MARK: - Generic Keychain Operations

  private func saveKey(_ apiKey: String, accountName: String) -> Bool {
    _ = deleteKey(accountName: accountName)
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
    if status == errSecSuccess {
      lock.lock()
      valueCache[accountName] = apiKey
      knownPresentAccounts.insert(accountName)
      knownAbsentAccounts.remove(accountName)
      lock.unlock()
    } else {
      DebugLogger.logError("KEYCHAIN: SecItemAdd failed for account \(accountName): status=\(status)")
    }
    return status == errSecSuccess
  }

  private func getKey(accountName: String) -> String? {
    if let injected = environmentOverride(for: accountName) { return injected }

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

  private func deleteKey(accountName: String) -> Bool {
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

  private func hasKey(accountName: String) -> Bool {
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

  // MARK: - API Key Management

  func saveAPIKey(_ apiKey: String) -> Bool {
    return saveKey(apiKey, accountName: Constants.accountName)
  }

  func getAPIKey() -> String? {
    return getKey(accountName: Constants.accountName)
  }

  func deleteAPIKey() -> Bool {
    return deleteKey(accountName: Constants.accountName)
  }

  func hasAPIKey() -> Bool {
    return hasKey(accountName: Constants.accountName)
  }

  // MARK: - Google API Key Management

  func saveGoogleAPIKey(_ apiKey: String) -> Bool {
    return saveKey(apiKey, accountName: Constants.googleAccountName)
  }

  func getGoogleAPIKey() -> String? {
    return getKey(accountName: Constants.googleAccountName)
  }

  func deleteGoogleAPIKey() -> Bool {
    return deleteKey(accountName: Constants.googleAccountName)
  }

  func hasGoogleAPIKey() -> Bool {
    return hasKey(accountName: Constants.googleAccountName)
  }

  func hasValidGoogleAPIKey() -> Bool {
    guard let key = getGoogleAPIKey() else { return false }
    return !key.isEmpty
  }

  // MARK: - xAI API Key Management

  func saveXAIAPIKey(_ apiKey: String) -> Bool {
    return saveKey(apiKey, accountName: Constants.xaiAccountName)
  }

  func getXAIAPIKey() -> String? {
    return getKey(accountName: Constants.xaiAccountName)
  }

  func deleteXAIAPIKey() -> Bool {
    return deleteKey(accountName: Constants.xaiAccountName)
  }

  func hasValidXAIAPIKey() -> Bool {
    guard let key = getXAIAPIKey() else { return false }
    return !key.isEmpty
  }

  // MARK: - Anthropic API Key Management

  func saveAnthropicAPIKey(_ apiKey: String) -> Bool {
    return saveKey(apiKey, accountName: Constants.anthropicAccountName)
  }

  func getAnthropicAPIKey() -> String? {
    return getKey(accountName: Constants.anthropicAccountName)
  }

  func deleteAnthropicAPIKey() -> Bool {
    return deleteKey(accountName: Constants.anthropicAccountName)
  }

  func hasValidAnthropicAPIKey() -> Bool {
    guard let key = getAnthropicAPIKey() else { return false }
    return !key.isEmpty
  }

  // MARK: - OpenAI API Key Management

  func saveOpenAIAPIKey(_ apiKey: String) -> Bool {
    return saveKey(apiKey, accountName: Constants.openAIAccountName)
  }

  func getOpenAIAPIKey() -> String? {
    return getKey(accountName: Constants.openAIAccountName)
  }

  func deleteOpenAIAPIKey() -> Bool {
    return deleteKey(accountName: Constants.openAIAccountName)
  }

  func hasValidOpenAIAPIKey() -> Bool {
    guard let key = getOpenAIAPIKey() else { return false }
    return !key.isEmpty
  }

  // MARK: - Google Calendar Refresh Token Management

  func saveGoogleCalendarRefreshToken(_ token: String) -> Bool {
    return saveKey(token, accountName: Constants.googleCalendarRefreshTokenAccountName)
  }

  func getGoogleCalendarRefreshToken() -> String? {
    return getKey(accountName: Constants.googleCalendarRefreshTokenAccountName)
  }

  func deleteGoogleCalendarRefreshToken() -> Bool {
    return deleteKey(accountName: Constants.googleCalendarRefreshTokenAccountName)
  }

  func hasGoogleCalendarRefreshToken() -> Bool {
    return hasKey(accountName: Constants.googleCalendarRefreshTokenAccountName)
  }

  // MARK: - Trello Token Management

  func saveTrelloToken(_ token: String) -> Bool {
    return saveKey(token, accountName: Constants.trelloTokenAccountName)
  }

  func getTrelloToken() -> String? {
    return getKey(accountName: Constants.trelloTokenAccountName)
  }

  func deleteTrelloToken() -> Bool {
    return deleteKey(accountName: Constants.trelloTokenAccountName)
  }

  func hasTrelloToken() -> Bool {
    return hasKey(accountName: Constants.trelloTokenAccountName)
  }

  // MARK: - Trello API Key Management
  // The API key is the user's own Trello Power-Up key (from
  // trello.com/power-ups/admin). It is *not* a Trello secret — Trello hands it
  // out for any Power-Up the user creates — but we keep it in Keychain so it's
  // not stored in plain UserDefaults.

  func saveTrelloAPIKey(_ apiKey: String) -> Bool {
    return saveKey(apiKey, accountName: Constants.trelloAPIKeyAccountName)
  }

  func getTrelloAPIKey() -> String? {
    return getKey(accountName: Constants.trelloAPIKeyAccountName)
  }

  func deleteTrelloAPIKey() -> Bool {
    return deleteKey(accountName: Constants.trelloAPIKeyAccountName)
  }

  func hasValidTrelloAPIKey() -> Bool {
    guard let key = getTrelloAPIKey() else { return false }
    return !key.isEmpty
  }

  // MARK: - Custom Transcription API Credentials

  func saveCustomTranscriptionBearerToken(_ token: String) -> Bool {
    return saveKey(token, accountName: Constants.customTranscriptionBearerTokenAccountName)
  }

  func getCustomTranscriptionBearerToken() -> String? {
    return getKey(accountName: Constants.customTranscriptionBearerTokenAccountName)
  }

  func saveCustomTranscriptionHeaders(_ headers: [[String: String]]) -> Bool {
    guard let data = try? JSONEncoder().encode(headers),
          let jsonString = String(data: data, encoding: .utf8) else {
      return false
    }
    return saveKey(jsonString, accountName: Constants.customTranscriptionHeadersAccountName)
  }

  func getCustomTranscriptionHeaders() -> [[String: String]] {
    guard let jsonString = getKey(accountName: Constants.customTranscriptionHeadersAccountName),
          let data = jsonString.data(using: .utf8),
          let headers = try? JSONDecoder().decode([[String: String]].self, from: data) else {
      return []
    }
    return headers
  }

  // MARK: - Custom OpenAI-compatible Chat Endpoint API Key
  // Optional override when routing chat through a proxy (OpenRouter, LiteLLM, …). When empty,
  // OpenAIChatPreferences falls back to the standard OpenAI key from Settings → General.

  func saveCustomOpenAIChatAPIKey(_ apiKey: String) -> Bool {
    return saveKey(apiKey, accountName: Constants.customOpenAIChatAPIKeyAccountName)
  }

  func getCustomOpenAIChatAPIKey() -> String? {
    return getKey(accountName: Constants.customOpenAIChatAPIKeyAccountName)
  }
}

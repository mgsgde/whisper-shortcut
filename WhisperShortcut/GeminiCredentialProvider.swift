import Foundation

/// Provides the current credential for Gemini API (API key from Keychain).
/// Single source of truth so all Gemini callers stay in sync.
protocol GeminiCredentialProviding {
  /// Returns a valid credential if the user has set an API key; nil otherwise.
  func getCredential() async -> GeminiCredential?
  /// Returns true if a non-empty API key is stored.
  func hasCredential() -> Bool
}

/// Default implementation: API key from Keychain only.
final class GeminiCredentialProvider: GeminiCredentialProviding {
  static let shared = GeminiCredentialProvider(keychainManager: KeychainManager.shared)

  private let keychainManager: KeychainManaging

  init(keychainManager: KeychainManaging = KeychainManager.shared) {
    self.keychainManager = keychainManager
  }

  func getCredential() async -> GeminiCredential? {
    guard let key = keychainManager.getGoogleAPIKey(), !key.isEmpty else { return nil }
    return .apiKey(key)
  }

  func hasCredential() -> Bool {
    keychainManager.hasValidGoogleAPIKey()
  }
}

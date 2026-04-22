import Foundation

/// Provides the current credential for Gemini API (BYOK — manual API key only).
protocol GeminiCredentialProviding {
  func getCredential() async -> GeminiCredential?
  func hasCredential() -> Bool
}

final class GeminiCredentialProvider: GeminiCredentialProviding {
  static let shared = GeminiCredentialProvider(keychainManager: KeychainManager.shared)

  private let keychainManager: KeychainManaging

  init(keychainManager: KeychainManaging = KeychainManager.shared) {
    self.keychainManager = keychainManager
  }

  func getCredential() async -> GeminiCredential? {
    if let key = keychainManager.getGoogleAPIKey(), !key.isEmpty {
      return .apiKey(key)
    }
    return nil
  }

  func hasCredential() -> Bool {
    return keychainManager.hasValidGoogleAPIKey()
  }
}

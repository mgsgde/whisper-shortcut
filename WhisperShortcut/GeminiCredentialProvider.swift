import Foundation

/// Provides the current credential for Gemini API (API key from Keychain or OAuth when signed in with Google).
/// Single source of truth so all Gemini callers stay in sync. Priority: API key if set, else OAuth access token if signed in.
protocol GeminiCredentialProviding {
  /// Returns a valid credential if the user has set an API key or is signed in with Google; nil otherwise.
  func getCredential() async -> GeminiCredential?
  /// Returns true if a non-empty API key is stored or the user is signed in with Google.
  func hasCredential() -> Bool
}

/// Default implementation: API key from Keychain first; if none, OAuth access token when signed in with Google.
final class GeminiCredentialProvider: GeminiCredentialProviding {
  static let shared = GeminiCredentialProvider(keychainManager: KeychainManager.shared)

  private let keychainManager: KeychainManaging

  init(keychainManager: KeychainManaging = KeychainManager.shared) {
    self.keychainManager = keychainManager
  }

  func getCredential() async -> GeminiCredential? {
    // API key always has precedence; OAuth (Google Sign-In) is used only when no API key is set.
    if let key = keychainManager.getGoogleAPIKey(), !key.isEmpty {
      return .apiKey(key)
    }
    if DefaultGoogleAuthService.shared.isSignedIn(),
       let accessToken = await DefaultGoogleAuthService.shared.currentAccessToken(),
       !accessToken.isEmpty {
      return .oauth(accessToken: accessToken)
    }
    return nil
  }

  func hasCredential() -> Bool {
    // Same priority: API key first, then signed-in state.
    if keychainManager.hasValidGoogleAPIKey() { return true }
    return DefaultGoogleAuthService.shared.isSignedIn()
  }
}

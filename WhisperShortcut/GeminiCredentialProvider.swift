import Foundation

/// Provides the current credential for Gemini API (OAuth if signed in, else API key).
/// Single source of truth for "which credential to use" so all Gemini callers stay in sync.
protocol GeminiCredentialProviding {
  /// Returns a valid credential if the user can call Gemini; nil otherwise.
  func getCredential() -> GeminiCredential?
  /// Returns true if either OAuth is signed in or a non-empty API key is stored.
  func hasCredential() -> Bool
}

/// Default implementation: OAuth takes precedence over API key when available.
final class GeminiCredentialProvider: GeminiCredentialProviding {
  static let shared = GeminiCredentialProvider(googleAuthService: DefaultGoogleAuthService.shared)

  private let keychainManager: KeychainManaging
  private weak var googleAuthService: GoogleAuthService?

  init(
    keychainManager: KeychainManaging = KeychainManager.shared,
    googleAuthService: GoogleAuthService? = nil
  ) {
    self.keychainManager = keychainManager
    self.googleAuthService = googleAuthService
  }

  func getCredential() -> GeminiCredential? {
    if let auth = googleAuthService, let token = auth.currentAccessToken() {
      return .oauth(accessToken: token)
    }
    if let key = keychainManager.getGoogleAPIKey(), !key.isEmpty {
      return .apiKey(key)
    }
    return nil
  }

  func hasCredential() -> Bool {
    if googleAuthService?.isSignedIn() == true { return true }
    return keychainManager.hasValidGoogleAPIKey()
  }
}

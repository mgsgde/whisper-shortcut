import Foundation

/// Provides the current credential for Gemini API (API key if set, else OAuth when signed in).
/// Single source of truth for "which credential to use" so all Gemini callers stay in sync.
protocol GeminiCredentialProviding {
  /// Returns a valid credential if the user can call Gemini; nil otherwise.
  /// Refreshes OAuth token if expired.
  func getCredential() async -> GeminiCredential?
  /// Returns true if either OAuth is signed in or a non-empty API key is stored.
  func hasCredential() -> Bool
}

/// Default implementation: API key takes precedence over OAuth when both are available.
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

  func getCredential() async -> GeminiCredential? {
    if let key = keychainManager.getGoogleAPIKey(), !key.isEmpty {
      return .apiKey(key)
    }
    if let auth = googleAuthService, let token = await auth.currentAccessToken() {
      return .oauth(accessToken: token)
    }
    return nil
  }

  func hasCredential() -> Bool {
    if googleAuthService?.isSignedIn() == true { return true }
    return keychainManager.hasValidGoogleAPIKey()
  }
}

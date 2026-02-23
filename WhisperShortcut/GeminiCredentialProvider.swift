import Foundation

/// Provides the current credential for Gemini: API key (direct) or Bearer ID token (proxy only when signed in).
/// Single source of truth. Priority: API key if set, else Bearer ID token when signed in with Google.
protocol GeminiCredentialProviding {
  /// Returns a valid credential if the user has set an API key or is signed in with Google; nil otherwise.
  func getCredential() async -> GeminiCredential?
  /// Returns true if a non-empty API key is stored or the user is signed in with Google.
  func hasCredential() -> Bool
}

/// Default implementation: API key from Keychain first; if none, Bearer ID token when signed in (proxy only).
final class GeminiCredentialProvider: GeminiCredentialProviding {
  static let shared = GeminiCredentialProvider(keychainManager: KeychainManager.shared)

  private let keychainManager: KeychainManaging

  init(keychainManager: KeychainManaging = KeychainManager.shared) {
    self.keychainManager = keychainManager
  }

  func getCredential() async -> GeminiCredential? {
    // API key always has precedence; when signed in (no key), use Bearer ID token for backend proxy only.
    if let key = keychainManager.getGoogleAPIKey(), !key.isEmpty {
      return .apiKey(key)
    }
    if DefaultGoogleAuthService.shared.isSignedIn(),
       let idToken = await DefaultGoogleAuthService.shared.getIDToken(),
       !idToken.isEmpty {
      return .bearer(idToken)
    }
    return nil
  }

  func hasCredential() -> Bool {
    // Same priority: API key first, then signed-in state.
    if keychainManager.hasValidGoogleAPIKey() { return true }
    return DefaultGoogleAuthService.shared.isSignedIn()
  }
}

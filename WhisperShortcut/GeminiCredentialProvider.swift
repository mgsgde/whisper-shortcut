import Foundation

/// Provides the current credential for Gemini: Bearer ID token (Whisper Shortcut App API when signed in) or API key (direct).
/// Single source of truth. Priority: when signed in use Whisper Shortcut App API (Bearer); otherwise API key if set.
protocol GeminiCredentialProviding {
  /// Returns a valid credential if the user is signed in (Bearer) or has set an API key; nil otherwise.
  func getCredential() async -> GeminiCredential?
  /// Returns true if the user is signed in with Google or has a non-empty API key stored.
  func hasCredential() -> Bool
}

/// Default implementation: when signed in use Bearer (Whisper Shortcut App API); else API key from Keychain.
final class GeminiCredentialProvider: GeminiCredentialProviding {
  static let shared = GeminiCredentialProvider(keychainManager: KeychainManager.shared)

  private let keychainManager: KeychainManaging

  init(keychainManager: KeychainManaging = KeychainManager.shared) {
    self.keychainManager = keychainManager
  }

  func getCredential() async -> GeminiCredential? {
    // When signed in, use Whisper Shortcut App API (Bearer); otherwise use API key if set.
    if DefaultGoogleAuthService.shared.isSignedIn(),
       let idToken = await DefaultGoogleAuthService.shared.getIDToken(),
       !idToken.isEmpty {
      return .bearer(idToken)
    }
    if let key = keychainManager.getGoogleAPIKey(), !key.isEmpty {
      return .apiKey(key)
    }
    return nil
  }

  func hasCredential() -> Bool {
    if DefaultGoogleAuthService.shared.isSignedIn() { return true }
    return keychainManager.hasValidGoogleAPIKey()
  }
}

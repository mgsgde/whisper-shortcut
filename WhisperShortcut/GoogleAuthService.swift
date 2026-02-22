import Foundation

/// Stub for Gemini API credential: only API key is used; no OAuth.
protocol GoogleAuthService: AnyObject {
  func currentAccessToken() async -> String?
  func isSignedIn() -> Bool
  func signIn() async throws
  func signOut()
  func signedInUserEmail() -> String?
  func restorePreviousSignInIfNeeded() async
}

/// Stub: OAuth removed; credential provider uses API key only.
final class StubGoogleAuthService: GoogleAuthService {
  static let shared = StubGoogleAuthService()
  private init() {}

  func currentAccessToken() async -> String? { nil }
  func isSignedIn() -> Bool { false }
  func signIn() async throws { }
  func signOut() { }
  func signedInUserEmail() -> String? { nil }
  func restorePreviousSignInIfNeeded() async { }
}

import Foundation
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

/// OAuth sign-in and token supply for Gemini API. When signed in, use Bearer token instead of API key.
protocol GoogleAuthService: AnyObject {
  /// Returns a valid access token for Gemini API, or nil if not signed in or token expired and refresh failed.
  func currentAccessToken() -> String?
  /// True if the user is currently signed in (may still need token refresh).
  func isSignedIn() -> Bool
  /// Start the sign-in flow (opens browser or system UI). Completion on main thread.
  func signIn() async throws
  /// Sign out and clear stored tokens.
  func signOut()
  /// Email or display string for the signed-in user, if available; nil when not signed in.
  func signedInUserEmail() -> String?
}

#if canImport(GoogleSignIn)
/// Real OAuth using Google Sign-In SDK. Use when GIDClientID is set in Info.plist.
final class DefaultGoogleAuthService: GoogleAuthService {
  static let shared = DefaultGoogleAuthService()

  private static let geminiScope = "https://www.googleapis.com/auth/generative-language.retriever"

  private var clientID: String? {
    Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String
  }

  private var isConfigured: Bool {
    guard let id = clientID else { return false }
    return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private init() {}

  func currentAccessToken() -> String? {
    guard isConfigured, let user = GIDSignIn.sharedInstance.currentUser else { return nil }
    return user.accessToken.tokenString
  }

  func isSignedIn() -> Bool {
    guard isConfigured else { return false }
    return GIDSignIn.sharedInstance.currentUser != nil
  }

  func signedInUserEmail() -> String? {
    guard isConfigured, let user = GIDSignIn.sharedInstance.currentUser else { return nil }
    return user.profile?.email
  }

  func signIn() async throws {
    guard isConfigured else {
      DebugLogger.logWarning("GoogleAuth: Not configured (GIDClientID missing or empty)")
      throw NSError(
        domain: "GoogleAuth",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Sign in with Google is not available in this version. Please use an API key below instead."]
      )
    }
    guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
      throw NSError(domain: "GoogleAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "No window to present sign-in"])
    }
    let config = GIDConfiguration(clientID: clientID!)
    GIDSignIn.sharedInstance.configuration = config
    let scopes = [Self.geminiScope]
    return try await withCheckedThrowingContinuation { continuation in
      GIDSignIn.sharedInstance.signIn(withPresenting: window, hint: nil, additionalScopes: scopes) { result, error in
        if let error = error {
          DebugLogger.logError("GoogleAuth: Sign-in failed: \(error.localizedDescription)")
          continuation.resume(throwing: error)
          return
        }
        guard result != nil else {
          continuation.resume(throwing: NSError(domain: "GoogleAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sign-in was cancelled"]))
          return
        }
        DebugLogger.log("GoogleAuth: Sign-in succeeded")
        continuation.resume()
      }
    }
  }

  func signOut() {
    guard isConfigured else { return }
    GIDSignIn.sharedInstance.signOut()
    DebugLogger.log("GoogleAuth: Signed out")
  }

  /// Call from NSApplicationDelegate.application(_:open:...) to handle OAuth redirect.
  static func handle(url: URL) -> Bool {
    GIDSignIn.sharedInstance.handle(url)
  }
}
#else
/// Placeholder when GoogleSignIn is not linked (e.g. conditional build).
final class DefaultGoogleAuthService: GoogleAuthService {
  static let shared = DefaultGoogleAuthService()
  private init() {}
  func currentAccessToken() -> String? { nil }
  func isSignedIn() -> Bool { false }
  func signIn() async throws {
    throw NSError(domain: "GoogleAuth", code: -3, userInfo: [NSLocalizedDescriptionKey: "Google Sign-In is not available in this build."])
  }
  func signOut() { }
  func signedInUserEmail() -> String? { nil }
  static func handle(url: URL) -> Bool { false }
}
#endif

/// Stub: use when OAuth is not configured (no GIDClientID). Credential provider falls back to API key.
final class StubGoogleAuthService: GoogleAuthService {
  static let shared = StubGoogleAuthService()
  private init() {}

  func currentAccessToken() -> String? { nil }
  func isSignedIn() -> Bool { false }
  func signIn() async throws { }
  func signOut() { }
  func signedInUserEmail() -> String? { nil }
}

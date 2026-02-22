//
//  GoogleAuthService.swift
//  WhisperShortcut
//
//  Google Sign-In (SSO) for backend API (ID token) and optional Gemini (access token).
//  Pattern restored from git history; adds getIDToken() for Backend API Bearer auth.
//

import Foundation
import AppKit

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

/// OAuth sign-in and token supply. When signed in: ID token for backend API (Bearer), access token for Gemini if needed.
protocol GoogleAuthService: AnyObject {
  /// Returns a valid access token for Gemini API, refreshing if expired. Nil if not signed in or refresh failed.
  func currentAccessToken() async -> String?
  /// Returns a valid ID token for backend API (Authorization: Bearer). Refreshes if needed. Nil if not signed in or refresh failed.
  func getIDToken() async -> String?
  /// True if the user is currently signed in (may still need token refresh).
  func isSignedIn() -> Bool
  /// Start the sign-in flow (opens browser or system UI). Throws on error or cancel.
  func signIn() async throws
  /// Sign out and clear stored tokens.
  func signOut()
  /// Email or display string for the signed-in user, if available; nil when not signed in.
  func signedInUserEmail() -> String?
  /// Restores a previous sign-in from Keychain if configured and credentials exist. Call at app launch.
  func restorePreviousSignInIfNeeded() async
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

  private init() {
    if isConfigured, let id = clientID {
      GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: id)
      DebugLogger.log("GOOGLE-AUTH: Configured with client ID (prefix: \(id.prefix(20))...)")
    } else {
      DebugLogger.log("GOOGLE-AUTH: GIDClientID not set; Google Sign-In disabled")
    }
  }

  private func refreshUser() async throws -> GIDGoogleUser {
    guard isConfigured, let user = GIDSignIn.sharedInstance.currentUser else {
      throw NSError(domain: "GoogleAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
    }
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GIDGoogleUser, Error>) in
      user.refreshTokensIfNeeded { user, error in
        if let error = error {
          continuation.resume(throwing: error)
        } else if let user = user {
          continuation.resume(returning: user)
        } else {
          continuation.resume(throwing: NSError(domain: "GoogleAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Token refresh returned nil"]))
        }
      }
    }
  }

  func currentAccessToken() async -> String? {
    do {
      let user = try await refreshUser()
      return user.accessToken.tokenString
    } catch {
      DebugLogger.logError("GOOGLE-AUTH: Token refresh failed: \(error.localizedDescription)")
      return nil
    }
  }

  func getIDToken() async -> String? {
    do {
      let user = try await refreshUser()
      return user.idToken?.tokenString
    } catch {
      DebugLogger.logError("GOOGLE-AUTH: Failed to get ID token: \(error.localizedDescription)")
      return nil
    }
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
      DebugLogger.logWarning("GOOGLE-AUTH: Not configured (GIDClientID missing or empty)")
      throw NSError(
        domain: "GoogleAuth",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Sign in with Google is not available. Set GIDClientID in Info.plist or use an API key instead."]
      )
    }
    guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
      throw NSError(domain: "GoogleAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "No window to present sign-in"])
    }
    let config = GIDConfiguration(clientID: clientID!)
    GIDSignIn.sharedInstance.configuration = config
    let scopes = [Self.geminiScope]
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      GIDSignIn.sharedInstance.signIn(withPresenting: window, hint: nil, additionalScopes: scopes) { result, error in
        if let error = error {
          DebugLogger.logError("GOOGLE-AUTH: Sign-in failed: \(error.localizedDescription)")
          let userError: Error
          if error.localizedDescription.lowercased().contains("keychain") {
            userError = NSError(
              domain: "GoogleAuth",
              code: -4,
              userInfo: [
                NSLocalizedDescriptionKey: "Keychain access required. In Xcode add the Keychain Sharing capability and the group com.google.GIDSignIn (see docs/google-sign-in-keychain.md)."
              ]
            )
          } else {
            userError = error
          }
          continuation.resume(throwing: userError)
          return
        }
        guard result != nil else {
          continuation.resume(throwing: NSError(domain: "GoogleAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sign-in was cancelled"]))
          return
        }
        DebugLogger.logSuccess("GOOGLE-AUTH: Sign-in succeeded")
        continuation.resume()
      }
    }
    NotificationCenter.default.post(name: .googleSignInDidChange, object: nil)
  }

  func signOut() {
    guard isConfigured else { return }
    GIDSignIn.sharedInstance.signOut()
    DebugLogger.log("GOOGLE-AUTH: Signed out")
    NotificationCenter.default.post(name: .googleSignInDidChange, object: nil)
  }

  func restorePreviousSignInIfNeeded() async {
    guard isConfigured, let clientID = clientID else { return }
    let config = GIDConfiguration(clientID: clientID)
    GIDSignIn.sharedInstance.configuration = config
    guard GIDSignIn.sharedInstance.hasPreviousSignIn() else {
      DebugLogger.log("GOOGLE-AUTH: No previous session to restore")
      return
    }
    do {
      _ = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
      DebugLogger.log("GOOGLE-AUTH: Restored previous session")
    } catch {
      DebugLogger.logError("GOOGLE-AUTH: Restore failed: \(error.localizedDescription)")
    }
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
  func currentAccessToken() async -> String? { nil }
  func getIDToken() async -> String? { nil }
  func isSignedIn() -> Bool { false }
  func signIn() async throws {
    throw NSError(domain: "GoogleAuth", code: -3, userInfo: [NSLocalizedDescriptionKey: "Google Sign-In is not available in this build."])
  }
  func signOut() { }
  func signedInUserEmail() -> String? { nil }
  func restorePreviousSignInIfNeeded() async { }
  static func handle(url: URL) -> Bool { false }
}
#endif

/// Stub: use when OAuth is not configured (no GIDClientID). No sign-in; getIDToken returns nil.
final class StubGoogleAuthService: GoogleAuthService {
  static let shared = StubGoogleAuthService()
  private init() {}
  func currentAccessToken() async -> String? { nil }
  func getIDToken() async -> String? { nil }
  func isSignedIn() -> Bool { false }
  func signIn() async throws { }
  func signOut() { }
  func signedInUserEmail() -> String? { nil }
  func restorePreviousSignInIfNeeded() async { }
}

// MARK: - Notification

extension Notification.Name {
  static let googleSignInDidChange = Notification.Name("googleSignInDidChange")
}

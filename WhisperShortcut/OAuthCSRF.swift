import Foundation

/// CSRF `state` for OAuth authorize/callback.
///
/// PKCE stops an intercepted authorization code from being *redeemed* by someone else. It does
/// not stop a page the user visits from hitting `http://127.0.0.1:<port>/callback?code=…` with
/// an attacker's own code and binding the app to the attacker's account. A random `state` we
/// sent on the authorize URL, checked on the callback, closes that injection.
enum OAuthCSRF {
  static func makeState() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// True when the callback's `state` matches the one we sent. Logs a reason on mismatch so a
  /// refused callback is visible without a debugger.
  static func accept(expected: String, received: String?, logPrefix: String) -> Bool {
    guard let received, !received.isEmpty else {
      DebugLogger.logError("\(logPrefix): Refusing callback — missing state parameter")
      return false
    }
    guard received == expected else {
      DebugLogger.logError("\(logPrefix): Refusing callback — state mismatch")
      return false
    }
    return true
  }
}

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// PKCE, base64url, and form-encoding were copied across OpenRouter, ChatGPT, and Google and had
/// started to drift: the three verifiers ignored a failed `SecRandomCopyBytes`, Google inlined the
/// base64url replace twice, and its form encoder treated space and `~` differently from ChatGPT's.
/// Gmail's decoder also accepted a base64url length mod 4 of 1, which is not valid base64.

extension Data {
  /// base64url (RFC 4648 §5) without padding — the replace chain that used to live in four files.
  var base64URLEncodedString: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// Rejects a length mod 4 of 1. That is the ID-token validator's rule; Gmail's copy padded that
  /// case in a loop and could hand back garbage instead of failing the body.
  init?(base64URLEncoded string: String) {
    var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder == 1 { return nil }
    if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    guard let data = Data(base64Encoded: base64) else { return nil }
    self = data
  }
}

/// S256 PKCE (RFC 7636). Every caller already drew 32 bytes, so the verifier stays 43 unpadded
/// base64url characters. A failed `SecRandomCopyBytes` used to be discarded, leaving an all-zero
/// verifier — the hole `OAuthCSRF` already closes for `state`.
enum PKCE {
  static func make() -> (verifier: String, challenge: String) {
    var bytes = [UInt8](repeating: 0, count: 32)
    let verifier: String
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
      DebugLogger.logError("OAUTH-PKCE: SecRandomCopyBytes failed — falling back to UUID verifier")
      verifier = UUID().uuidString + UUID().uuidString
    } else {
      verifier = Data(bytes).base64URLEncodedString
    }
    return (verifier, challenge(for: verifier))
  }

  /// Exposed so a fixed verifier can be checked against RFC 7636 appendix B. `make()` cannot
  /// take one without weakening the random draw.
  static func challenge(for verifier: String) -> String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
  }
}

/// `application/x-www-form-urlencoded` with the RFC 3986 unreserved set (space is `%20`, `~` stays).
/// ChatGPT already encoded this way. Google's copy allowed `*` and space (then rewrote space to
/// `+`) and, through `CharacterSet.alphanumerics`, non-ASCII letters. Both token endpoints accept
/// `%20`. Google's real token fields are unreserved plus `:` and `/`, which both encoders escape
/// the same way.
enum FormURLEncoding {
  static func encode(_ pairs: [(String, String)]) -> String {
    pairs.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
  }

  static func percentEncode(_ value: String) -> String {
    // Explicit ASCII set: `CharacterSet.alphanumerics` also contains non-ASCII letters.
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}

/// The key window, or a fresh window when none is key. OpenRouter, Google, and ChatGPT each
/// carried this one-liner, and `presentationContextProvider` is weak, so the instance has to
/// outlive the sheet.
final class OAuthPresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = OAuthPresentationAnchorProvider()

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? ASPresentationAnchor()
  }
}

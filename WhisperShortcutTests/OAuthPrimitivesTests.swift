import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("OAuth primitives")
struct OAuthPrimitivesTests {

  @Test("base64url round-trips, including length mod 4 of 2 and 3, and rejects remainder 1")
  func base64URLRoundTrip() {
    let one = Data([0x61])
    let two = Data([0x61, 0x62])
    let three = Data([0x61, 0x62, 0x63])
    #expect(one.base64URLEncodedString == "YQ")
    #expect(Data(base64URLEncoded: "YQ") == one)
    #expect(two.base64URLEncodedString == "YWI")
    #expect(Data(base64URLEncoded: "YWI") == two)
    #expect(three.base64URLEncodedString == "YWJj")
    #expect(Data(base64URLEncoded: "YWJj") == three)

    // Standard base64 of these bytes is "++++"; the URL form must use "-".
    let slashes = Data([0xfb, 0xef, 0xbe])
    #expect(slashes.base64URLEncodedString == "----")
    #expect(Data(base64URLEncoded: "----") == slashes)

    let text = Data("hello world ✓".utf8)
    #expect(Data(base64URLEncoded: text.base64URLEncodedString) == text)

    #expect(Data(base64URLEncoded: "Y") == nil)
    #expect(Data(base64URLEncoded: "ABCDE") == nil)
  }

  @Test("S256 challenge of the RFC 7636 appendix B verifier")
  func pkceAppendixB() {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test("A fresh verifier is 32 bytes of unpadded base64url, which is what every service drew")
  func verifierLength() {
    let (verifier, challenge) = PKCE.make()
    #expect(verifier.count == 43)
    #expect(challenge == PKCE.challenge(for: verifier))
    #expect(!verifier.contains("="))
    #expect(!verifier.contains("+"))
    #expect(!verifier.contains("/"))
  }

  @Test("Form encoding leaves ~ alone, encodes space as %20, and UTF-8-encodes ä")
  func formEncoding() {
    #expect(FormURLEncoding.encode([("q", "a b"), ("t", "~"), ("n", "ä")]) == "q=a%20b&t=~&n=%C3%A4")
  }

  @Test("Google's real token fields encode the same under the old form rules and RFC 3986")
  func googleTokenFieldsMatch() {
    // The live Google redirect is a custom scheme from Info.plist
    // (`<reversed client id>:/oauthredirect`), not loopback. ChatGPT's redirect is
    // `http://127.0.0.1:<port>/auth/callback`. Outside the unreserved set both shapes contain
    // only ":" and "/", which the old Google encoder (alphanumerics + "-._* ", space rewritten
    // to "+") and `FormURLEncoding` percent-encode identically. `~`, space, and `ä` are the
    // characters that used to differ; they do not appear in these fields.
    let samples = [
      "com.googleusercontent.apps.797100884157-9m6p166qmss4rj9psi4qbmipig9ljkn2:/oauthredirect",
      "http://127.0.0.1:54321/auth/callback",
      "797100884157-9m6p166qmss4rj9psi4qbmipig9ljkn2.apps.googleusercontent.com",
      "4/0AeanS0abc-def_XYZ",
      "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
      "authorization_code",
      "refresh_token",
    ]
    for value in samples {
      #expect(FormURLEncoding.percentEncode(value) == Self.legacyGoogleEncode(value))
    }
    let body = [
      ("grant_type", "authorization_code"),
      ("client_id", "797100884157-9m6p166qmss4rj9psi4qbmipig9ljkn2.apps.googleusercontent.com"),
      ("code", "4/0AeanS0abc-def_XYZ"),
      ("redirect_uri", "com.googleusercontent.apps.797100884157-9m6p166qmss4rj9psi4qbmipig9ljkn2:/oauthredirect"),
      ("code_verifier", "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
    ]
    #expect(FormURLEncoding.encode(body) == Self.legacyGoogleForm(body))
  }

  /// Google's encoder before this refactor, kept so the token-body diff stays checkable.
  private static func legacyGoogleEncode(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._* ")
    let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    return escaped.replacingOccurrences(of: " ", with: "+")
  }

  private static func legacyGoogleForm(_ pairs: [(String, String)]) -> String {
    pairs.map { "\(legacyGoogleEncode($0.0))=\(legacyGoogleEncode($0.1))" }.joined(separator: "&")
  }
}

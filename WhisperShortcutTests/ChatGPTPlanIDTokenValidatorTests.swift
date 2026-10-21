import Testing
import Foundation
import Security
@testable import WhisperShortcut_AppStore

@Suite("ChatGPT plan ID token validation")
struct ChatGPTPlanIDTokenValidatorTests {
  typealias F = ChatGPTPlanFixtures
  typealias V = ChatGPTPlanIDTokenValidator

  private func claimsCheck(
    _ claims: [String: Any], clientID: String = "oaiapp_saved", nonce: String = "nonce-1",
    subject: String? = nil
  ) throws {
    _ = try V.validateClaims(
      idToken: F.jwt(claims: claims), expectedClientID: clientID, expectedNonce: nonce,
      expectedSubject: subject, now: F.now)
  }

  // MARK: Claims

  @Test("A well-formed token passes")
  func valid() throws {
    try claimsCheck(F.idTokenClaims())
    try claimsCheck(F.idTokenClaims(aud: ["other", "oaiapp_saved"]))
    try claimsCheck(F.idTokenClaims(), subject: "sub-123")
  }

  @Test("Wrong issuer is refused")
  func wrongIssuer() {
    #expect(throws: V.ValidationError.issuerMismatch) {
      try claimsCheck(F.idTokenClaims(iss: "https://evil.example"))
    }
  }

  @Test("Wrong audience is refused")
  func wrongAudience() {
    #expect(throws: V.ValidationError.audienceMismatch) {
      try claimsCheck(F.idTokenClaims(aud: "oaiapp_someone_else"))
    }
  }

  @Test("An expired token is refused; one inside the clock skew is not")
  func expiry() throws {
    #expect(throws: V.ValidationError.expired) {
      try claimsCheck(F.idTokenClaims(exp: F.now.addingTimeInterval(-3600)))
    }
    try claimsCheck(F.idTokenClaims(exp: F.now.addingTimeInterval(-30)))
  }

  @Test("Wrong or missing nonce is refused")
  func nonce() {
    #expect(throws: V.ValidationError.nonceMismatch) {
      try claimsCheck(F.idTokenClaims(nonce: "replayed"))
    }
    #expect(throws: V.ValidationError.nonceMismatch) {
      try claimsCheck(F.idTokenClaims(nonce: nil))
    }
  }

  @Test("On reauthorization a different subject is refused")
  func subjectMismatch() {
    #expect(throws: V.ValidationError.subjectMismatch) {
      try claimsCheck(F.idTokenClaims(sub: "someone-else"), subject: "sub-123")
    }
  }

  @Test("A token that is not a JWT is malformed")
  func malformed() {
    #expect(throws: (any Error).self) {
      _ = try V.validateClaims(
        idToken: "not-a-jwt", expectedClientID: "x", expectedNonce: "y", now: F.now)
    }
  }

  // MARK: Signature

  private struct Signer {
    let privateKey: SecKey
    let jwk: V.JWK

    init() throws {
      let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
      ]
      var error: Unmanaged<CFError>?
      privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
      let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
      // PKCS#1 DER: SEQUENCE { INTEGER n, INTEGER e }.
      let der = try #require(SecKeyCopyExternalRepresentation(publicKey, &error) as Data?)
      let (n, e) = try Self.parsePKCS1(der)
      jwk = V.JWK(keyID: "k1", modulus: n, exponent: e)
      self.der = der
    }
    let der: Data

    static func parsePKCS1(_ der: Data) throws -> (Data, Data) {
      var index = der.startIndex
      func readLength() -> Int {
        let first = Int(der[index]); index += 1
        if first < 0x80 { return first }
        let count = first & 0x7f
        var length = 0
        for _ in 0..<count { length = (length << 8) | Int(der[index]); index += 1 }
        return length
      }
      func readInteger() -> Data {
        index += 1  // 0x02
        let length = readLength()
        var bytes = der[index..<index + length]
        index += length
        while bytes.first == 0 && bytes.count > 1 { bytes = bytes.dropFirst() }
        return Data(bytes)
      }
      index += 1  // 0x30
      _ = readLength()
      return (readInteger(), readInteger())
    }

    func sign(header: [String: Any] = ["alg": "RS256", "kid": "k1"], claims: [String: Any]) throws -> String {
      let unsigned = String(F.jwt(header: header, claims: claims).dropLast(5))  // drop ".c2ln"
      var error: Unmanaged<CFError>?
      let signature = try #require(
        SecKeyCreateSignature(
          privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(unsigned.utf8) as CFData, &error) as Data?)
      let encoded = signature.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
      return "\(unsigned).\(encoded)"
    }
  }

  @Test("DER encoding of n/e matches the key the system exported")
  func derEncoding() throws {
    let signer = try Signer()
    let rebuilt = V.derEncodeRSAPublicKey(modulus: signer.jwk.modulus, exponent: signer.jwk.exponent)
    #expect(rebuilt == signer.der)
  }

  @Test("A correctly signed RS256 token verifies")
  func signatureOK() throws {
    let signer = try Signer()
    let token = try signer.sign(claims: F.idTokenClaims())
    try V.verifyRS256(jwt: token, keys: [signer.jwk])
  }

  @Test("A tampered payload fails verification")
  func tampered() throws {
    let signer = try Signer()
    let token = try signer.sign(claims: F.idTokenClaims())
    let other = F.jwt(claims: F.idTokenClaims(sub: "attacker"))
    let forged = other.split(separator: ".").prefix(2).joined(separator: ".") + "." + token.split(separator: ".")[2]
    #expect(throws: V.ValidationError.signatureInvalid) {
      try V.verifyRS256(jwt: forged, keys: [signer.jwk])
    }
  }

  @Test("An unknown kid finds no key; a non-RS256 algorithm is refused")
  func keySelection() throws {
    let signer = try Signer()
    let unknownKid = try signer.sign(header: ["alg": "RS256", "kid": "nope"], claims: F.idTokenClaims())
    #expect(throws: V.ValidationError.keyNotFound) {
      try V.verifyRS256(jwt: unknownKid, keys: [signer.jwk])
    }
    let none = F.jwt(header: ["alg": "none", "kid": "k1"], claims: F.idTokenClaims())
    #expect(throws: (any Error).self) { try V.verifyRS256(jwt: none, keys: [signer.jwk]) }
  }

  @Test("JWKS parsing keeps RSA signing keys only")
  func jwks() throws {
    let json = """
      {"keys":[{"kty":"RSA","kid":"a","use":"sig","n":"AQAB","e":"AQAB"},
               {"kty":"EC","kid":"b"},{"kty":"RSA","kid":"c","use":"enc","n":"AQAB","e":"AQAB"}]}
      """
    let keys = try V.parseJWKS(Data(json.utf8))
    #expect(keys.map(\.keyID) == ["a"])
  }
}

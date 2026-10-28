import Foundation
import Security

/// Validates the OpenID Connect ID token issued by auth.openai.com after a ChatGPT sign-in:
/// RS256 signature against OpenAI's published JWKS, issuer, audience (the issued client id),
/// expiry and the nonce of this attempt. The validated `sub` is the account identity.
///
/// The signature step is injectable (`SignatureVerifier`) so unit tests can exercise claim
/// validation on unsigned tokens; production uses `verifyRS256(jwt:jwks:)`.
enum ChatGPTPlanIDTokenValidator {

  // MARK: Types

  struct Claims: Equatable {
    let issuer: String
    let audience: [String]
    let subject: String
    let expiresAt: Date
    let nonce: String?
    let email: String?
  }

  struct Header: Equatable {
    let algorithm: String
    let keyID: String?
  }

  enum ValidationError: LocalizedError, Equatable {
    case malformed
    case unsupportedAlgorithm(String)
    case missingClaim(String)
    case issuerMismatch
    case audienceMismatch
    case expired
    case nonceMismatch
    case subjectMismatch
    case signatureInvalid
    case keyNotFound
    case jwksUnavailable

    var errorDescription: String? {
      switch self {
      case .malformed: return String(localized: "ChatGPT returned an ID token that could not be read.")
      case .unsupportedAlgorithm(let alg): return String(localized: "ChatGPT signed the ID token with an unsupported algorithm (\(alg)).")
      case .missingClaim(let claim): return String(localized: "ChatGPT's ID token is missing \"\(claim)\".")
      case .issuerMismatch: return String(localized: "ChatGPT's ID token came from an unexpected issuer. Sign-in was refused.")
      case .audienceMismatch: return String(localized: "ChatGPT's ID token was issued for a different app. Sign-in was refused.")
      case .expired: return String(localized: "ChatGPT's ID token has already expired. Try signing in again.")
      case .nonceMismatch: return String(localized: "ChatGPT's sign-in response did not match this attempt. Try signing in again.")
      case .subjectMismatch:
        return String(localized: "That is a different ChatGPT account than the one saved for this app. Sign in with the same account, or use a different account instead.")
      case .signatureInvalid: return String(localized: "ChatGPT's ID token signature could not be verified. Sign-in was refused.")
      case .keyNotFound: return String(localized: "ChatGPT's signing key for this token was not found. Try signing in again.")
      case .jwksUnavailable: return String(localized: "Could not load ChatGPT's signing keys. Check your connection and try again.")
      }
    }
  }

  /// Verifies the signature of the whole compact JWT. Throws on failure.
  typealias SignatureVerifier = (_ jwt: String, _ header: Header) async throws -> Void

  /// Accepted clock skew when comparing `exp` with the local clock.
  static let clockSkew: TimeInterval = 60

  // MARK: Entry points

  /// Full validation: signature (via `verifySignature`), then claims. `expectedSubject` is set for a
  /// returning account and must equal the token's `sub`.
  @discardableResult
  static func validate(
    idToken: String,
    expectedClientID: String,
    expectedNonce: String,
    expectedSubject: String? = nil,
    now: Date = Date(),
    verifySignature: SignatureVerifier
  ) async throws -> Claims {
    let (header, _) = try decode(idToken)
    try await verifySignature(idToken, header)
    return try validateClaims(
      idToken: idToken, expectedClientID: expectedClientID, expectedNonce: expectedNonce,
      expectedSubject: expectedSubject, now: now)
  }

  /// Claim checks only (no signature): issuer, audience, expiry, nonce, optional subject.
  static func validateClaims(
    idToken: String,
    expectedClientID: String,
    expectedNonce: String,
    expectedSubject: String? = nil,
    now: Date = Date()
  ) throws -> Claims {
    let (_, claims) = try decode(idToken)
    guard claims.issuer == ChatGPTPlanOAuthConfig.issuer else { throw ValidationError.issuerMismatch }
    guard claims.audience.contains(expectedClientID) else { throw ValidationError.audienceMismatch }
    guard claims.expiresAt.timeIntervalSince(now) > -clockSkew else { throw ValidationError.expired }
    guard let nonce = claims.nonce, !nonce.isEmpty, nonce == expectedNonce else {
      throw ValidationError.nonceMismatch
    }
    if let expectedSubject, claims.subject != expectedSubject { throw ValidationError.subjectMismatch }
    return claims
  }

  // MARK: Decoding

  static func decode(_ jwt: String) throws -> (Header, Claims) {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let headerData = base64URLDecode(String(parts[0])),
      let payloadData = base64URLDecode(String(parts[1])),
      let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
      let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
    else { throw ValidationError.malformed }

    guard let alg = header["alg"] as? String else { throw ValidationError.missingClaim("alg") }
    guard let iss = payload["iss"] as? String else { throw ValidationError.missingClaim("iss") }
    guard let sub = payload["sub"] as? String, !sub.isEmpty else { throw ValidationError.missingClaim("sub") }
    guard let exp = (payload["exp"] as? NSNumber)?.doubleValue else { throw ValidationError.missingClaim("exp") }

    let audience: [String]
    if let single = payload["aud"] as? String {
      audience = [single]
    } else if let list = payload["aud"] as? [String] {
      audience = list
    } else {
      throw ValidationError.missingClaim("aud")
    }

    return (
      Header(algorithm: alg, keyID: header["kid"] as? String),
      Claims(
        issuer: iss, audience: audience, subject: sub,
        expiresAt: Date(timeIntervalSince1970: exp),
        nonce: payload["nonce"] as? String, email: payload["email"] as? String)
    )
  }

  static func base64URLDecode(_ string: String) -> Data? {
    var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder == 1 { return nil }
    if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: base64)
  }

  // MARK: Signature (production)

  /// One RSA key from a JWKS document.
  struct JWK: Equatable {
    let keyID: String?
    let modulus: Data
    let exponent: Data
  }

  /// Parses the RSA signing keys out of a JWKS document (`{"keys":[…]}`).
  static func parseJWKS(_ data: Data) throws -> [JWK] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let keys = root["keys"] as? [[String: Any]]
    else { throw ValidationError.jwksUnavailable }
    return keys.compactMap { key in
      guard (key["kty"] as? String) == "RSA",
        let n = (key["n"] as? String).flatMap(base64URLDecode),
        let e = (key["e"] as? String).flatMap(base64URLDecode)
      else { return nil }
      if let use = key["use"] as? String, use != "sig" { return nil }
      return JWK(keyID: key["kid"] as? String, modulus: n, exponent: e)
    }
  }

  /// Verifies an RS256 JWT against `keys`: picks the key by `kid` (or the only key when the token
  /// carries none), rebuilds the RSA public key from `n`/`e` and checks the PKCS#1 v1.5 SHA-256
  /// signature over `header.payload`.
  static func verifyRS256(jwt: String, keys: [JWK]) throws {
    let (header, _) = try decode(jwt)
    guard header.algorithm == "RS256" else { throw ValidationError.unsupportedAlgorithm(header.algorithm) }

    let candidates: [JWK]
    if let kid = header.keyID {
      candidates = keys.filter { $0.keyID == kid }
    } else {
      candidates = keys.count == 1 ? keys : []
    }
    guard let jwk = candidates.first else { throw ValidationError.keyNotFound }

    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let signature = base64URLDecode(String(parts[2])) else {
      throw ValidationError.malformed
    }
    let signedData = Data("\(parts[0]).\(parts[1])".utf8)

    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
    ]
    var error: Unmanaged<CFError>?
    guard
      let secKey = SecKeyCreateWithData(
        derEncodeRSAPublicKey(modulus: jwk.modulus, exponent: jwk.exponent) as CFData,
        attributes as CFDictionary, &error)
    else { throw ValidationError.signatureInvalid }

    guard
      SecKeyVerifySignature(
        secKey, .rsaSignatureMessagePKCS1v15SHA256, signedData as CFData, signature as CFData, &error)
    else { throw ValidationError.signatureInvalid }
  }

  /// PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }` in DER, the
  /// format `SecKeyCreateWithData` expects for an RSA public key.
  static func derEncodeRSAPublicKey(modulus: Data, exponent: Data) -> Data {
    let body = derInteger(modulus) + derInteger(exponent)
    return Data([0x30]) + derLength(body.count) + body
  }

  private static func derInteger(_ bigEndian: Data) -> Data {
    var bytes = Array(bigEndian.drop { $0 == 0 })
    if bytes.isEmpty { bytes = [0] }
    // A leading 1 bit would read as negative; DER wants an explicit 0x00 pad.
    if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
    return Data([0x02]) + derLength(bytes.count) + Data(bytes)
  }

  private static func derLength(_ length: Int) -> Data {
    if length < 0x80 { return Data([UInt8(length)]) }
    var octets: [UInt8] = []
    var remaining = length
    while remaining > 0 {
      octets.insert(UInt8(remaining & 0xff), at: 0)
      remaining >>= 8
    }
    return Data([0x80 | UInt8(octets.count)]) + Data(octets)
  }
}

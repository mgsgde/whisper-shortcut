import Foundation
@testable import WhisperShortcut_AppStore

/// Shared fixtures for the ChatGPT-plan tests.
enum ChatGPTPlanFixtures {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  static func credentials(
    clientID: String = "oaiapp_saved",
    subject: String = "sub-123",
    email: String = "me@example.com",
    idToken: String = "saved.id.token",
    accessToken: String? = "access-old",
    refreshToken: String? = "refresh-old",
    expiresAt: Date? = now.addingTimeInterval(3600),
    scopes: [String] = [
      "chatgpt.tokens.use.direct", "email", "offline_access", "openid", "profile", "resource.invoke",
    ]
  ) -> ChatGPTPlanCredentials {
    ChatGPTPlanCredentials(
      email: email, issuer: "https://auth.openai.com", subject: subject, clientID: clientID,
      extAgentHostID: "urn:uuid:11111111-1111-4111-8111-111111111111", idToken: idToken,
      accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, scopes: scopes,
      savedAt: now)
  }

  /// An unsigned compact JWT; the signature part is junk (claim tests never verify it).
  static func jwt(
    header: [String: Any] = ["alg": "RS256", "kid": "k1"],
    claims: [String: Any]
  ) -> String {
    func b64(_ object: [String: Any]) -> String {
      let data = try! JSONSerialization.data(withJSONObject: object)
      return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64(header)).\(b64(claims)).c2ln"
  }

  static func idTokenClaims(
    iss: String = "https://auth.openai.com", aud: Any = "oaiapp_saved", sub: String = "sub-123",
    exp: Date = now.addingTimeInterval(3600), nonce: String? = "nonce-1", email: String? = "me@example.com"
  ) -> [String: Any] {
    var claims: [String: Any] = [
      "iss": iss, "aud": aud, "sub": sub, "exp": Int(exp.timeIntervalSince1970),
    ]
    if let nonce { claims["nonce"] = nonce }
    if let email { claims["email"] = email }
    return claims
  }

  static func queryValue(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
  }

  static func queryNames(in url: URL) -> Set<String> {
    Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
  }
}

/// In-memory credential store.
final class MemoryChatGPTPlanStore: ChatGPTPlanCredentialStoring {
  var record: ChatGPTPlanCredentials?
  /// What another process wrote to the Keychain: `loadUncached()` sees it, the cached `load()` does not.
  var externalRecord: ChatGPTPlanCredentials?
  init(_ record: ChatGPTPlanCredentials? = nil) { self.record = record }
  func load() -> ChatGPTPlanCredentials? { record }
  func loadUncached() -> ChatGPTPlanCredentials? { externalRecord ?? record }
  func save(_ credentials: ChatGPTPlanCredentials) -> Bool {
    record = credentials
    externalRecord = nil
    return true
  }
  func delete() { record = nil }
}

/// Records every request and answers from a queue.
final class FakeTransport: @unchecked Sendable {
  struct Reply {
    let status: Int
    let body: String
  }
  private(set) var requests: [URLRequest] = []
  var replies: [Reply]
  init(_ replies: [Reply]) { self.replies = replies }

  func callAsFunction(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let reply = replies.isEmpty ? Reply(status: 500, body: "") : replies.removeFirst()
    let response = HTTPURLResponse(
      url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
    return (Data(reply.body.utf8), response)
  }

  var transport: ChatGPTPlanTransport { { [self] request in try await self(request) } }

  func formBody(at index: Int) -> [String: String] {
    guard let data = requests[index].httpBody, let text = String(data: data, encoding: .utf8) else { return [:] }
    var result: [String: String] = [:]
    for pair in text.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      result[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
    }
    return result
  }
}

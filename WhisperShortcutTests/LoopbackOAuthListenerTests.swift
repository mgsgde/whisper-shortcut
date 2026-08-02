import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Covers the HTTP request-line parsing that turns a browser redirect into an authorization code.
///
/// This is the whole reason the loopback listener exists, and it is hand-rolled parsing of bytes
/// off a socket — if it returns nil the sign-in hangs with no error, which is exactly the symptom
/// the custom-URL-scheme attempt produced.
@Suite("Loopback OAuth listener")
struct LoopbackOAuthListenerTests {

  private func request(_ line: String) -> Data {
    Data("\(line)\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
  }

  @Test("Extracts the authorization code from a redirect")
  func extractsCode() throws {
    let parsed = try #require(
      LoopbackOAuthListener.parseRequestTarget(
        request("GET /openrouter-callback?code=abc123 HTTP/1.1")))
    #expect(parsed.queryItems?.first { $0.name == "code" }?.value == "abc123")
  }

  @Test("Handles extra query parameters and percent-encoding")
  func handlesExtraParameters() throws {
    let parsed = try #require(
      LoopbackOAuthListener.parseRequestTarget(
        request("GET /openrouter-callback?state=x%2Fy&code=a-b_c HTTP/1.1")))
    #expect(parsed.queryItems?.first { $0.name == "code" }?.value == "a-b_c")
    #expect(parsed.queryItems?.first { $0.name == "state" }?.value == "x/y")
  }

  @Test("A redirect without a code parses but yields none, so the flow can report an error")
  func noCodeParsesCleanly() throws {
    let parsed = try #require(
      LoopbackOAuthListener.parseRequestTarget(request("GET /openrouter-callback HTTP/1.1")))
    #expect(parsed.queryItems?.first { $0.name == "code" }?.value == nil)
  }

  @Test("Non-GET and malformed request lines are rejected rather than half-parsed")
  func rejectsMalformedRequests() {
    #expect(LoopbackOAuthListener.parseRequestTarget(request("POST /openrouter-callback HTTP/1.1")) == nil)
    #expect(LoopbackOAuthListener.parseRequestTarget(request("GET")) == nil)
    #expect(LoopbackOAuthListener.parseRequestTarget(Data()) == nil)
  }
}

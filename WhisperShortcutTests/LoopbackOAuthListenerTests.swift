import Darwin
import Foundation
import Testing
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

  @Test("A custom callback path and provider name reach the listener and the browser page")
  func customPathAndProviderName() throws {
    let listener = try LoopbackOAuthListener(callbackPath: "/auth/callback", providerName: "ChatGPT") { _ in }
    defer { listener.stop() }
    #expect(listener.callbackURL.hasPrefix("http://127.0.0.1:"))
    #expect(listener.callbackURL.hasSuffix("/auth/callback"))

    let page = String(decoding: LoopbackOAuthListener.httpResponse(success: true, providerName: "ChatGPT"), as: UTF8.self)
    #expect(page.contains("WhisperShortcut has your ChatGPT connection"))
    let defaultPage = String(decoding: LoopbackOAuthListener.httpResponse(success: true), as: UTF8.self)
    #expect(defaultPage.contains("OpenRouter connection"))
  }

  @Test("A browser GET is answered with the connection page and delivers the code")
  func servesRedirect() async throws {
    let gate = Gate()
    let listener = try LoopbackOAuthListener { gate.deliver($0) }
    defer { listener.stop() }
    let timeout = Task {
      try await Task.sleep(for: .seconds(3))
      gate.fail(ServeError.timeout)
    }
    defer { timeout.cancel() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      gate.arm(continuation)
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          gate.notePage(try Self.poke(listener.callbackURL))
        } catch {
          gate.fail(error)
        }
      }
    }
    #expect(gate.page.contains("HTTP/1.1 200"))
    #expect(gate.page.contains("OpenRouter connection"))
    #expect(gate.components?.queryItems?.first { $0.name == "code" }?.value == "abc123")
    #expect(gate.components?.queryItems?.first { $0.name == "state" }?.value == "s")
  }

  private enum ServeError: Error {
    case timeout
    case connectFailed
    case shortResponse
  }

  /// Resumes once both the HTTP page and the listener callback have arrived.
  private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var resumed = false
    private var havePage = false
    private var haveCallback = false
    var page = ""
    var components: URLComponents?

    func arm(_ continuation: CheckedContinuation<Void, Error>) {
      lock.lock()
      self.continuation = continuation
      lock.unlock()
    }

    func deliver(_ components: URLComponents?) {
      lock.lock()
      self.components = components
      haveCallback = true
      let done = finishLocked()
      lock.unlock()
      done?()
    }

    func fail(_ error: Error) {
      lock.lock()
      guard !resumed, let continuation else { lock.unlock(); return }
      resumed = true
      self.continuation = nil
      lock.unlock()
      continuation.resume(throwing: error)
    }

    /// Called from the poke thread. The assignment is visible to the test because `finish` resumes
    /// only after both sides have stored their results.
    fileprivate func notePage(_ text: String) {
      lock.lock()
      page = text
      havePage = true
      let done = finishLocked()
      lock.unlock()
      done?()
    }

    private func finishLocked() -> (() -> Void)? {
      guard !resumed, havePage, haveCallback, let continuation else { return nil }
      resumed = true
      self.continuation = nil
      return { continuation.resume() }
    }
  }

  private static func poke(_ callbackURL: String) throws -> String {
    guard let url = URL(string: callbackURL), let port = url.port else { throw ServeError.connectFailed }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ServeError.connectFailed }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else { throw ServeError.connectFailed }
    let payload = "GET \(url.path)?code=abc123&state=s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    let bytes = Array(payload.utf8)
    let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    guard sent == bytes.count else { throw ServeError.shortResponse }
    var collected = Data()
    while collected.count < 8192 {
      var buffer = [UInt8](repeating: 0, count: 2048)
      let n = recv(fd, &buffer, buffer.count, 0)
      if n <= 0 { break }
      collected.append(buffer, count: n)
    }
    guard !collected.isEmpty else { throw ServeError.shortResponse }
    return String(decoding: collected, as: UTF8.self)
  }
}

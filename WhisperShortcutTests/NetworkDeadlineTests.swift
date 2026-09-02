import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins the stall detector that sits in front of OpenAI-compatible transcription.
///
/// I2's hangs (3.5–12.8 min in `transcribing`) happened because `URLSession`'s
/// timers did not fire. These tests drive `NetworkDeadline` through a `URLProtocol`
/// stub so they never touch the network, and they fail if the production cap
/// drifts back above the 120s falsifier.
@Suite("Network deadline")
struct NetworkDeadlineTests {

  // MARK: - Production cap

  @Test("The transcription cap is 60s — under the 120s cancelledWhileProcessing falsifier")
  func transcriptionTimeoutIsUnderFalsifier() {
    #expect(NetworkDeadline.transcriptionRequestTimeout == 60)
    #expect(NetworkDeadline.transcriptionRequestTimeout <= 120)
  }

  // MARK: - Hang → timeout

  /// Never delivers a response. Cancellation arrives via `stopLoading`.
  final class HangProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
  }

  @Test("A request that never responds fails with requestTimeout instead of hanging")
  func hangingRequestTimesOut() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HangProtocol.self]
    // URLSession's own timers must be longer than the deadline under test, otherwise
    // a native timedOut could win and hide a broken Task deadline.
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 300
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let request = URLRequest(url: URL(string: "https://deadline.test/v1/audio/transcriptions")!)
    let started = Date()
    await #expect(throws: TranscriptionError.requestTimeout) {
      _ = try await NetworkDeadline.data(for: request, session: session, timeout: 0.25)
    }
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed < 2, "deadline took \(elapsed)s; the hang path is still blocking")
  }

  // MARK: - Fast success

  final class StubProtocol: URLProtocol {
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]
    private static let lock = NSLock()

    static func register(body: Data) -> URL {
      let url = URL(string: "https://deadline.test/\(UUID().uuidString)")!
      lock.lock()
      bodies[url.absoluteString] = body
      lock.unlock()
      return url
    }

    private static func body(for url: URL?) -> Data? {
      guard let key = url?.absoluteString else { return nil }
      lock.lock()
      defer { lock.unlock() }
      return bodies[key]
    }

    override class func canInit(with request: URLRequest) -> Bool {
      body(for: request.url) != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      guard let url = request.url, let body = Self.body(for: url) else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }

  @Test("A response that arrives before the deadline is returned unchanged")
  func fastResponseSucceeds() async throws {
    let body = Data(#"{"text":"hello"}"#.utf8)
    let url = StubProtocol.register(body: body)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let (data, response) = try await NetworkDeadline.data(
      for: URLRequest(url: url), session: session, timeout: 5)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(data == body)
  }

  // MARK: - Native URLSession timeout mapping

  final class TimedOutProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
  }

  final class NotConnectedProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
  }

  @Test("A URLSession-native notConnectedToInternet is surfaced as TranscriptionError.networkError")
  func nativeDisconnectMapsToNetworkError() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NotConnectedProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let request = URLRequest(url: URL(string: "https://deadline.test/offline")!)
    do {
      _ = try await NetworkDeadline.data(for: request, session: session, timeout: 5)
      Issue.record("expected networkError")
    } catch TranscriptionError.networkError {
      // retryable, audio retained
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test("A URLSession-native timedOut is surfaced as TranscriptionError.requestTimeout")
  func nativeTimedOutMapsToRequestTimeout() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TimedOutProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let request = URLRequest(url: URL(string: "https://deadline.test/timeout")!)
    await #expect(throws: TranscriptionError.requestTimeout) {
      _ = try await NetworkDeadline.data(for: request, session: session, timeout: 5)
    }
  }

  // MARK: - User-visible error

  @Test("requestTimeout formats as a visible timeout, not a generic network error")
  func requestTimeoutIsUserVisible() {
    let message = SpeechErrorFormatter.format(.requestTimeout)
    #expect(message.contains("Timeout"))
    #expect(message.contains("too long"))
    // Must not pin the copy to Gemini — OpenAI GPT-Transcribe throws this too.
    #expect(!message.lowercased().contains("google"))
    #expect(SpeechErrorFormatter.shortStatus(.requestTimeout).contains("Timeout"))
  }
}

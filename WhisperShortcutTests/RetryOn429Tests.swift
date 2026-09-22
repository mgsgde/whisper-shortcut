import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The shared 429 branch in `SpeechService.performWithRetryOn429`.
///
/// A spend-cap body (`insufficient_quota`) must come back on the first response, with no sleep.
/// A transient 429 must be asked again. No network: a `URLProtocol` stub replays canned bodies,
/// keyed by URL so swift-testing's parallel runners cannot cross wires.
@Suite("Retry on HTTP 429")
struct RetryOn429Tests {

  final class SequencedStub: URLProtocol {
    struct Step {
      let status: Int
      let body: String
    }

    private struct Script {
      var steps: [Step]
      var hits = 0
    }

    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    private static let lock = NSLock()

    /// Registers `steps` and returns the unique endpoint that serves them, in order.
    static func register(_ steps: [Step]) -> URL {
      let url = URL(string: "https://retry-stub.invalid/\(UUID().uuidString)")!
      lock.lock()
      scripts[url.absoluteString] = Script(steps: steps)
      lock.unlock()
      return url
    }

    static func hits(for url: URL) -> Int {
      lock.lock()
      defer { lock.unlock() }
      return scripts[url.absoluteString]?.hits ?? 0
    }

    private static func next(for url: URL?) -> Step? {
      guard let key = url?.absoluteString else { return nil }
      lock.lock()
      defer { lock.unlock() }
      guard var script = scripts[key], !script.steps.isEmpty else { return nil }
      let index = min(script.hits, script.steps.count - 1)
      script.hits += 1
      scripts[key] = script
      return script.steps[index]
    }

    override class func canInit(with request: URLRequest) -> Bool {
      guard let key = request.url?.absoluteString else { return false }
      lock.lock()
      defer { lock.unlock() }
      return scripts[key] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      guard let step = Self.next(for: request.url), let url = request.url else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      let response = HTTPURLResponse(
        url: url, statusCode: step.status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(step.body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }

  private static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SequencedStub.self]
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }

  private static func request(url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    return request
  }

  /// OpenAI's "no credit" 429. Retrying it only delays the billing error.
  @Test("An insufficient_quota 429 returns immediately without a second attempt")
  func permanentQuotaDoesNotRetry() async throws {
    let body = #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}"#
    let url = SequencedStub.register([.init(status: 429, body: body)])
    let clock = ContinuousClock()
    let started = clock.now

    let (data, http) = try await SpeechService.performWithRetryOn429(
      request: Self.request(url: url), session: Self.session(), logPrefix: "TEST-429")

    let elapsed = started.duration(to: clock.now)
    #expect(http.statusCode == 429)
    #expect(String(data: data, encoding: .utf8) == body)
    #expect(SequencedStub.hits(for: url) == 1)
    // The transient path sleeps `retryDelaySeconds` (1.5s). Anything under a second did not.
    #expect(elapsed < .seconds(1))
  }

  /// Same short-circuit when the body is read as a byte stream (`onPartial != nil`).
  @Test("An insufficient_quota 429 on the streaming path also returns without retrying")
  func permanentQuotaDoesNotRetryWhenStreaming() async throws {
    let body = #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}"#
    let url = SequencedStub.register([.init(status: 429, body: body)])
    let clock = ContinuousClock()
    let started = clock.now
    var partials: [Data] = []

    let (data, http) = try await SpeechService.performWithRetryOn429(
      request: Self.request(url: url), session: Self.session(), logPrefix: "TEST-429-STREAM",
      onPartial: { partials.append($0) })

    let elapsed = started.duration(to: clock.now)
    #expect(http.statusCode == 429)
    #expect(String(data: data, encoding: .utf8) == body)
    #expect(partials.isEmpty)
    #expect(SequencedStub.hits(for: url) == 1)
    #expect(elapsed < .seconds(1))
  }

  @Test("A transient 429 is retried and the later response is the one returned")
  func transient429IsRetried() async throws {
    let url = SequencedStub.register([
      .init(status: 429, body: #"{"error":{"code":"rate_limit_exceeded"}}"#),
      .init(status: 200, body: "pcm-bytes"),
    ])

    let (data, http) = try await SpeechService.performWithRetryOn429(
      request: Self.request(url: url), session: Self.session(), logPrefix: "TEST-429")

    #expect(http.statusCode == 200)
    #expect(String(data: data, encoding: .utf8) == "pcm-bytes")
    #expect(SequencedStub.hits(for: url) == 2)
  }
}

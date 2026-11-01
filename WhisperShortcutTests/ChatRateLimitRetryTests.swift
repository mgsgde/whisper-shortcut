import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Chat 429s for Claude, OpenAI, OpenRouter, Grok, an own server, and a local server.
///
/// A delay advertised on the response is a spike the pre-first-token loop may wait out.
/// No delay, an `insufficient_quota` body, or a wait past the automatic ceiling is not.
/// No network: header tests build an `HTTPURLResponse` in memory, and the retry test
/// replays canned bodies through a `URLProtocol` stub keyed by URL.
@Suite("Chat rate-limit retry")
struct ChatRateLimitRetryTests {

  private static func http(
    _ headers: [String: String], status: Int = 429
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: "https://stub.invalid/v1/chat/completions")!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: headers)!
  }

  private static func utc(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int
  ) -> Date {
    var comps = DateComponents()
    comps.calendar = Calendar(identifier: .gregorian)
    comps.timeZone = TimeZone(secondsFromGMT: 0)
    comps.year = year
    comps.month = month
    comps.day = day
    comps.hour = hour
    comps.minute = minute
    comps.second = second
    return comps.date!
  }

  // MARK: - Header parsing

  @Test("Retry-After seconds, including surrounding whitespace")
  func retryAfterSeconds() {
    let response = Self.http(["Retry-After": "  12  "])
    #expect(RetryBackoff.retryAfter(from: response) == 12)
  }

  @Test("retry-after-ms is milliseconds")
  func retryAfterMilliseconds() {
    let response = Self.http(["retry-after-ms": "2500"])
    #expect(RetryBackoff.retryAfter(from: response) == 2.5)
  }

  @Test("Retry-After HTTP-date is the delay until that instant")
  func retryAfterHTTPDate() {
    // 21 Oct 2015 07:28:00 GMT is the RFC 9110 example's shape; the wait is measured from `now`.
    let now = Self.utc(2015, 10, 21, 7, 27, 45)
    let response = Self.http(["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"])
    #expect(RetryBackoff.retryAfter(from: response, now: now) == 15)
  }

  @Test("A response with no rate-limit header has no delay")
  func retryAfterMissing() {
    #expect(RetryBackoff.retryAfter(from: Self.http([:])) == nil)
    #expect(RetryBackoff.retryAfter(from: Self.http(["Content-Type": "application/json"])) == nil)
  }

  @Test("An unparseable Retry-After falls through to retry-after-ms; a numeric one wins")
  func retryAfterPrecedence() {
    let fallback = Self.http(["Retry-After": "soon", "retry-after-ms": "1500"])
    #expect(RetryBackoff.retryAfter(from: fallback) == 1.5)
    let secondsWin = Self.http(["Retry-After": "4", "retry-after-ms": "9000"])
    #expect(RetryBackoff.retryAfter(from: secondsWin) == 4)
  }

  @Test("Anthropic's soonest ratelimit reset is the delay; a non-reset header is ignored")
  func anthropicReset() {
    let now = Self.utc(2026, 11, 1, 0, 0, 0)
    let one = Self.http(["anthropic-ratelimit-requests-reset": "2026-11-01T00:00:05Z"])
    #expect(RetryBackoff.retryAfter(from: one, now: now) == 5)
    let two = Self.http([
      "anthropic-ratelimit-tokens-reset": "2026-11-01T00:00:20Z",
      "anthropic-ratelimit-requests-reset": "2026-11-01T00:00:05Z",
    ])
    #expect(RetryBackoff.retryAfter(from: two, now: now) == 5)
    let notAReset = Self.http(["anthropic-ratelimit-requests-limit": "2026-11-01T00:00:05Z"])
    #expect(RetryBackoff.retryAfter(from: notAReset, now: now) == nil)
  }

  // MARK: - Classification

  @Test("A 429 with Retry-After is a transient rate limit")
  func retryAfterIsTransient() {
    let err = ChatProviderHTTPError.map(
      provider: "OpenAI", status: 429, body: #"{"error":{"message":"Rate limit reached"}}"#,
      response: Self.http(["Retry-After": "3"]))
    #expect(err as? TranscriptionError == .rateLimited(retryAfter: 3))
    #expect(RetryBackoff.isTransientPreFirstToken(err))
    #expect(!RetryBackoff.isPermanentRateLimit(err))
  }

  @Test("A 429 with no delay stays permanent")
  func missingDelayStaysPermanent() {
    let err = ChatProviderHTTPError.map(
      provider: "OpenAI", status: 429, body: #"{"error":{"message":"Rate limit reached"}}"#,
      response: Self.http([:]))
    #expect(err as? TranscriptionError == .rateLimited(retryAfter: nil))
    #expect(!RetryBackoff.isTransientPreFirstToken(err))
    #expect(RetryBackoff.isPermanentRateLimit(err))
  }

  @Test("A Retry-After past the automatic-wait ceiling is kept and not retried")
  func retryAfterPastCapIsNotTransient() {
    let tooLong = RetryBackoff.maxAutomaticRetryWait + 50
    let err = ChatProviderHTTPError.map(
      provider: "OpenAI", status: 429, body: "Rate limit reached",
      response: Self.http(["Retry-After": String(tooLong)]))
    #expect(err as? TranscriptionError == .rateLimited(retryAfter: tooLong))
    #expect(!RetryBackoff.isTransientPreFirstToken(err))
  }

  @Test("insufficient_quota stays a billing error even when Retry-After is set")
  func insufficientQuotaStaysPermanent() {
    let body = #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}"#
    let err = ChatProviderHTTPError.map(
      provider: "OpenAI", status: 429, body: body,
      response: Self.http(["Retry-After": "3"]))
    guard case TranscriptionError.billingRequired(let topUpURL) = err else {
      Issue.record("expected billingRequired, got \(err)")
      return
    }
    #expect(topUpURL == TranscriptionError.openAIBillingURL)
    #expect(!RetryBackoff.isTransientPreFirstToken(err))
  }

  @Test("Claude's mapper keeps an anthropic reset, via the same HTTP mapping")
  func claudeMapperReadsTheResponse() {
    let err = AnthropicChatProvider.mapHTTPError(
      response: Self.http(["Retry-After": "6"]),
      body: #"{"type":"error","error":{"message":"rate limit"}}"#)
    #expect(err as? TranscriptionError == .rateLimited(retryAfter: 6))
    #expect(RetryBackoff.isTransientPreFirstToken(err))
  }

  @Test("Grok keeps Retry-After on a spike and ignores it when credits are exhausted")
  func grok429() {
    let spike = GrokChatProvider.classifyXAI429(
      body: "Too many requests", response: Self.http(["Retry-After": "4"]))
    #expect(spike == .rateLimited(retryAfter: 4))
    #expect(RetryBackoff.isTransientPreFirstToken(spike))

    let exhausted = GrokChatProvider.classifyXAI429(
      body: "Your team has reached its monthly spending limit",
      response: Self.http(["Retry-After": "4"]))
    guard case TranscriptionError.networkError = exhausted else {
      Issue.record("expected the credits error, got \(exhausted)")
      return
    }
    #expect(!RetryBackoff.isTransientPreFirstToken(exhausted))
  }

  // MARK: - Pre-first-token retry

  /// Replays `steps` in order for one endpoint. A later hit past the end repeats the last step,
  /// so an extra retry still shows up in `hits`.
  final class SequencedStub: URLProtocol {
    struct Step {
      let status: Int
      let body: String
      var headers: [String: String] = [:]
    }

    private struct Script {
      var steps: [Step]
      var hits = 0
    }

    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    private static let lock = NSLock()

    static func register(_ steps: [Step]) -> String {
      let endpoint = "https://chat-429-stub.invalid/\(UUID().uuidString)/v1/chat/completions"
      lock.lock()
      scripts[endpoint] = Script(steps: steps)
      lock.unlock()
      return endpoint
    }

    static func hits(for endpoint: String) -> Int {
      lock.lock()
      defer { lock.unlock() }
      return scripts[endpoint]?.hits ?? 0
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
      var headers = step.headers
      if headers["Content-Type"] == nil { headers["Content-Type"] = "text/event-stream" }
      let response = HTTPURLResponse(
        url: url, statusCode: step.status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(step.body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }

  private static let okSSE = """
    data: {"choices":[{"delta":{"content":"ok"}}]}

    data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """

  private static func collect(
    _ endpoint: String
  ) async throws -> [ChatStreamEvent] {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SequencedStub.self]
    configuration.urlCache = nil
    let config = OpenAICompatibleStream.Config(
      endpoint: endpoint,
      headers: [:],
      logTag: "TEST-CHAT-429",
      mapHTTPError: { response, body in
        ChatProviderHTTPError.map(
          provider: "OpenAI", status: response.statusCode, body: body, response: response)
      },
      session: URLSession(configuration: configuration))
    var events: [ChatStreamEvent] = []
    for try await event in OpenAICompatibleStream.chatCompletions(config, body: [:]) {
      events.append(event)
    }
    return events
  }

  private static func text(in events: [ChatStreamEvent]) -> String {
    events.reduce(into: "") { acc, event in
      if case .textDelta(let delta) = event { acc += delta }
    }
  }

  @Test("A 429 with Retry-After is retried once before the first token")
  func transient429IsRetriedOnce() async throws {
    let endpoint = SequencedStub.register([
      .init(status: 429, body: #"{"error":{"message":"Rate limit reached"}}"#, headers: ["Retry-After": "0"]),
      .init(status: 200, body: Self.okSSE),
    ])
    let clock = ContinuousClock()
    let started = clock.now

    let events = try await Self.collect(endpoint)

    #expect(Self.text(in: events) == "ok")
    #expect(SequencedStub.hits(for: endpoint) == 2)
    // The no-header path does not retry; a retry that ignored the header would sleep the 1s base.
    #expect(started.duration(to: clock.now) < .seconds(1))
  }

  @Test("An insufficient_quota 429 is not retried, header or not")
  func insufficientQuotaIsNotRetried() async {
    let body = #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}"#
    let endpoint = SequencedStub.register([
      .init(status: 429, body: body, headers: ["Retry-After": "0"]),
    ])
    let clock = ContinuousClock()
    let started = clock.now

    await #expect(throws: TranscriptionError.billingRequired(topUpURL: TranscriptionError.openAIBillingURL)) {
      _ = try await Self.collect(endpoint)
    }
    #expect(SequencedStub.hits(for: endpoint) == 1)
    #expect(started.duration(to: clock.now) < .seconds(1))
  }

  @Test("A 429 whose Retry-After exceeds the wait ceiling is not retried")
  func overCap429IsNotRetried() async {
    let tooLong = RetryBackoff.maxAutomaticRetryWait + 50
    let endpoint = SequencedStub.register([
      .init(
        status: 429, body: #"{"error":{"message":"Rate limit reached"}}"#,
        headers: ["Retry-After": String(tooLong)]),
      .init(status: 200, body: Self.okSSE),
    ])
    let clock = ContinuousClock()
    let started = clock.now

    await #expect(throws: TranscriptionError.rateLimited(retryAfter: tooLong)) {
      _ = try await Self.collect(endpoint)
    }
    #expect(SequencedStub.hits(for: endpoint) == 1)
    #expect(started.duration(to: clock.now) < .seconds(1))
  }
}

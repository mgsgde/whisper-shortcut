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

  struct RetryAfterParse: Sendable {
    let note: String
    let headers: [String: String]
    let expected: TimeInterval?
    var now: Date? = nil
  }

  @Test("Retry-After is read from seconds, milliseconds, an HTTP-date, or not at all", arguments: [
    RetryAfterParse(note: "seconds, including surrounding whitespace", headers: ["Retry-After": "  12  "], expected: 12),
    RetryAfterParse(note: "retry-after-ms is milliseconds", headers: ["retry-after-ms": "2500"], expected: 2.5),
    // 21 Oct 2015 07:28:00 GMT is the RFC 9110 example's shape; the wait is measured from `now`.
    RetryAfterParse(
      note: "HTTP-date is the delay until that instant",
      headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"],
      expected: 15, now: Self.utc(2015, 10, 21, 7, 27, 45)),
    RetryAfterParse(note: "no headers", headers: [:], expected: nil),
    RetryAfterParse(note: "an unrelated header is not a delay", headers: ["Content-Type": "application/json"], expected: nil),
    RetryAfterParse(
      note: "an unparseable Retry-After falls through to retry-after-ms",
      headers: ["Retry-After": "soon", "retry-after-ms": "1500"], expected: 1.5),
    RetryAfterParse(
      note: "a numeric Retry-After wins over retry-after-ms",
      headers: ["Retry-After": "4", "retry-after-ms": "9000"], expected: 4),
  ])
  func retryAfterParsing(_ row: RetryAfterParse) {
    let response = Self.http(row.headers)
    let got: TimeInterval?
    if let now = row.now {
      got = RetryBackoff.retryAfter(from: response, now: now)
    } else {
      got = RetryBackoff.retryAfter(from: response)
    }
    #expect(got == row.expected, "\(row.note)")
  }

  @Test("Stored delay is raw; the skew buffer is applied only when sleeping")
  func absoluteWaitsGetSkewBufferOnlyWhenSleeping() {
    let now = Self.utc(2015, 10, 21, 7, 27, 45)
    // Client clock runs 30s fast: the server's date is already "in the past" for us.
    let fast = Self.utc(2015, 10, 21, 7, 28, 15)
    let date = Self.http(["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"])
    #expect(RetryBackoff.retryAfter(from: date, now: fast) == 0)
    let reset = Self.http(["anthropic-ratelimit-requests-reset": "2015-10-21T07:28:00Z"])
    #expect(RetryBackoff.retryAfter(from: reset, now: fast) == 0)
    #expect(RetryBackoff.retryAfter(from: Self.http(["Retry-After": "12"]), now: now) == 12)
    #expect(RetryBackoff.clockSkewBuffer == 2)
    // End to end: the sleep for a past absolute date is the buffer, not the 1s hot-retry floor.
    let err = RetryBackoff.rateLimitedError(from: date, now: fast)
    #expect(err.retryAfterIsAbsolute)
    #expect(RetryBackoff.preFirstTokenDelay(attempt: 1, error: err) == 2)
    let resetErr = RetryBackoff.rateLimitedError(from: reset, now: fast)
    #expect(resetErr.retryAfterIsAbsolute)
    #expect(RetryBackoff.preFirstTokenDelay(attempt: 1, error: resetErr) == 2)
  }

  @Test("Delta-seconds delays are not buffered: Retry-After 7 sleeps 7, 0 keeps the 1s floor")
  func deltaWaitsAreNotBuffered() {
    let now = Self.utc(2015, 10, 21, 7, 27, 45)
    let seven = RetryBackoff.rateLimitedError(from: Self.http(["Retry-After": "7"]), now: now)
    let zero = RetryBackoff.rateLimitedError(from: Self.http(["Retry-After": "0"]), now: now)
    let ms = RetryBackoff.rateLimitedError(from: Self.http(["retry-after-ms": "2500"]), now: now)
    #expect(!seven.retryAfterIsAbsolute && !zero.retryAfterIsAbsolute && !ms.retryAfterIsAbsolute)
    #expect(RetryBackoff.preFirstTokenDelay(attempt: 1, error: seven) == 7)
    #expect(RetryBackoff.preFirstTokenDelay(attempt: 1, error: zero) == RetryBackoff.minAutomaticRetryWait)
    #expect(RetryBackoff.preFirstTokenDelay(attempt: 1, error: ms) == 2.5)
    // Provenance is parsed from the same headers as the seconds.
    #expect(RetryBackoff.serverDelay(from: Self.http(["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]), now: now)?.isAbsolute == true)
    #expect(RetryBackoff.serverDelay(from: Self.http(["Retry-After": "12"]), now: now)?.isAbsolute == false)
    #expect(RetryBackoff.serverDelay(from: Self.http([:]), now: now) == nil)
    #expect(RetryBackoff.rateLimitedError(from: Self.http([:])) == .rateLimited(retryAfter: nil))
    #expect(RetryBackoff.rateLimitedError(from: nil) == .rateLimited(retryAfter: nil))
  }

  @Test("An absolute reset ~60s away stays transient and sleeps ~62s")
  func absoluteSixtySecondResetIsTransient() {
    let now = Self.utc(2026, 11, 1, 0, 0, 0)
    let date = Self.http(["Retry-After": "Sun, 01 Nov 2026 00:01:00 GMT"])
    let reset = Self.http(["anthropic-ratelimit-tokens-remaining": "0",
                           "anthropic-ratelimit-tokens-reset": "2026-11-01T00:01:00Z"])
    for response in [date, reset] {
      let wait = RetryBackoff.retryAfter(from: response, now: now)
      #expect(wait == 60)
      let err = RetryBackoff.rateLimitedError(from: response, now: now)
      #expect(RetryBackoff.isTransientPreFirstToken(err))
      #expect(RetryBackoff.preFirstTokenDelay(attempt: 1, error: err) == 62)
    }
    // Past the ceiling on the raw delta is still rejected.
    let tooLong = Self.http(["Retry-After": "Sun, 01 Nov 2026 00:01:01 GMT"])
    let err = RetryBackoff.rateLimitedError(from: tooLong, now: now)
    #expect(!RetryBackoff.isTransientPreFirstToken(err))
  }

  struct AnthropicReset: Sendable {
    let note: String
    let headers: [String: String]
    let expected: TimeInterval?
  }

  @Test("Anthropic reset uses the exhausted bucket, else the latest, and ignores non-reset headers", arguments: [
    AnthropicReset(
      note: "a lone bucket",
      headers: ["anthropic-ratelimit-requests-reset": "2026-11-01T00:00:05Z"], expected: 5),
    AnthropicReset(
      note: "the latest when none reports remaining",
      headers: [
        "anthropic-ratelimit-tokens-reset": "2026-11-01T00:00:20Z",
        "anthropic-ratelimit-requests-reset": "2026-11-01T00:00:05Z",
      ], expected: 20),
    AnthropicReset(
      note: "a non-reset header is ignored",
      headers: ["anthropic-ratelimit-requests-limit": "2026-11-01T00:00:05Z"], expected: nil),
    AnthropicReset(
      note: "waits for the exhausted tokens bucket, not the sooner requests reset",
      headers: [
        "anthropic-ratelimit-requests-remaining": "5",
        "anthropic-ratelimit-requests-reset": "2026-11-01T00:00:05Z",
        "anthropic-ratelimit-tokens-remaining": "0",
        "anthropic-ratelimit-tokens-reset": "2026-11-01T00:00:40Z",
      ], expected: 40),
    AnthropicReset(
      note: "waits for the exhausted requests bucket",
      headers: [
        "anthropic-ratelimit-requests-remaining": "0",
        "anthropic-ratelimit-requests-reset": "2026-11-01T00:00:05Z",
        "anthropic-ratelimit-tokens-remaining": "9000",
        "anthropic-ratelimit-tokens-reset": "2026-11-01T00:00:40Z",
      ], expected: 5),
    AnthropicReset(
      note: "both buckets exhausted: the later reset wins",
      headers: [
        "anthropic-ratelimit-requests-remaining": "0",
        "anthropic-ratelimit-requests-reset": "2026-11-01T00:00:05Z",
        "anthropic-ratelimit-tokens-remaining": "0",
        "anthropic-ratelimit-tokens-reset": "2026-11-01T00:00:40Z",
      ], expected: 40),
  ])
  func anthropicReset(_ row: AnthropicReset) {
    let now = Self.utc(2026, 11, 1, 0, 0, 0)
    #expect(RetryBackoff.retryAfter(from: Self.http(row.headers), now: now) == row.expected, "\(row.note)")
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

  // MARK: - Retry delay

  @Test("A 60s Retry-After window is transient; the displayed wait is floored")
  func sixtySecondWindowAndDisplayedFloor() {
    #expect(RetryBackoff.isTransientPreFirstToken(TranscriptionError.rateLimited(retryAfter: 60)))
    #expect(RetryBackoff.displayedWaitSeconds(0) == 1)
    #expect(RetryBackoff.displayedWaitSeconds(0.4) == 1)
    #expect(RetryBackoff.displayedWaitSeconds(12.9) == 12)
    let message = SpeechErrorFormatter.format(.rateLimited(retryAfter: 0))
    #expect(message.contains("wait 1 seconds"))
    #expect(!message.contains("wait 0 seconds"))
    #expect(SpeechErrorFormatter.format(.quotaExceeded(retryAfter: 0)).contains("wait 1 seconds"))
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

  @Test("A 429 with Retry-After: 0 is retried once, after the minimum wait")
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
    // Delta `Retry-After: 0` is floored at `minAutomaticRetryWait` (1s, no skew buffer), not retried hot.
    #expect(started.duration(to: clock.now) >= .milliseconds(900))
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

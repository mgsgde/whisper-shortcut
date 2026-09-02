import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Offline tests for the SSE parser shared by the OpenAI, Grok, and local providers.
///
/// This parser used to exist as three verbatim copies, one per provider. These tests are the
/// equivalence lock for the consolidation: they pin the exact event sequence the old per-provider
/// copies produced, including the fiddly parts (fragmented tool-call arguments, `index`-keyed
/// ordering with double-digit indices, positional `call_<n>` fallback) and the provider-specific
/// error mapping that stayed behind in each `Config`.
///
/// No network: a `URLProtocol` stub replays a canned response body, so these run in every
/// environment regardless of which API keys are present.
@Suite("OpenAI-compatible stream parser")
struct OpenAICompatibleStreamTests {

  // MARK: - Canned-response plumbing

  /// Replays a canned response, looked up by the request's URL. Keying on the URL rather than a
  /// shared "current response" is what makes these tests safe under swift-testing's default
  /// parallel execution — otherwise one test's body leaks into another's stream.
  final class StubProtocol: URLProtocol {
    private struct Canned {
      let status: Int
      let body: String
    }

    nonisolated(unsafe) private static var responses: [String: Canned] = [:]
    private static let lock = NSLock()

    /// Registers a response and returns the unique endpoint that serves it.
    static func register(status: Int, body: String) -> String {
      let endpoint = "https://stub.invalid/\(UUID().uuidString)/v1/chat/completions"
      lock.lock()
      responses[endpoint] = Canned(status: status, body: body)
      lock.unlock()
      return endpoint
    }

    private static func canned(for url: URL?) -> Canned? {
      guard let key = url?.absoluteString else { return nil }
      lock.lock()
      defer { lock.unlock() }
      return responses[key]
    }

    override class func canInit(with request: URLRequest) -> Bool {
      canned(for: request.url) != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      guard let url = request.url, let canned = Self.canned(for: url) else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      let response = HTTPURLResponse(
        url: url, statusCode: canned.status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(canned.body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }

  private static func config(status: Int = 200, body: String) -> OpenAICompatibleStream.Config {
    let endpoint = StubProtocol.register(status: status, body: body)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return OpenAICompatibleStream.Config(
      endpoint: endpoint,
      headers: [:],
      logTag: "TEST",
      mapHTTPError: { status, body in
        TranscriptionError.networkError("mapped \(status): \(body.prefix(40))")
      },
      session: URLSession(configuration: configuration))
  }

  private static func collect(
    _ stream: AsyncThrowingStream<ChatStreamEvent, Error>
  ) async throws -> [ChatStreamEvent] {
    var events: [ChatStreamEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  private static func text(in events: [ChatStreamEvent]) -> String {
    events.reduce(into: "") { acc, event in
      if case .textDelta(let delta) = event { acc += delta }
    }
  }

  private static func calls(
    in events: [ChatStreamEvent]
  ) -> [(name: String, args: [String: Any], id: String?)] {
    events.compactMap { event in
      guard case .functionCall(let name, let args, let signature) = event else { return nil }
      return (name, args, signature)
    }
  }

  // MARK: - Chat Completions

  @Test("Chat Completions: text deltas concatenate and finish reason is reported")
  func chatCompletionsText() async throws {
    let body = """
      data: {"choices":[{"delta":{"content":"Hello"}}]}

      data: {"choices":[{"delta":{"content":", world"}}]}

      data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

      data: [DONE]

      """
    let events = try await Self.collect(
      OpenAICompatibleStream.chatCompletions(Self.config(body: body), body: [:]))

    #expect(Self.text(in: events) == "Hello, world")
    guard case .finished(_, _, let reason) = events.last else {
      Issue.record("expected a finished event, got \(String(describing: events.last))")
      return
    }
    #expect(reason == "stop")
  }

  @Test("Chat Completions: fragmented tool-call arguments are reassembled")
  func chatCompletionsFragmentedToolCall() async throws {
    let body = """
      data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","function":{"name":"get_time","arguments":"{\\"tz\\":"}}]}}]}

      data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"UTC\\"}"}}]}}]}

      data: [DONE]

      """
    let events = try await Self.collect(
      OpenAICompatibleStream.chatCompletions(Self.config(body: body), body: [:]))
    let calls = Self.calls(in: events)

    #expect(calls.count == 1)
    #expect(calls.first?.name == "get_time")
    #expect(calls.first?.args["tz"] as? String == "UTC")
    // The tool_call id round-trips via thoughtSignature so the follow-up turn can pair the result.
    #expect(calls.first?.id == "call_abc")
  }

  @Test("Chat Completions: parallel tool calls emit in numeric index order, not lexicographic")
  func chatCompletionsOrdersByNumericIndex() async throws {
    // Index 10 arriving before index 2 is the case a string-keyed dict got wrong.
    let body = """
      data: {"choices":[{"delta":{"tool_calls":[{"index":10,"id":"c10","function":{"name":"ten","arguments":"{}"}}]}}]}

      data: {"choices":[{"delta":{"tool_calls":[{"index":2,"id":"c2","function":{"name":"two","arguments":"{}"}}]}}]}

      data: [DONE]

      """
    let events = try await Self.collect(
      OpenAICompatibleStream.chatCompletions(Self.config(body: body), body: [:]))

    #expect(Self.calls(in: events).map(\.name) == ["two", "ten"])
  }

  @Test("Chat Completions: a tool call with no id falls back to its positional call_<index>")
  func chatCompletionsPositionalFallback() async throws {
    let body = """
      data: {"choices":[{"delta":{"tool_calls":[{"index":3,"function":{"name":"noid","arguments":"{}"}}]}}]}

      data: [DONE]

      """
    let events = try await Self.collect(
      OpenAICompatibleStream.chatCompletions(Self.config(body: body), body: [:]))

    #expect(Self.calls(in: events).first?.id == "call_3")
  }

  @Test("Chat Completions: malformed tool-call arguments yield empty args, not a thrown stream")
  func chatCompletionsMalformedArguments() async throws {
    let body = """
      data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c0","function":{"name":"broken","arguments":"{not json"}}]}}]}

      data: [DONE]

      """
    let events = try await Self.collect(
      OpenAICompatibleStream.chatCompletions(Self.config(body: body), body: [:]))

    #expect(Self.calls(in: events).first?.name == "broken")
    #expect(Self.calls(in: events).first?.args.isEmpty == true)
  }

  // MARK: - Responses API

  @Test("Responses: text deltas concatenate and completion maps to finish reason 'stop'")
  func responsesText() async throws {
    let body = """
      event: response.output_text.delta
      data: {"delta":"Hi"}

      event: response.output_text.delta
      data: {"delta":" there"}

      event: response.completed
      data: {"response":{"status":"completed"}}

      """
    let events = try await Self.collect(
      OpenAICompatibleStream.responses(Self.config(body: body), body: [:], collectCitations: false))

    #expect(Self.text(in: events) == "Hi there")
    guard case .finished(_, _, let reason) = events.last else {
      Issue.record("expected a finished event, got \(String(describing: events.last))")
      return
    }
    #expect(reason == "stop")
  }

  @Test("Responses: a function call pairs its name from output_item.added with later arguments")
  func responsesFunctionCall() async throws {
    let body = """
      event: response.output_item.added
      data: {"item":{"type":"function_call","id":"fc_1","name":"lookup"}}

      event: response.function_call_arguments.done
      data: {"item_id":"fc_1","arguments":"{\\"q\\":\\"swift\\"}"}

      event: response.completed
      data: {"response":{"status":"completed"}}

      """
    let events = try await Self.collect(
      OpenAICompatibleStream.responses(Self.config(body: body), body: [:], collectCitations: false))
    let calls = Self.calls(in: events)

    #expect(calls.count == 1)
    #expect(calls.first?.name == "lookup")
    #expect(calls.first?.args["q"] as? String == "swift")
    #expect(calls.first?.id == "fc_1")
  }

  @Test("Responses: citations are deduplicated, kept in first-seen order, and titled by host")
  func responsesCitations() async throws {
    let body = """
      event: response.output_text.annotation.added
      data: {"annotation":{"type":"url_citation","url":"https://www.example.com/a"}}

      event: response.output_text.annotation.added
      data: {"annotation":{"type":"url_citation","url":"https://other.org/b"}}

      event: response.output_text.annotation.added
      data: {"annotation":{"type":"url_citation","url":"https://www.example.com/a"}}

      event: response.completed
      data: {"response":{"status":"completed"}}

      """
    let events = try await Self.collect(
      OpenAICompatibleStream.responses(Self.config(body: body), body: [:], collectCitations: true))

    guard case .finished(let sources, _, _) = events.last else {
      Issue.record("expected a finished event, got \(String(describing: events.last))")
      return
    }
    #expect(sources.map(\.uri) == ["https://www.example.com/a", "https://other.org/b"])
    // "www." is dropped so the footer reads the same way Gemini-grounded sources do.
    #expect(sources.map(\.title) == ["example.com", "other.org"])
  }

  @Test("Responses: citations stay empty when the provider writes its own inline markers")
  func responsesCitationsSuppressed() async throws {
    let body = """
      event: response.output_text.annotation.added
      data: {"annotation":{"type":"url_citation","url":"https://example.com/a"}}

      event: response.completed
      data: {"response":{"status":"completed"}}

      """
    let events = try await Self.collect(
      OpenAICompatibleStream.responses(Self.config(body: body), body: [:], collectCitations: false))

    guard case .finished(let sources, _, _) = events.last else {
      Issue.record("expected a finished event, got \(String(describing: events.last))")
      return
    }
    #expect(sources.isEmpty)
  }

  @Test("length / max_tokens finish reasons count as truncated")
  func truncatedFinishReasons() {
    #expect(ChatViewModel.isTruncatedFinishReason("length"))
    #expect(ChatViewModel.isTruncatedFinishReason("MAX_TOKENS"))
    #expect(ChatViewModel.isTruncatedFinishReason("max_tokens"))
    #expect(!ChatViewModel.isTruncatedFinishReason("stop"))
    #expect(!ChatViewModel.isTruncatedFinishReason(nil))
  }

  // MARK: - Error mapping

  @Test("A non-2xx status is routed through the provider's own mapHTTPError")
  func httpErrorUsesProviderMapping() async throws {
    let config = Self.config(status: 429, body: "rate limit reached")
    await #expect(throws: TranscriptionError.self) {
      _ = try await Self.collect(OpenAICompatibleStream.chatCompletions(config, body: [:]))
    }
  }

  @Test("5xx maps to serverError; JSON error bodies are not leaked")
  func httpErrorHidesJSON() {
    let err = ChatProviderHTTPError.map(
      provider: "OpenAI", status: 503, body: #"{"error":{"message":"overloaded"}}"#)
    #expect(err as? TranscriptionError == .serverError(503))
    let four = ChatProviderHTTPError.map(
      provider: "OpenAI", status: 400, body: #"{"error":{"message":"context_length_exceeded"}}"#)
    #expect(four as? TranscriptionError == .networkError("OpenAI API error: context_length_exceeded"))
  }

  @Test("PDF attachments are rejected for OpenAI-compatible providers")
  func attachmentGuardRejectsPDF() {
    let contents: [[String: Any]] = [[
      "role": "user",
      "parts": [["inline_data": ["mime_type": "application/pdf", "data": "AAAA"]]],
    ]]
    let err = ChatAttachmentGuard.rejectUnsupported(
      in: contents, provider: "OpenAI", allowedPrefixes: ["image/", "audio/"])
    #expect(err != nil)
    #expect((err as? TranscriptionError) != nil)
    #expect(ChatAttachmentGuard.rejectUnsupported(
      in: [["role": "user", "parts": [["inline_data": ["mime_type": "image/png", "data": "AAAA"]]]]],
      provider: "OpenAI", allowedPrefixes: ["image/", "audio/"]) == nil)
  }
}

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Lenient OpenAI/Grok streams must surface a failed or cut-off reply instead of finishing empty.
/// No network: the shared `URLProtocol` stub replays canned SSE.
@Suite("OpenAI-compatible stream terminals")
struct OpenAICompatibleStreamTerminalTests {

  private static func config(body: String) -> OpenAICompatibleStream.Config {
    let endpoint = OpenAICompatibleStreamTests.StubProtocol.register(status: 200, body: body)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAICompatibleStreamTests.StubProtocol.self]
    return OpenAICompatibleStream.Config(
      endpoint: endpoint,
      headers: [:],
      logTag: "TEST",
      mapHTTPError: { _, _ in TranscriptionError.networkError("http") },
      session: URLSession(configuration: configuration))
  }

  private static func collect(
    _ stream: AsyncThrowingStream<ChatStreamEvent, Error>
  ) async throws -> [ChatStreamEvent] {
    var events: [ChatStreamEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  private static func networkMessage(_ error: Error) -> String {
    guard let transcription = error as? TranscriptionError,
          case .networkError(let message) = transcription else {
      return ""
    }
    return message
  }

  @Test("Lenient response.incomplete carries a truncated finish reason")
  func incompleteIsTruncated() async throws {
    let body = """
      event: response.output_text.delta
      data: {"delta":"Hello"}

      event: response.incomplete
      data: {"response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}

      """
    let events = try await Self.collect(
      OpenAICompatibleStream.responses(Self.config(body: body), body: [:], collectCitations: false))

    guard case .finished(_, _, let reason) = events.last else {
      Issue.record("expected a finished event, got \(String(describing: events.last))")
      return
    }
    #expect(reason == "length")
    #expect(ChatViewModel.isTruncatedFinishReason(reason))
  }

  @Test("Lenient response.incomplete with another reason is plain incomplete")
  func incompleteOtherReason() async throws {
    let body = """
      event: response.incomplete
      data: {"response":{"status":"incomplete","incomplete_details":{"reason":"content_filter"}}}

      """
    let events = try await Self.collect(
      OpenAICompatibleStream.responses(Self.config(body: body), body: [:], collectCitations: false))

    guard case .finished(_, _, let reason) = events.last else {
      Issue.record("expected a finished event, got \(String(describing: events.last))")
      return
    }
    #expect(reason == "incomplete")
  }

  @Test("Lenient response.failed throws the payload message")
  func failedThrowsMessage() async {
    let body = """
      event: response.failed
      data: {"response":{"error":{"message":"boom"}}}

      """
    do {
      _ = try await Self.collect(
        OpenAICompatibleStream.responses(Self.config(body: body), body: [:], collectCitations: false))
      Issue.record("expected the stream to throw")
    } catch {
      #expect(Self.networkMessage(error).contains("boom"))
    }
  }

  @Test("Chat Completions error line throws the payload message")
  func chatCompletionsErrorThrows() async {
    let body = """
      data: {"choices":[{"delta":{"content":"Hi"}}]}

      data: {"error":{"message":"quota"}}

      """
    do {
      _ = try await Self.collect(
        OpenAICompatibleStream.chatCompletions(Self.config(body: body), body: [:]))
      Issue.record("expected the stream to throw")
    } catch {
      #expect(Self.networkMessage(error).contains("quota"))
    }
  }

  @Test("Chat Completions still yields text and finishes")
  func chatCompletionsStillFinishes() async throws {
    let body = """
      data: {"choices":[{"delta":{"content":"Hello"}}]}

      data: {"choices":[{"delta":{"content":", world"}}]}

      data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

      data: [DONE]

      """
    let events = try await Self.collect(
      OpenAICompatibleStream.chatCompletions(Self.config(body: body), body: [:]))

    let text = events.reduce(into: "") { acc, event in
      if case .textDelta(let delta) = event { acc += delta }
    }
    #expect(text == "Hello, world")
    guard case .finished(_, _, let reason) = events.last else {
      Issue.record("expected a finished event, got \(String(describing: events.last))")
      return
    }
    #expect(reason == "stop")
  }
}

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

  private struct IncompleteRow: Sendable {
    let body: String
    let reason: String
    let truncated: Bool
    let label: String
  }

  @Test(
    "Lenient response.incomplete finishes with a mapped reason",
    arguments: [
      IncompleteRow(
        body: """
          event: response.output_text.delta
          data: {"delta":"Hello"}

          event: response.incomplete
          data: {"response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}

          """,
        reason: "length", truncated: true, label: "max_output_tokens is a truncated finish"),
      IncompleteRow(
        body: """
          event: response.incomplete
          data: {"response":{"status":"incomplete","incomplete_details":{"reason":"content_filter"}}}

          """,
        reason: "incomplete", truncated: true, label: "another reason is plain incomplete"),
    ])
  private func incomplete(_ row: IncompleteRow) async throws {
    let events = try await Self.collect(
      OpenAICompatibleStream.responses(Self.config(body: row.body), body: [:], collectCitations: false))

    guard case .finished(_, _, let reason) = events.last else {
      Issue.record("expected a finished event, got \(String(describing: events.last)): \(row.label)")
      return
    }
    #expect(reason == row.reason, Comment(rawValue: row.label))
    #expect(ChatViewModel.isTruncatedFinishReason(reason) == row.truncated, Comment(rawValue: row.label))
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
}

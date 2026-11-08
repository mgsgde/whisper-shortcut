import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Live Meeting with an on-device summary model: structured output without a server, and no
/// transcript-echoing consolidation pass.
@Suite("Meeting offline MLX")
struct MeetingOfflineMLXTests {

  private struct SchemaRow: @unchecked Sendable {
    let schema: [String: Any]
    let expected: String?
    let label: String
  }

  @Test(
    "only a single string property is the plain-text schema",
    arguments: [
      SchemaRow(
        schema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]],
        expected: "text", label: "one string property"),
      SchemaRow(
        schema: ["type": "object", "properties": ["a": ["type": "string"], "b": ["type": "string"]]],
        expected: nil, label: "two properties"),
      SchemaRow(
        schema: ["type": "object", "properties": ["n": ["type": "integer"]]],
        expected: nil, label: "non-string property"),
      SchemaRow(schema: [:], expected: nil, label: "empty schema"),
    ])
  private func schemaCase(_ row: SchemaRow) {
    #expect(MLXChatProvider.singleStringProperty(in: row.schema) == row.expected, Comment(rawValue: row.label))
  }

  private struct JSONRow: Sendable {
    let reply: String
    let check: @Sendable ([String: Any]) -> Bool
    let label: String
  }

  @Test(
    "extractJSONObject finds the object in plain, fenced and prose-wrapped replies",
    arguments: [
      JSONRow(reply: #"{"title":"Plan"}"#, check: { $0["title"] as? String == "Plan" }, label: "plain JSON object"),
      JSONRow(
        reply: "```json\n{\"title\": \"Plan\", \"n\": 2}\n```",
        check: { $0["title"] as? String == "Plan" && $0["n"] as? Int == 2 }, label: "```json fence"),
      JSONRow(
        reply: "Sure, here you go: {\"a\": {\"b\": \"x\"}} Hope that helps.",
        check: { ($0["a"] as? [String: Any])?["b"] as? String == "x" },
        label: "outermost object from surrounding prose"),
    ])
  private func extractsJSON(_ row: JSONRow) throws {
    let obj = try MLXChatProvider.extractJSONObject(from: row.reply)
    #expect(row.check(obj), Comment(rawValue: row.label))
  }

  @Test("invalid input throws a non-retryable error")
  func invalidThrows() {
    for bad in ["", "no json here", "{not json}", "} {", "[1, 2]"] {
      #expect(throws: TranscriptionError.self) {
        try MLXChatProvider.extractJSONObject(from: bad)
      }
    }
    do {
      _ = try MLXChatProvider.extractJSONObject(from: "nope")
      Issue.record("expected a throw")
    } catch let error as TranscriptionError {
      #expect(error.isRetryable == false)
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  @Test("speaker consolidation is skipped for on-device providers only")
  func consolidationSkip() {
    #expect(MeetingListService.skipsSpeakerConsolidation(provider: .localMLX))
    #expect(MeetingListService.skipsSpeakerConsolidation(provider: .local))
    #expect(!MeetingListService.skipsSpeakerConsolidation(provider: .gemini))
    #expect(!MeetingListService.skipsSpeakerConsolidation(provider: .openai))
    #expect(!MeetingListService.skipsSpeakerConsolidation(provider: .grok))
    // An own server can be remote, so it stays on the cloud side of this check.
    #expect(!MeetingListService.skipsSpeakerConsolidation(provider: .customOpenAI))
    #expect(!ChatModelProvider.customOpenAI.isLocal)
    #expect(ChatModelProvider.local.isLocal)
    #expect(ChatModelProvider.localMLX.isLocal)
  }
}

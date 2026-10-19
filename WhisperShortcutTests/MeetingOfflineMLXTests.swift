import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Live Meeting with an on-device summary model: structured output without a server, and no
/// transcript-echoing consolidation pass.
@Suite("Meeting offline MLX")
struct MeetingOfflineMLXTests {

  @Test("one string property is the plain-text case")
  func singleStringProperty() {
    let textSchema: [String: Any] = [
      "type": "object",
      "properties": ["text": ["type": "string"]],
      "required": ["text"],
    ]
    #expect(MLXChatProvider.singleStringProperty(in: textSchema) == "text")
  }

  @Test("other schemas are not the plain-text case")
  func otherSchemas() {
    let two: [String: Any] = [
      "type": "object",
      "properties": ["a": ["type": "string"], "b": ["type": "string"]],
    ]
    let nonString: [String: Any] = [
      "type": "object", "properties": ["n": ["type": "integer"]],
    ]
    #expect(MLXChatProvider.singleStringProperty(in: two) == nil)
    #expect(MLXChatProvider.singleStringProperty(in: nonString) == nil)
    #expect(MLXChatProvider.singleStringProperty(in: [:]) == nil)
  }

  @Test("extracts a plain JSON object")
  func plainJSON() throws {
    let obj = try MLXChatProvider.extractJSONObject(from: #"{"title":"Plan"}"#)
    #expect(obj["title"] as? String == "Plan")
  }

  @Test("extracts from a ```json fence")
  func fencedJSON() throws {
    let reply = "```json\n{\"title\": \"Plan\", \"n\": 2}\n```"
    let obj = try MLXChatProvider.extractJSONObject(from: reply)
    #expect(obj["title"] as? String == "Plan")
    #expect(obj["n"] as? Int == 2)
  }

  @Test("extracts the outermost object from surrounding prose")
  func proseAroundJSON() throws {
    let reply = "Sure, here you go: {\"a\": {\"b\": \"x\"}} Hope that helps."
    let obj = try MLXChatProvider.extractJSONObject(from: reply)
    #expect((obj["a"] as? [String: Any])?["b"] as? String == "x")
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
  }
}

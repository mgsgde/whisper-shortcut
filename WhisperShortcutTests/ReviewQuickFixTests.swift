import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Small fixes from the 2026-09-29 app review, each pinned where a regression would be silent.
@Suite("Review quick fixes")
struct ReviewQuickFixTests {

  @Test("update_event keeps an all-day event all-day when all_day is omitted")
  func updateEventAllDayInference() {
    #expect(ChatToolRegistry.updateEventAllDay(["start_iso8601": "2026-10-01"]))
    #expect(!ChatToolRegistry.updateEventAllDay(["start_iso8601": "2026-10-01T15:00:00+02:00"]))
    #expect(!ChatToolRegistry.updateEventAllDay(["summary": "Renamed"]))
    #expect(!ChatToolRegistry.updateEventAllDay(["all_day": false, "start_iso8601": "2026-10-01"]))
    #expect(ChatToolRegistry.updateEventAllDay(["all_day": "true"]))
  }

  @Test("create_event accepts all_day as a string, same as update_event")
  func createEventAllDayString() {
    #expect(ChatToolRegistry.createEventAllDay(["all_day": "true"]))
    #expect(ChatToolRegistry.createEventAllDay(["all_day": true]))
    #expect(ChatToolRegistry.createEventAllDay(["all_day": NSNumber(value: true)]))
    #expect(!ChatToolRegistry.createEventAllDay(["all_day": "false"]))
    #expect(!ChatToolRegistry.createEventAllDay([:]))
    #expect(ChatToolRegistry.createEventAllDay(["all_day": "true"])
      == ChatToolRegistry.updateEventAllDay(["all_day": "true"]))
  }

  @Test("A tool result over the cap is truncated with a note; normal results pass untouched")
  func toolResultCap() {
    let small: [String: Any] = ["content": "hello"]
    #expect((ChatToolHistory.cappedForModel(small).response["content"] as? String) == "hello")

    let huge: [String: Any] = ["content": String(repeating: "x", count: ChatToolHistory.maxResultCharsForModel + 5_000)]
    let capped = ChatToolHistory.cappedForModel(huge)
    #expect(capped.chars == ChatToolHistory.maxResultCharsForModel)
    #expect((capped.response["truncated_result"] as? String)?.count == ChatToolHistory.maxResultCharsForModel)
    #expect((capped.response["note"] as? String)?.contains("truncated") == true)
  }
}

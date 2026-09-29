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

  @Test("An error popup does not repeat a differently worded heading in its body")
  func popupBodyDropsSecondHeading() {
    let (title, body) = SpeechErrorFormatter.titleAndBodyForPopup(.noGoogleAPIKey)
    #expect(title.hasPrefix("⚠️"))
    #expect(!body.hasPrefix("⚠️"), "body still opens with a heading: \(body.prefix(40))")
    #expect(!body.isEmpty)
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

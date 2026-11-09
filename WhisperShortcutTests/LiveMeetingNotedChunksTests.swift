import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The live-note cursor used to be "the last noted chunk". A chunk that finished transcribing late
/// lands before that cursor by start time and was never noted.
@Suite("Live meeting noted chunks")
struct LiveMeetingNotedChunksTests {

  @Test("Everything is pending when nothing was noted")
  func allPending() {
    let chunks = [
      LiveMeetingChunk(startTime: 0, text: "a"), LiveMeetingChunk(startTime: 30, text: "b"),
    ]
    #expect(LiveMeetingSession.unnotedChunks(chunks, noted: []).map(\.text) == ["a", "b"])
  }

  @Test("A chunk inserted before an already noted one is still pending")
  func lateChunkBeforeCursorIsNoted() {
    let first = LiveMeetingChunk(startTime: 0, text: "first")
    let last = LiveMeetingChunk(startTime: 60, text: "last")
    let late = LiveMeetingChunk(startTime: 30, text: "late")
    let store = [first, late, last]
    let pending = LiveMeetingSession.unnotedChunks(store, noted: [first.id, last.id])
    #expect(pending.map(\.text) == ["late"])
  }

  @Test("Pending chunks come back in start-time order")
  func orderedByStart() {
    let chunks = [
      LiveMeetingChunk(startTime: 90, text: "c"), LiveMeetingChunk(startTime: 10, text: "a"),
      LiveMeetingChunk(startTime: 50, text: "b"),
    ]
    #expect(LiveMeetingSession.unnotedChunks(chunks, noted: []).map(\.text) == ["a", "b", "c"])
  }

  @Test("Nothing is pending once every chunk is noted")
  func nothingPending() {
    let chunks = [LiveMeetingChunk(startTime: 0, text: "a")]
    #expect(LiveMeetingSession.unnotedChunks(chunks, noted: Set(chunks.map(\.id))).isEmpty)
  }
}

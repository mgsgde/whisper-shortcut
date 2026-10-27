import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The end-of-meeting pass may only replace the transcript file with the LLM's speaker-consolidated
/// text when every block survived, and the parser must not split a chunk on a timestamp-looking
/// string inside its text.
@Suite("Meeting transcript integrity")
struct MeetingTranscriptIntegrityTests {

  private let original = "[00:00] Anna: Hello\n\n[01:05] Ben: Hi there\n\n[02:10] Anna: Bye"

  @Test("Identical timestamps are accepted")
  func accepts() {
    let consolidated = "[00:00] Speaker 1: Hello\n\n[01:05] Speaker 2: Hi there\n\n[02:10] Speaker 1: Bye"
    #expect(LiveMeetingSession.acceptsConsolidation(original: original, consolidated: consolidated))
  }

  @Test("A dropped block is rejected")
  func droppedBlock() {
    let consolidated = "[00:00] Speaker 1: Hello\n\n[02:10] Speaker 1: Bye"
    #expect(!LiveMeetingSession.acceptsConsolidation(original: original, consolidated: consolidated))
  }

  @Test("Empty output is rejected")
  func empty() {
    #expect(!LiveMeetingSession.acceptsConsolidation(original: original, consolidated: ""))
    #expect(!LiveMeetingSession.acceptsConsolidation(original: original, consolidated: "  \n "))
  }

  @Test("Reordered blocks are rejected")
  func reordered() {
    let consolidated = "[01:05] Ben: Hi there\n\n[00:00] Anna: Hello\n\n[02:10] Anna: Bye"
    #expect(!LiveMeetingSession.acceptsConsolidation(original: original, consolidated: consolidated))
  }

  @Test("A timestamp inside a chunk body does not split the chunk")
  func midLineTimestamp() {
    let text = "[00:00] He said see [1:23] in the recording\n\n[01:05] Next"
    let chunks = MeetingTranscriptFormat.parse(text)
    #expect(chunks.count == 2)
    #expect(chunks.first?.text == "He said see [1:23] in the recording")
    #expect(chunks.last?.startTime == 65)
  }

  @Test("Parser round-trips timestampString blocks")
  func roundTrip() {
    let chunks = [
      LiveMeetingChunk(startTime: 0, text: "one"),
      LiveMeetingChunk(startTime: 3725, text: "two\nlines"),
    ]
    let text = chunks.map { "\($0.timestampString) \($0.text)" }.joined(separator: "\n\n")
    let parsed = MeetingTranscriptFormat.parse(text)
    #expect(parsed.map(\.text) == ["one", "two\nlines"])
    #expect(parsed.map(\.startTime) == [0, 3725])
  }
}

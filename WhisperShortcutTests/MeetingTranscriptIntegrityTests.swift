import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The end-of-meeting pass may only replace the transcript file with the LLM's speaker-consolidated
/// text when every block survived, and the parser must not split a chunk on a timestamp-looking
/// string inside its text.
@Suite("Meeting transcript integrity")
struct MeetingTranscriptIntegrityTests {

  private let original = "[00:00] Anna: Hello\n\n[01:05] Ben: Hi there\n\n[02:10] Anna: Bye"

  private struct Row: Sendable {
    let consolidated: String
    let accepted: Bool
    let label: String
  }

  @Test(
    "Consolidation is accepted only when every block survives in order",
    arguments: [
      Row(
        consolidated: "[00:00] Speaker 1: Hello\n\n[01:05] Speaker 2: Hi there\n\n[02:10] Speaker 1: Bye",
        accepted: true, label: "identical timestamps"),
      Row(
        consolidated: "[00:00] Speaker 1: Hello\n\n[02:10] Speaker 1: Bye",
        accepted: false, label: "dropped block"),
      Row(consolidated: "", accepted: false, label: "empty output"),
      Row(consolidated: "  \n ", accepted: false, label: "whitespace-only output"),
      Row(
        consolidated: "[01:05] Ben: Hi there\n\n[00:00] Anna: Hello\n\n[02:10] Anna: Bye",
        accepted: false, label: "reordered blocks"),
    ])
  private func consolidation(_ row: Row) {
    #expect(
      LiveMeetingSession.acceptsConsolidation(original: original, consolidated: row.consolidated) == row.accepted,
      Comment(rawValue: row.label))
  }

  @Test("A timestamp inside a chunk body does not split the chunk")
  func midLineTimestamp() {
    let text = "[00:00] He said see [1:23] in the recording\n\n[01:05] Next"
    let chunks = LiveMeetingTranscriptStore.parseTranscript(text)
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
    let parsed = LiveMeetingTranscriptStore.parseTranscript(text)
    #expect(parsed.map(\.text) == ["one", "two\nlines"])
    #expect(parsed.map(\.startTime) == [0, 3725])
  }
}

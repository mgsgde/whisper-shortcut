import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The backlog keeps a chunk's timestamp only in its filename, and splices recovered text back by
/// that timestamp. A wrong round-trip or ordering would put a late-transcribed part of a meeting at
/// the wrong place in the transcript without any error.
@Suite("Meeting audio backlog")
struct MeetingAudioBacklogTests {

  @Test("Start time survives the filename round-trip")
  func filenameRoundTrip() {
    for start in [0, 12.5, 754, 3599.999, 7200] as [TimeInterval] {
      let name = MeetingAudioBacklog.filename(startTime: start)
      let parsed = MeetingAudioBacklog.startTime(fromFilename: name)
      #expect(parsed != nil)
      #expect(abs((parsed ?? -1) - start) < 0.001)
    }
  }

  @Test("Filenames sort in time order and foreign files are ignored")
  func filenamesSortAndReject() {
    let names = [754, 60, 3600].map { MeetingAudioBacklog.filename(startTime: TimeInterval($0)) }
    #expect(names.sorted() == [60, 754, 3600].map { MeetingAudioBacklog.filename(startTime: TimeInterval($0)) })
    #expect(MeetingAudioBacklog.startTime(fromFilename: ".DS_Store") == nil)
    #expect(MeetingAudioBacklog.startTime(fromFilename: "chunk-.wav") == nil)
    #expect(MeetingAudioBacklog.startTime(fromFilename: "live_meeting_1.wav") == nil)
  }

  @Test("Recovered chunks are spliced in at their timestamps")
  func mergeOrdersByTime() {
    let existing = [
      LiveMeetingChunk(startTime: 0, text: "hello"),
      LiveMeetingChunk(startTime: 180, text: "end"),
    ]
    let recovered = [
      LiveMeetingChunk(startTime: 120, text: "b"),
      LiveMeetingChunk(startTime: 60, text: "a"),
      LiveMeetingChunk(startTime: 180, text: "same second"),
    ]
    let merged = MeetingAudioBacklog.merge(recovered, into: existing)
    #expect(merged.map(\.text) == ["hello", "a", "b", "same second", "end"])
  }

  @Test("Merged transcript renders in the format the parser reads back")
  func transcriptTextRoundTrip() {
    let chunks = [
      LiveMeetingChunk(startTime: 5, text: "Speaker A: first"),
      LiveMeetingChunk(startTime: 754, text: "Speaker B: second\nline two"),
    ]
    let parsed = LiveMeetingTranscriptStore.parseTranscript(MeetingAudioBacklog.transcriptText(chunks))
    #expect(parsed.map(\.text) == chunks.map(\.text))
    #expect(parsed.map(\.startTime) == [5, 754])
  }
}

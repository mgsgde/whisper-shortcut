import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// New audio of a resumed meeting must be stamped after all old audio, transcribed or still kept.
@Suite("Live meeting resume offset")
struct LiveMeetingResumeOffsetTests {

  @Test("A meeting with nothing recorded starts at zero")
  func empty() {
    #expect(LiveMeetingSession.resumeOffset(chunkStarts: [], backlogStarts: [], chunkInterval: 60) == 0)
  }

  @Test("The offset follows the last transcribed chunk")
  func chunksOnly() {
    #expect(
      LiveMeetingSession.resumeOffset(chunkStarts: [0, 60, 120], backlogStarts: [], chunkInterval: 60)
        == 180)
  }

  @Test("An empty transcript with kept audio still moves the offset")
  func backlogOnly() {
    #expect(
      LiveMeetingSession.resumeOffset(chunkStarts: [], backlogStarts: [0, 90], chunkInterval: 60)
        == 150)
  }

  @Test("Kept audio later than the transcript wins")
  func backlogAfterChunks() {
    #expect(
      LiveMeetingSession.resumeOffset(chunkStarts: [0, 60], backlogStarts: [300], chunkInterval: 30)
        == 330)
  }

  @Test("A tiny interval still leaves a one second buffer")
  func minimumBuffer() {
    #expect(LiveMeetingSession.resumeOffset(chunkStarts: [10], backlogStarts: [], chunkInterval: 0) == 11)
  }
}

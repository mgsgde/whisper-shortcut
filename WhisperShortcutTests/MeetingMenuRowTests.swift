import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The status-menu meeting row is the only way into a meeting without opening the chat window, so
/// its title has to say what a click will do. The three states are decided by a pure function so
/// they can be checked without an `NSMenu`.
@Suite("Status menu — meeting row")
struct MeetingMenuRowTests {
  @Test("A running meeting offers Stop")
  func active() {
    #expect(
      MenuBarController.meetingRowTitle(isActive: true, canResume: false)
        == "Stop Meeting Transcription")
    // A running meeting wins over resumable chunks: stopping is what a click does.
    #expect(
      MenuBarController.meetingRowTitle(isActive: true, canResume: true)
        == "Stop Meeting Transcription")
  }

  @Test("A stopped meeting with transcript chunks offers Resume")
  func resumable() {
    #expect(
      MenuBarController.meetingRowTitle(isActive: false, canResume: true)
        == "Resume Meeting Transcription")
  }

  @Test("Nothing running and nothing to resume offers Start")
  func fresh() {
    #expect(
      MenuBarController.meetingRowTitle(isActive: false, canResume: false)
        == "Start Meeting Transcription")
  }
}

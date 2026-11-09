import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The status-menu meeting row is the only way into a meeting without opening the chat window, so
/// its title has to say what a click will do. The three states are decided by a pure function so
/// they can be checked without an `NSMenu`.
@Suite("Status menu — meeting row")
struct MeetingMenuRowTests {
  private struct Row: Sendable {
    let isActive: Bool
    let canResume: Bool
    let title: LocalizedStringResource
    let label: String
  }

  @Test(
    "The row title says what a click will do",
    arguments: [
      Row(isActive: true, canResume: false, title: "Stop Meeting Transcription", label: "running offers Stop"),
      // A running meeting wins over resumable chunks: stopping is what a click does.
      Row(isActive: true, canResume: true, title: "Stop Meeting Transcription", label: "running beats resumable"),
      Row(isActive: false, canResume: true, title: "Resume Meeting Transcription", label: "stopped with chunks offers Resume"),
      Row(isActive: false, canResume: false, title: "Start Meeting Transcription", label: "nothing to resume offers Start"),
    ])
  private func rowTitle(_ row: Row) {
    #expect(
      MenuBarController.meetingRowTitle(isActive: row.isActive, canResume: row.canResume) == row.title,
      Comment(rawValue: row.label))
  }
}

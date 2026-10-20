import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The marker decides, at launch, whether an interrupted meeting is resumed, reported or ignored.
/// A wrong answer either restarts a recording the user ended on purpose or silently drops the one
/// they did not — the 2026-10-20 incident.
@Suite("Live meeting recording marker")
struct LiveMeetingRecordingMarkerTests {

  private let now = Date(timeIntervalSince1970: 1_000_000)
  private func payload(userQuit: Bool = false) -> LiveMeetingRecordingMarker.Payload {
    .init(stem: "Meeting-1", pid: 42, userQuit: userQuit)
  }

  @Test("No marker means nothing to do")
  func noPayload() {
    let action = LiveMeetingRecordingMarker.launchAction(
      payload: nil, lastAlive: now, now: now, transcriptExists: true)
    #expect(action == .none)
  }

  @Test("A deliberate quit is never resumed")
  func userQuit() {
    let action = LiveMeetingRecordingMarker.launchAction(
      payload: payload(userQuit: true), lastAlive: now.addingTimeInterval(-5), now: now,
      transcriptExists: true)
    #expect(action == .none)
  }

  @Test("Without a transcript there is nothing to resume")
  func noTranscript() {
    let action = LiveMeetingRecordingMarker.launchAction(
      payload: payload(), lastAlive: now.addingTimeInterval(-5), now: now, transcriptExists: false)
    #expect(action == .none)
  }

  @Test("A recent interruption is resumed")
  func recent() {
    let action = LiveMeetingRecordingMarker.launchAction(
      payload: payload(), lastAlive: now.addingTimeInterval(-30), now: now, transcriptExists: true)
    #expect(action == .resume(stem: "Meeting-1"))
  }

  @Test("An old interruption is only reported")
  func old() {
    let action = LiveMeetingRecordingMarker.launchAction(
      payload: payload(), lastAlive: now.addingTimeInterval(-11 * 60), now: now,
      transcriptExists: true)
    #expect(action == .notifyInterrupted(stem: "Meeting-1"))
  }

  @Test("Exactly at the window boundary still resumes")
  func boundary() {
    let action = LiveMeetingRecordingMarker.launchAction(
      payload: payload(), lastAlive: now.addingTimeInterval(-LiveMeetingRecordingMarker.resumeWindow),
      now: now, transcriptExists: true)
    #expect(action == .resume(stem: "Meeting-1"))
  }
}

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The marker decides, at launch, whether an interrupted meeting is resumed, reported or ignored.
/// A wrong answer either restarts a recording the user ended on purpose or silently drops the one
/// they did not — the 2026-10-20 incident.
@Suite("Live meeting recording marker")
struct LiveMeetingRecordingMarkerTests {

  private struct MarkerCase: @unchecked Sendable {
    let note: String
    let payload: LiveMeetingRecordingMarker.Payload?
    let age: TimeInterval
    let transcriptExists: Bool
    let expected: LiveMeetingRecordingMarker.LaunchAction
  }

  private static let now = Date(timeIntervalSince1970: 1_000_000)

  private static func payload(userQuit: Bool = false) -> LiveMeetingRecordingMarker.Payload {
    .init(stem: "Meeting-1", pid: 42, userQuit: userQuit)
  }

  private static let markerCases: [MarkerCase] = [
    .init(note: "no marker", payload: nil, age: 0, transcriptExists: true, expected: .none),
    .init(note: "deliberate quit", payload: payload(userQuit: true), age: 5, transcriptExists: true, expected: .none),
    .init(note: "no transcript", payload: payload(), age: 5, transcriptExists: false, expected: .none),
    .init(note: "recent interruption", payload: payload(), age: 30, transcriptExists: true,
          expected: .resume(stem: "Meeting-1")),
    .init(note: "old interruption", payload: payload(), age: 11 * 60, transcriptExists: true,
          expected: .notifyInterrupted(stem: "Meeting-1")),
    .init(note: "window boundary", payload: payload(),
          age: LiveMeetingRecordingMarker.resumeWindow, transcriptExists: true,
          expected: .resume(stem: "Meeting-1")),
  ]

  @Test("Launch action for a leftover recording marker", arguments: markerCases)
  private func launchAction(_ row: MarkerCase) {
    let action = LiveMeetingRecordingMarker.launchAction(
      payload: row.payload, lastAlive: Self.now.addingTimeInterval(-row.age), now: Self.now,
      transcriptExists: row.transcriptExists)
    #expect(action == row.expected, "\(row.note)")
  }

  @Test("Owner liveness: other live pid counts, own pid and dead pid do not")
  func ownerIsAlive() {
    #expect(LiveMeetingRecordingMarker.ownerIsAlive(pid: 42, currentPid: 1, isAlive: { _ in true }))
    #expect(!LiveMeetingRecordingMarker.ownerIsAlive(pid: 42, currentPid: 1, isAlive: { _ in false }))
    #expect(!LiveMeetingRecordingMarker.ownerIsAlive(pid: 42, currentPid: 42, isAlive: { _ in true }))
  }
}

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// `MeetingPhase` on the transcript store and `LiveMeetingSession.isDraining` are the one
/// lifecycle the menu bar and the meeting chat read. These tests walk that lifecycle without a
/// microphone.
@MainActor
@Suite("Meeting phase")
struct MeetingPhaseTests {

  @Test("Store phase walks idle, recording, finishing, then idle")
  func storePhaseLifecycle() {
    let store = LiveMeetingTranscriptStore.shared
    store.clearForNewMeeting()
    defer { store.clearForNewMeeting() }

    #expect(store.phase == .idle)
    #expect(!store.isSessionActive)
    #expect(!store.isFinishing)

    store.startSession()
    #expect(store.phase == .recording)
    #expect(store.isSessionActive)
    #expect(!store.isFinishing)

    store.beginFinishing()
    #expect(store.phase == .finishing)
    #expect(store.isSessionActive)
    #expect(store.isFinishing)

    store.endSession()
    #expect(store.phase == .idle)
    #expect(!store.isSessionActive)
    #expect(!store.isFinishing)
  }

  @Test("isDraining is false until the run is marked draining")
  func sessionIsDrainingFollowsPhase() throws {
    let session = LiveMeetingSession(
      transcribeChunk: { _ in "" },
      cleanUpAudioFile: { _ in },
      appStateIsRecordingMeeting: { false },
      onStopping: {},
      onFinished: {},
      onBacklogChanged: {})
    #expect(!session.isDraining)

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("MeetingPhase-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("meeting.txt")
    FileManager.default.createFile(atPath: url.path, contents: nil)

    let run = session.beginRunForTesting(transcriptURL: url)
    #expect(!session.isDraining)

    session.markDrainingForTesting(run)
    #expect(session.isDraining)
  }
}

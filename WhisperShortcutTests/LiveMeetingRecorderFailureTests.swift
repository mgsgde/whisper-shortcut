import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// A recorder that died by itself must end the meeting like a Stop, not leave it on "Recording"
/// until the 30 s safety net.
@MainActor
@Suite("Live meeting recorder failure", .serialized)
struct LiveMeetingRecorderFailureTests {

  final class Box: @unchecked Sendable {
    var finished = 0
    var stopping = 0
    var pending: [CheckedContinuation<String, Error>] = []
  }

  private func makeSession(box: Box) -> LiveMeetingSession {
    LiveMeetingSession(
      transcribeChunk: { _ in
        try await withCheckedThrowingContinuation { box.pending.append($0) }
      },
      cleanUpAudioFile: { _ in },
      appStateIsRecordingMeeting: { false },
      onStopping: { box.stopping += 1 },
      onFinished: { box.finished += 1 },
      onBacklogChanged: {},
      stopSafetyNetDelay: 3600,
      postProcessingOverride: { _, _ in },
      presentEndedMeetingAlert: { _ in })
  }

  private func makeFile() throws -> (dir: URL, file: URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("r205-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("Meeting-r205-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: file.path, contents: Data())
    return (dir, file)
  }

  @Test("A meeting that captured nothing finishes at once and is discarded")
  func emptyMeetingEndsImmediately() async throws {
    let store = LiveMeetingTranscriptStore.shared
    store.clearForNewMeeting()
    defer { store.clearForNewMeeting() }
    let (dir, file) = try makeFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    let box = Box()
    let session = makeSession(box: box)
    session.beginSessionWithoutRecorder(transcriptFile: file)
    session.attachInactiveRecorderForTesting()

    session.endMeetingAfterRecorderFailureForTesting()

    #expect(box.stopping == 1)
    #expect(box.finished == 1)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(!session.isRecording)
  }

  @Test("A chunk already handed over is transcribed before the meeting finishes")
  func pendingChunkFinishesFirst() async throws {
    let store = LiveMeetingTranscriptStore.shared
    store.clearForNewMeeting()
    defer { store.clearForNewMeeting() }
    let (dir, file) = try makeFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    let box = Box()
    let session = makeSession(box: box)
    session.beginSessionWithoutRecorder(transcriptFile: file)
    session.attachInactiveRecorderForTesting()
    session.liveMeetingRecorder(
      didFinishChunk: URL(fileURLWithPath: "/tmp/r205-chunk.wav"), chunkIndex: 0, startTime: 5,
      isSilent: false, isFinal: true)

    session.endMeetingAfterRecorderFailureForTesting()
    #expect(box.finished == 0)
    #expect(session.pendingChunkCount == 1)

    for _ in 0..<50 where box.pending.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
    box.pending.removeFirst().resume(returning: "captured before the failure")
    for _ in 0..<100 where box.finished == 0 { try await Task.sleep(nanoseconds: 20_000_000) }

    #expect(box.finished == 1)
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    #expect(text.contains("captured before the failure"))
  }
}

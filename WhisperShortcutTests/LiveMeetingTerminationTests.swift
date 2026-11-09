import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Quitting the app mid-meeting must not lose audio that has no transcript yet: a chunk whose
/// transcription call is still running dies with the process unless it is moved into the backlog.
@MainActor
@Suite("Live meeting termination", .serialized)
struct LiveMeetingTerminationTests {

  final class Box: @unchecked Sendable {
    var pending: [CheckedContinuation<String, Error>] = []
  }

  private func makeSession(box: Box) -> LiveMeetingSession {
    LiveMeetingSession(
      transcribeChunk: { _ in
        try await withCheckedThrowingContinuation { box.pending.append($0) }
      },
      cleanUpAudioFile: { _ in },
      appStateIsRecordingMeeting: { false },
      onStopping: {},
      onFinished: {},
      onBacklogChanged: {},
      stopSafetyNetDelay: 3600,
      postProcessingOverride: { _, _ in },
      presentEndedMeetingAlert: { _ in })
  }

  @Test("A chunk still being transcribed is kept in the backlog on termination")
  func inFlightChunkIsPreserved() async throws {
    let store = LiveMeetingTranscriptStore.shared
    store.clearForNewMeeting()
    defer { store.clearForNewMeeting() }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("r203-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("Meeting-r203-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: file.path, contents: Data())
    let stem = file.deletingPathExtension().lastPathComponent
    defer { MeetingAudioBacklog.remove(stem: stem) }
    let audio = dir.appendingPathComponent("chunk.wav")
    FileManager.default.createFile(atPath: audio.path, contents: Data([1, 2, 3]))

    let box = Box()
    let session = makeSession(box: box)
    session.beginSessionWithoutRecorder(transcriptFile: file)
    session.liveMeetingRecorder(
      didFinishChunk: audio, chunkIndex: 0, startTime: 42, isSilent: false, isFinal: false)
    for _ in 0..<50 where box.pending.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
    #expect(box.pending.count == 1)

    session.preserveForTermination()

    let kept = MeetingAudioBacklog.items(stem: stem)
    #expect(kept.map(\.startTime) == [42])
    #expect(!FileManager.default.fileExists(atPath: audio.path))
    box.pending.removeFirst().resume(throwing: CancellationError())
  }

  @Test("A chunk whose text already landed is not kept again")
  func transcribedChunkIsNotPreserved() async throws {
    let store = LiveMeetingTranscriptStore.shared
    store.clearForNewMeeting()
    defer { store.clearForNewMeeting() }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("r203b-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("Meeting-r203b-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: file.path, contents: Data())
    let stem = file.deletingPathExtension().lastPathComponent
    defer { MeetingAudioBacklog.remove(stem: stem) }
    let audio = dir.appendingPathComponent("chunk.wav")
    FileManager.default.createFile(atPath: audio.path, contents: Data([1]))

    let box = Box()
    let session = makeSession(box: box)
    session.beginSessionWithoutRecorder(transcriptFile: file)
    session.liveMeetingRecorder(
      didFinishChunk: audio, chunkIndex: 0, startTime: 10, isSilent: false, isFinal: false)
    for _ in 0..<50 where box.pending.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
    box.pending.removeFirst().resume(returning: "hello there")
    for _ in 0..<100 where store.chunks.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
    #expect(store.chunks.map(\.text) == ["hello there"])

    session.preserveForTermination()

    #expect(MeetingAudioBacklog.items(stem: stem).isEmpty)
  }
}

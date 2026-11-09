import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Retry Meeting Transcription: which meetings it touches and what it leaves behind.
@MainActor
@Suite("Live meeting backlog retry", .serialized)
struct LiveMeetingRetryBacklogTests {

  /// Records every file it was asked to transcribe and answers with `reply`.
  final class Calls: @unchecked Sendable {
    var urls: [URL] = []
    var reply: String
    init(reply: String = "") { self.reply = reply }
  }

  static func makeSession(calls: Calls) -> LiveMeetingSession {
    LiveMeetingSession(
      transcribeChunk: { url in
        calls.urls.append(url)
        return calls.reply
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

  static func keepAudio(stem: String, start: TimeInterval) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("r207-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let wav = dir.appendingPathComponent("chunk.wav")
    FileManager.default.createFile(atPath: wav.path, contents: Data([0]))
    #expect(MeetingAudioBacklog.retain(wav, stem: stem, startTime: start))
    return MeetingAudioBacklog.directory(stem: stem)
      .appendingPathComponent(MeetingAudioBacklog.filename(startTime: start))
  }

  @Test("Kept audio of a meeting whose transcript was deleted is dropped, not transcribed")
  func deletedTranscriptIsNotRecreated() async throws {
    let stem = "Meeting-r210-\(UUID().uuidString)"
    defer { MeetingAudioBacklog.remove(stem: stem) }
    _ = try Self.keepAudio(stem: stem, start: 30)
    let calls = Calls(reply: "should never appear")
    let session = Self.makeSession(calls: calls)

    await session.retryBacklog(stems: [stem], announce: false)

    #expect(calls.urls.isEmpty)
    #expect(MeetingAudioBacklog.items(stem: stem).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: MeetingListService.transcriptURL(forStem: stem).path))
  }

  @Test("Retry during a live meeting transcribes its kept audio into the live transcript")
  func retryDuringLiveMeeting() async throws {
    let store = LiveMeetingTranscriptStore.shared
    store.clearForNewMeeting()
    defer { store.clearForNewMeeting() }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("r207-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("Meeting-r207-\(UUID().uuidString).txt")
    let stem = file.deletingPathExtension().lastPathComponent
    defer { MeetingAudioBacklog.remove(stem: stem) }
    try MeetingAudioBacklog.transcriptText([LiveMeetingChunk(startTime: 60, text: "later")])
      .write(to: file, atomically: true, encoding: .utf8)
    let kept = try Self.keepAudio(stem: stem, start: 15)

    let calls = Calls(reply: "recovered words")
    let session = Self.makeSession(calls: calls)
    session.beginSessionWithoutRecorder(transcriptFile: file)
    store.appendChunk(startTime: 60, text: "later")

    await session.retryBacklog(stems: [stem], announce: false)

    #expect(calls.urls.map(\.lastPathComponent) == [kept.lastPathComponent])
    #expect(store.chunks.map(\.text) == ["recovered words", "later"])
    let onDisk = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    #expect(LiveMeetingTranscriptStore.parseTranscript(onDisk).map(\.text) == ["recovered words", "later"])
    #expect(MeetingAudioBacklog.items(stem: stem).isEmpty)
  }

  @Test("A retry pass leaves post-processing to the queued pass of a meeting that ended mid-retry")
  func queuedPassOwnsPostProcessing() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("r207-pp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stem = "Meeting-r207pp-\(UUID().uuidString)"
    let file = MeetingListService.transcriptURL(forStem: stem)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "[00:00] hello\n\n".write(to: file, atomically: true, encoding: .utf8)
    defer {
      try? FileManager.default.removeItem(at: file)
      MeetingAudioBacklog.remove(stem: stem)
    }
    _ = try Self.keepAudio(stem: stem, start: 15)

    final class Gate: @unchecked Sendable {
      var passes = 0
      var waiting: CheckedContinuation<String, Error>?
    }
    let gate = Gate()
    let session = LiveMeetingSession(
      transcribeChunk: { _ in
        try await withCheckedThrowingContinuation { gate.waiting = $0 }
      },
      cleanUpAudioFile: { _ in },
      appStateIsRecordingMeeting: { false },
      onStopping: {},
      onFinished: {},
      onBacklogChanged: {},
      stopSafetyNetDelay: 3600,
      postProcessingOverride: { _, _ in gate.passes += 1 },
      presentEndedMeetingAlert: { _ in })

    // The first pass is held mid-transcription; a second request arrives and is queued behind it.
    let first = Task { @MainActor in await session.retryBacklog(stems: [stem], announce: false) }
    for _ in 0..<100 where gate.waiting == nil { try await Task.sleep(nanoseconds: 20_000_000) }
    #expect(gate.waiting != nil)
    let second = Task { @MainActor in await session.retryBacklog(stems: [stem], announce: false) }
    try await Task.sleep(nanoseconds: 100_000_000)
    gate.waiting?.resume(returning: "recovered")
    await first.value
    await second.value
    for _ in 0..<50 where gate.passes == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
    try await Task.sleep(nanoseconds: 200_000_000)

    #expect(gate.passes == 1)
  }
}

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Chunk work belongs to the meeting run that produced it. These tests drive two runs through one
/// session and prove that a late completion from run 1 can neither touch run 2's pending count nor
/// write into run 2's transcript, and that run 1's stop safety net cannot finish run 2.
@MainActor
@Suite("Meeting run isolation")
struct MeetingRunIsolationTests {

  /// A transcription that stays in flight until the test releases it.
  final class Gate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        if opened { c.resume() } else { continuation = c }
      }
    }
    func open() {
      opened = true
      continuation?.resume()
      continuation = nil
    }
  }

  final class Harness: @unchecked Sendable {
    let gates: [String: Gate]
    var finishedCount = 0
    init(gates: [String: Gate]) { self.gates = gates }
  }

  private func tempTranscript(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("MeetingRunIsolation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(name).txt")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return url
  }

  private func makeSession(_ harness: Harness, appShowsMeeting: Bool = true) -> LiveMeetingSession {
    LiveMeetingSession(
      transcribeChunk: { url in
        await harness.gates[url.lastPathComponent]?.wait()
        return "text of \(url.lastPathComponent)"
      },
      cleanUpAudioFile: { _ in },
      appStateIsRecordingMeeting: { appShowsMeeting },
      onStopping: {},
      onFinished: { harness.finishedCount += 1 },
      onBacklogChanged: {})
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 25_000_000) }
  }

  @Test("A late chunk from run 1 neither touches run 2's pending count nor its transcript")
  func lateChunkStaysInItsRun() async throws {
    let gate1 = Gate(), gate2 = Gate()
    let harness = Harness(gates: ["chunk-run1.m4a": gate1, "chunk-run2.m4a": gate2])
    let session = makeSession(harness)
    let url1 = try tempTranscript("run1"), url2 = try tempTranscript("run2")

    let run1 = session.beginRunForTesting(transcriptURL: url1)
    session.liveMeetingRecorder(
      didFinishChunk: URL(fileURLWithPath: "/tmp/chunk-run1.m4a"), chunkIndex: 0, startTime: 0,
      isSilent: false, isFinal: false)
    #expect(run1.pendingChunks == 1)

    // Run 1 ends while its chunk is still transcribing (safety net zeroed the count), and a
    // second meeting starts and has a chunk of its own in flight.
    run1.pendingChunks = 0
    let run2 = session.beginRunForTesting(transcriptURL: url2)
    session.liveMeetingRecorder(
      didFinishChunk: URL(fileURLWithPath: "/tmp/chunk-run2.m4a"), chunkIndex: 0, startTime: 0,
      isSilent: false, isFinal: false)
    #expect(run2.pendingChunks == 1)

    gate1.open()
    await waitUntil { (try? String(contentsOf: url1, encoding: .utf8))?.isEmpty == false }

    #expect((try? String(contentsOf: url1, encoding: .utf8))?.contains("text of chunk-run1.m4a") == true)
    #expect((try? String(contentsOf: url2, encoding: .utf8)) == "")
    #expect(run1.pendingChunks == 0)  // clamped, never -1
    // Let the main-actor completion of run 1 run.
    try? await Task.sleep(nanoseconds: 200_000_000)
    #expect(run2.pendingChunks == 1)
    #expect(session.currentRun === run2)
    #expect(harness.finishedCount == 0)
    #expect(!LiveMeetingTranscriptStore.shared.chunks.contains { $0.text.contains("chunk-run1") })

    // Run 2's own chunk still lands in run 2's transcript.
    gate2.open()
    await waitUntil { run2.pendingChunks == 0 }
    #expect((try? String(contentsOf: url2, encoding: .utf8))?.contains("text of chunk-run2.m4a") == true)
    #expect(!((try? String(contentsOf: url1, encoding: .utf8)) ?? "").contains("chunk-run2"))
  }

  @Test("Run 1's stop safety net cannot finish run 2")
  func staleSafetyNetIsIgnored() throws {
    let harness = Harness(gates: [:])
    let session = makeSession(harness)
    let run1 = session.beginRunForTesting(transcriptURL: try tempTranscript("a"))
    session.markDrainingForTesting(run1)

    // Run 1 finished earlier; the meeting was resumed as run 2 and is stopping again.
    let run2 = session.beginRunForTesting(transcriptURL: try tempTranscript("b"))
    session.markDrainingForTesting(run2)
    run2.pendingChunks = 1  // its final chunk is still being transcribed

    session.safetyNetFired(for: run1)

    #expect(harness.finishedCount == 0)
    #expect(session.currentRun === run2)
    #expect(run2.pendingChunks == 1)
    #expect(run2.awaitingFinalChunk)
    if case .draining(let current) = session.phase { #expect(current === run2) } else {
      Issue.record("run 2 must still be draining")
    }
  }

  @Test("A late final-chunk completion of run 1 cannot finish run 2")
  func lateCompletionCannotFinishNextRun() async throws {
    let gate1 = Gate()
    let harness = Harness(gates: ["chunk-run1.m4a": gate1])
    let session = makeSession(harness)
    let run1 = session.beginRunForTesting(transcriptURL: try tempTranscript("a"))
    session.liveMeetingRecorder(
      didFinishChunk: URL(fileURLWithPath: "/tmp/chunk-run1.m4a"), chunkIndex: 0, startTime: 0,
      isSilent: false, isFinal: true)
    session.markDrainingForTesting(run1)
    run1.awaitingFinalChunk = false

    let run2 = session.beginRunForTesting(transcriptURL: try tempTranscript("b"))
    session.markDrainingForTesting(run2)
    run2.awaitingFinalChunk = false  // would finish on any completion that reached it

    gate1.open()
    await waitUntil { run1.pendingChunks == 0 }
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(harness.finishedCount == 0)
    #expect(session.currentRun === run2)
  }

  @Test("A stray stop or end with no run leaves app state alone")
  func strayStopWithNoRunIsIgnored() {
    let harness = Harness(gates: [:])
    let session = makeSession(harness, appShowsMeeting: false)
    session.stop()
    session.end(preferredName: "late", discard: false)
    #expect(harness.finishedCount == 0)
  }

  @Test("Stop with no run while the app still shows a meeting finishes at once, without a drain")
  func stopWithNoRunWhileAppShowsMeetingFinishesNow() {
    let harness = Harness(gates: [:])
    let session = makeSession(harness, appShowsMeeting: true)
    session.stop()
    #expect(harness.finishedCount == 1)
  }
}

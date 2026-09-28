import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Pins the attribution that `noSpeechDetected` and the cancel/deadline signals read (queue #5,
/// #8): the context the caller sets must be visible a dozen frames down, in child tasks too,
/// and must be gone again once the call returns.
@Suite("No-speech attribution and processing clock")
struct NoSpeechContextTests {

  private final class TestResourceAnchor {}

  private static var sampleAudioURL: URL {
    guard let url = Bundle(for: TestResourceAnchor.self)
      .url(forResource: "sample", withExtension: "wav") else {
      fatalError("sample.wav missing from test bundle resources")
    }
    return url
  }

  @Test("run() exposes origin, duration and peak, including to child tasks")
  func contextReachesChildTasks() async throws {
    let url = Self.sampleAudioURL
    let expectedMs = Int((try AudioDuration.avAudioFileSeconds(url) * 1000).rounded())

    let seen = await NoSpeechContext.run(.streamingChunk, audioURL: url, peakDb: -30) {
      await Task { NoSpeechContext.current }.value
    }
    #expect(seen?.origin == .streamingChunk)
    #expect(seen?.durationMs == expectedMs)
    #expect(seen?.peakDb == -30)
    #expect(NoSpeechContext.current == nil)
  }

  @Test("an unreadable file still attributes the origin, with no duration")
  func missingFileKeepsOrigin() async {
    let missing = URL(fileURLWithPath: "/tmp/whisper-shortcut-missing-\(UUID().uuidString).wav")
    let seen = await NoSpeechContext.run(.promptHistory, audioURL: missing) { NoSpeechContext.current }
    #expect(seen?.origin == .promptHistory)
    #expect(seen?.durationMs == nil)
  }

  @Test("processing clock runs from start and stops when cleared")
  func processingClock() {
    let logger = ContextLogger.shared
    logger.noteProcessingStart(Date().addingTimeInterval(-2))
    let elapsed = logger.processingElapsedMs()
    #expect(elapsed.map { $0 >= 2000 && $0 < 10_000 } == true)
    logger.noteProcessingStart(nil)
    #expect(logger.processingElapsedMs() == nil)
  }

  @Test("only non-TTS processing counts as processing")
  func processingStateEdges() {
    #expect(AppState.processing(.transcribing).isNonTTSProcessing)
    #expect(AppState.processing(.prompting).isNonTTSProcessing)
    #expect(!AppState.processing(.ttsProcessing).isNonTTSProcessing)
    #expect(!AppState.idle.isNonTTSProcessing)
  }
}

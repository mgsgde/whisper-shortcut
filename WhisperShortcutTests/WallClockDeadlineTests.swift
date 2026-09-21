import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Pins the wall-clock helper around WhisperKit load/decode. A task-group shape would
/// wait for the stuck child before returning the timeout; these tests fail if that
/// regression comes back.
@Suite("Wall-clock deadline")
struct WallClockDeadlineTests {

  @Test("An operation that ignores cancellation still times out at the deadline")
  func ignoringCancellationTimesOutAtDeadline() async {
    let started = Date()
    await #expect(throws: TranscriptionError.requestTimeout) {
      try await WallClockDeadline.run(seconds: 0.2) {
        for _ in 0..<40 {
          try? await Task.sleep(for: .milliseconds(100))
        }
        return 1
      }
    }
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed < 1.5, "deadline took \(elapsed)s; a task-group shape is still waiting for the work")
  }

  @Test("A fast success is returned unchanged")
  func fastSuccess() async throws {
    let started = Date()
    let value = try await WallClockDeadline.run(seconds: 5) { 42 }
    #expect(value == 42)
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed < 1, "fast path took \(elapsed)s")
  }

  @Test("The work's own error is rethrown unchanged")
  func workErrorPropagates() async {
    await #expect(throws: TranscriptionError.noSpeechDetected) {
      try await WallClockDeadline.run(seconds: 5) {
        throw TranscriptionError.noSpeechDetected
      }
    }
  }

  @Test("Caller cancellation throws CancellationError without waiting for the work")
  func callerCancellation() async {
    let started = Date()
    let task = Task {
      try await WallClockDeadline.run(seconds: 5) {
        try await Task.sleep(for: .seconds(5))
        return 1
      }
    }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed < 1, "cancellation took \(elapsed)s; still waiting for the work")
  }

  @Test("Timeout cancels the work task")
  func timeoutCancelsTheWork() async {
    actor Flag {
      var value = false
      func set() { value = true }
    }
    let flag = Flag()
    await #expect(throws: TranscriptionError.requestTimeout) {
      try await WallClockDeadline.run(seconds: 0.2) {
        do {
          try await Task.sleep(for: .seconds(5))
        } catch {
          await flag.set()
          throw error
        }
        return 0
      }
    }
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await flag.value)
  }

  @Test("Load and decode deadlines match the measured budgets")
  func deadlinePins() {
    #expect(LocalSpeechService.modelLoadDeadline == 300)
    #expect(LocalSpeechService.decodeDeadline(forAudioSeconds: nil) == 60)
    #expect(LocalSpeechService.decodeDeadline(forAudioSeconds: 10) == 90)
    #expect(LocalSpeechService.decodeDeadline(forAudioSeconds: 300) == 960)
    #expect(
      LocalSpeechService.decodeDeadline(forAudioSeconds: 0)
        >= NetworkDeadline.transcriptionRequestTimeout)
  }
}

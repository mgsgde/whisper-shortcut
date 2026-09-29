import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Cancelling a job must reach every stage of its work, not just the first network call — the
/// Voice Feedback bug this owner fixes was a second stage that kept running after a cancel.
@MainActor
@Suite("Voice job")
struct VoiceJobTests {

  @Test("cancel() stops a later stage of the job's work")
  func cancelReachesLaterStages() async throws {
    let job = VoiceJob(mode: .voiceFeedback, audioURL: URL(fileURLWithPath: "/tmp/x.wav"))
    var reachedSecondStage = false
    var sawCancellation = false
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      job.run {
        do {
          try await Task.sleep(nanoseconds: 50_000_000)  // stage 1
          try Task.checkCancellation()
          reachedSecondStage = true                      // stage 2 must not run
        } catch {
          sawCancellation = error is CancellationError
        }
        done.resume()
      }
      job.cancel()
    }
    #expect(sawCancellation)
    #expect(!reachedSecondStage)
  }
}

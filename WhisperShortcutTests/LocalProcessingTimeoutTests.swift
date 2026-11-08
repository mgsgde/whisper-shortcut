import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Pins the user-facing copy for on-device Whisper deadlines.
///
/// PR #75 surfaced `LocalSpeechService`'s load/decode deadlines as `.requestTimeout`, whose popup
/// says "over 60 seconds" and blames the internet connection. `.localProcessingTimeout` keeps the
/// retry semantics but must never mention the network.
@Suite("Local processing timeout")
struct LocalProcessingTimeoutTests {

  @Test("A local deadline names the stage and the real budget, never the network", arguments: [
    (LocalProcessingStage.decode, 90, "transcribe", "decode"),
    (.modelLoad, 300, "load", "model load"),
  ])
  func localTimeoutIsLocalCopy(stage: LocalProcessingStage, seconds: Int, stageWord: String, label: String) {
    let message = SpeechErrorFormatter.format(.localProcessingTimeout(stage: stage, seconds: seconds))
    #expect(message.contains("Local Model Timeout"), "\(label)")
    #expect(message.contains("\(seconds)"), "\(label)")
    #expect(message.contains(stageWord), "\(label)")
    #expect(!message.lowercased().contains("internet"), "\(label)")
    #expect(!message.contains("API"), "\(label)")
  }

  @Test("A local deadline is retryable, like the network one")
  func localTimeoutIsRetryable() {
    #expect(TranscriptionError.localProcessingTimeout(stage: .decode, seconds: 1).isRetryable)
  }

  @Test("ModelStore treats a local load deadline as a deadline, not a corrupt download")
  func modelStoreIsDeadline() {
    #expect(
      ModelStore<ModelStoreTests.FakeModel>.isDeadline(
        TranscriptionError.localProcessingTimeout(stage: .modelLoad, seconds: 1)))
    #expect(!ModelStore<ModelStoreTests.FakeModel>.isDeadline(ModelStoreError.fileError("corrupt")))
  }
}

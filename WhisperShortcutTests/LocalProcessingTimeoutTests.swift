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

  @Test("A decode deadline formats as a local-model timeout with the real budget")
  func decodeTimeoutIsLocalCopy() {
    let message = SpeechErrorFormatter.format(.localProcessingTimeout(stage: .decode, seconds: 90))
    #expect(message.contains("Local Model Timeout"))
    #expect(message.contains("90"))
    #expect(message.contains("transcribe"))
    #expect(!message.lowercased().contains("internet"))
    #expect(!message.contains("API"))
  }

  @Test("A model-load deadline names the load, not the network")
  func modelLoadTimeoutIsLocalCopy() {
    let message = SpeechErrorFormatter.format(.localProcessingTimeout(stage: .modelLoad, seconds: 300))
    #expect(message.contains("Local Model Timeout"))
    #expect(message.contains("300"))
    #expect(message.contains("load"))
    #expect(!message.lowercased().contains("internet"))
    #expect(!message.contains("API"))
  }

  @Test("The short status still reads as a timeout")
  func shortStatusIsTimeout() {
    #expect(
      SpeechErrorFormatter.shortStatus(.localProcessingTimeout(stage: .decode, seconds: 90))
        .contains("Timeout"))
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

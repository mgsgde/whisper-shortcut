import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// A doctor's dictation must survive a model that cannot be prepared (offline mode). Model errors
/// keep the audio and offer Retry, but must never join the automatic retry/backoff loop.
@Suite("Keep audio on model-preparation errors")
struct KeepAudioOnModelErrorsTests {

  @Test("ModelStoreError of any kind keeps the audio and offers Retry")
  func modelStoreErrors() {
    #expect(ModelStoreError.downloadFailed("offline").offersManualRetry)
    #expect(ModelStoreError.fileError("Model not found").offersManualRetry)
  }

  @Test("modelNotAvailable keeps the audio but is not auto-retryable")
  func modelNotAvailable() {
    let error = TranscriptionError.modelNotAvailable(.parakeetUltra)
    #expect(error.keepsAudioForManualRetry)
    #expect(error.offersManualRetry)
    #expect(!error.isRetryable)
  }

  @Test("localModelFailed (Parakeet, WhisperKit, MLX) keeps the audio but is not auto-retryable")
  func localModelFailed() {
    let cases: [TranscriptionError] = [
      .localModelFailed("Failed to load model: boom"),
      .localModelFailed("Offline model not initialized"),
      .localModelFailed("Offline transcription failed: decode error"),
    ]
    for error in cases {
      #expect(error.keepsAudioForManualRetry)
      #expect(error.offersManualRetry)
      #expect(!error.isRetryable)
    }
  }

  @Test("Offline-model message wording no longer decides anything: plain fileError never keeps audio")
  func fileErrorNeverKeepsAudio() {
    for message in ["Failed to load model: x", "Offline model not initialized", "Audio file not found"] {
      let error = TranscriptionError.fileError(message)
      #expect(!error.keepsAudioForManualRetry)
      #expect(!error.offersManualRetry)
    }
  }

  @Test("Cloud-only OpenAI too-long message does not offer a futile Retry")
  func cloudOnlyMessage() {
    let error = TranscriptionError.fileError("Audio is too long for OpenAI Dictate Prompt (30.0 MB > 25.0 MB limit). Switch to a Gemini Dictate Prompt model for longer recordings.")
    #expect(!error.offersManualRetry)
  }

  @Test("Unrelated fileError does not keep the audio")
  func unrelatedFileError() {
    let error = TranscriptionError.fileError("Audio file not found")
    #expect(!error.keepsAudioForManualRetry)
    #expect(!error.offersManualRetry)
  }

  @Test("Transient errors still offer Retry; permanent ones still do not")
  func existingBehaviourUnchanged() {
    #expect(TranscriptionError.networkError("x").offersManualRetry)
    #expect(TranscriptionError.requestTimeout.offersManualRetry)
    #expect(!TranscriptionError.emptyFile.offersManualRetry)
    #expect(!TranscriptionError.invalidAPIKey.offersManualRetry)
  }

  @Test("Foreign errors do not keep the audio")
  func foreignError() {
    #expect(!URLError(.notConnectedToInternet).offersManualRetry)
  }
}

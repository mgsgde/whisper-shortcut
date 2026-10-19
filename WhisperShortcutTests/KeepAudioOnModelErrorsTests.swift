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

  @Test("Model-load fileError keeps the audio but is not auto-retryable")
  func modelLoadFileError() {
    let load = TranscriptionError.fileError("Failed to load model: boom. Please try downloading it again in Settings.")
    let uninitialized = TranscriptionError.fileError("Offline model not initialized")
    for error in [load, uninitialized] {
      #expect(error.keepsAudioForManualRetry)
      #expect(error.offersManualRetry)
      #expect(!error.isRetryable)
    }
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

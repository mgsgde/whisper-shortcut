import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Pins the decode-deadline tail `LocalSpeechService` shares between Whisper and Parakeet (R67),
/// and the R98 regression: a cancelled Whisper decode used to fall into the generic catch and
/// surface as "model missing, download it again" (counted as `.offlineModelMissing`).
@Suite("Local decode deadline")
struct LocalDecodeDeadlineTests {

  private static func whisperMapping(_ error: Error) -> Error {
    LocalSpeechService.whisperDecodeFailure(error, modelType: .whisperLargeTurbo)
  }

  @Test("A CancellationError from the decode stays a CancellationError under Whisper's mapping")
  func cancelledDecodeIsNotAMissingModel() async {
    do {
      _ = try await LocalSpeechService.withDecodeDeadline(
        seconds: 5, audioSeconds: 1, model: "test",
        op: { () async throws -> String in throw CancellationError() },
        mapFailure: Self.whisperMapping)
      Issue.record("expected CancellationError")
    } catch is CancellationError {
      // expected
    } catch {
      Issue.record("expected CancellationError, got \(error)")
    }
  }

  @Test("Cancelling the calling task mid-decode surfaces as CancellationError")
  func cancellingCallerSurfacesCancellation() async {
    let task = Task { () async throws -> String in
      try await LocalSpeechService.withDecodeDeadline(
        seconds: 30, audioSeconds: 1, model: "test",
        op: {
          try await Task.sleep(nanoseconds: 20_000_000_000)
          return "never"
        },
        mapFailure: Self.whisperMapping)
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("expected CancellationError")
    } catch is CancellationError {
      // expected
    } catch {
      Issue.record("expected CancellationError, got \(error)")
    }
  }

  @Test("The deadline maps to a local decode timeout with the real budget")
  func deadlineMapsToLocalTimeout() async {
    do {
      _ = try await LocalSpeechService.withDecodeDeadline(
        seconds: 0.05, audioSeconds: 1, model: "test",
        op: { () async throws -> String in
          try await Task.sleep(nanoseconds: 20_000_000_000)
          return "never"
        },
        mapFailure: Self.whisperMapping)
      Issue.record("expected a timeout")
    } catch TranscriptionError.localProcessingTimeout(let stage, _) {
      #expect(stage == .decode)
    } catch {
      Issue.record("expected localProcessingTimeout, got \(error)")
    }
  }

  @Test("A Whisper error that looks like a missing model still maps to modelNotAvailable")
  func missingModelHeuristicStaysForWhisper() async {
    struct Boom: LocalizedError { var errorDescription: String? { "MIL network could not be loaded" } }
    do {
      _ = try await LocalSpeechService.withDecodeDeadline(
        seconds: 5, audioSeconds: nil, model: "test",
        op: { () async throws -> String in throw Boom() },
        mapFailure: Self.whisperMapping)
      Issue.record("expected modelNotAvailable")
    } catch TranscriptionError.modelNotAvailable(let type) {
      #expect(type == .whisperLargeTurbo)
    } catch {
      Issue.record("expected modelNotAvailable, got \(error)")
    }
  }

  @Test("Other errors go to the engine's own mapping")
  func otherErrorsUseEngineMapping() async {
    do {
      _ = try await LocalSpeechService.withDecodeDeadline(
        seconds: 5, audioSeconds: 1, model: "test",
        op: { () async throws -> String in throw ParakeetBackendError.audioTooShort },
        mapFailure: { error in
          if case ParakeetBackendError.audioTooShort = error { return TranscriptionError.noSpeechDetected }
          return error
        })
      Issue.record("expected noSpeechDetected")
    } catch TranscriptionError.noSpeechDetected {
      // expected
    } catch {
      Issue.record("expected noSpeechDetected, got \(error)")
    }
  }
}

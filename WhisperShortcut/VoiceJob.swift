import Foundation

/// One finished recording being turned into a result — Dictate, Dictate Prompt or Voice Feedback,
/// outside a live meeting (meeting segments are not cancellable and carry no job).
///
/// Before this, a job was only an audio URL in `MenuBarController.currentJobAudioURL`, and the work
/// ran in a bare `Task {}` nobody held. Cancelling could only reach the inner `SpeechService` call,
/// so Voice Feedback's second stage (`proposeChange`) kept running and its review panel could still
/// open after the user cancelled, and a late cancellation tail could `finish()` a recording the user
/// had started in the meantime. The job owns its task, so cancel reaches every stage, and
/// "is this result still wanted?" is an identity check (`currentJob === job`) instead of a URL
/// comparison that every exit path had to keep in sync.
///
/// Main thread only, like the controller that owns it.
final class VoiceJob {
  let mode: AppState.RecordingMode
  let audioURL: URL
  private var task: Task<Void, Never>?

  init(mode: AppState.RecordingMode, audioURL: URL) {
    self.mode = mode
    self.audioURL = audioURL
  }

  /// Starts the job's work on the main actor. The pipelines touch `appState`, the clipboard and
  /// popups, all of which are main-thread only; their network stages hop off it on their own.
  func run(_ work: @escaping @MainActor () async -> Void) {
    task = Task { @MainActor in await work() }
  }

  /// Cancels every stage still running. The pipeline observes it as a `CancellationError` (or a
  /// cancelled `URLSession` request) and, because the controller has already dropped the job,
  /// cleans up without touching `appState`.
  func cancel() {
    task?.cancel()
  }
}

import Foundation

/// Slice 2 of plans/active/streaming-dictate.md: transcribes dictate chunks while the
/// user is still speaking, so pressing Stop only leaves the tail chunk to process.
///
/// One session is created per Dictate recording when the selected transcription model is
/// a cloud Gemini model (`makeIfEligible`). It consumes `ChunkedDictateRecorder`'s chunk
/// callbacks and transcribes each rotated-out chunk immediately through the regular
/// `SpeechService.transcribe` pipeline (which brings AAC transcoding, retries, and SPEED
/// logging for free). `finalTranscript()` joins the per-chunk transcripts in order.
///
/// Streaming is an optimization, never a correctness dependency: if anything goes wrong —
/// a chunk fails, the session is cancelled, a chunk is missing — `finalTranscript()`
/// returns nil and the caller falls back to single-shot transcription of the merged WAV.
///
/// Threading: `addChunk`/`addFinalChunk`/`cancel` are called on the main thread (recorder
/// callbacks and MenuBarController paths); `finalTranscript()` runs on a background task
/// strictly after all adds (the recorder fires `onFinalChunk` before the delegate
/// delivery that spawns it). `chunkTasks` is never mutated after that point — `cancel()`
/// only cancels the tasks — and the cancel flag is lock-protected.
final class DictateStreamingSession {
  private let speechService: SpeechService
  /// Transcription task per chunk index. Silent chunks get a pre-completed empty task.
  private var chunkTasks: [Int: Task<String, Error>] = [:]
  private var finalChunkIndex: Int?
  private let cancelLock = NSLock()
  private var _isCancelled = false
  private var isCancelled: Bool {
    cancelLock.lock()
    defer { cancelLock.unlock() }
    return _isCancelled
  }
  private let sessionStart = CFAbsoluteTimeGetCurrent()

  private init(speechService: SpeechService) {
    self.speechService = speechService
  }

  /// Creates a session when streaming can help: chunked recorder active and the selected
  /// Dictate model is a cloud Gemini model with a credential. All other providers (OpenAI,
  /// xAI, offline Whisper, self-hosted) return nil and keep the single-shot path.
  static func makeIfEligible(speechService: SpeechService) -> DictateStreamingSession? {
    guard AppConstants.useChunkedDictateRecorder else { return nil }
    let model = TranscriptionModel.loadSelected()
    guard model.isGemini, model.hasRequiredCredential else { return nil }
    return DictateStreamingSession(speechService: speechService)
  }

  /// Called from `ChunkedDictateRecorder.onChunkFinalized` while recording continues.
  func addChunk(url: URL, index: Int, isSilent: Bool) {
    guard !isCancelled, chunkTasks[index] == nil else { return }
    if isSilent {
      DebugLogger.logSpeech("STREAMING-DICTATE: Chunk \(index) is silent, skipping API call")
      chunkTasks[index] = Task { "" }
      return
    }
    DebugLogger.logSpeech("STREAMING-DICTATE: Transcribing chunk \(index) in flight (\(url.lastPathComponent))")
    chunkTasks[index] = Task { [speechService] in
      try await speechService.transcribe(audioURL: url, cancellable: false)
    }
  }

  /// Called from `ChunkedDictateRecorder.onFinalChunk` at stop, before the merged WAV is
  /// delivered. Only ever fires when at least one rotation happened.
  func addFinalChunk(url: URL, index: Int, isSilent: Bool) {
    guard !isCancelled, !chunkTasks.isEmpty else { return }
    finalChunkIndex = index
    addChunk(url: url, index: index, isSilent: isSilent)
  }

  /// Cancels all in-flight chunk transcriptions (recording discarded, processing
  /// cancelled, or the recording failed). The session delivers nothing afterwards.
  /// `chunkTasks` is deliberately left intact — `finalTranscript()` may be iterating it
  /// concurrently; the cancelled tasks throw and the cancel flag turns that into
  /// CancellationError.
  func cancel() {
    cancelLock.lock()
    let alreadyCancelled = _isCancelled
    _isCancelled = true
    cancelLock.unlock()
    guard !alreadyCancelled else { return }
    for task in chunkTasks.values { task.cancel() }
    DebugLogger.logSpeech("STREAMING-DICTATE: Session cancelled")
  }

  /// Awaits all chunk transcripts and joins them in recording order. Returns nil whenever
  /// the single-shot fallback should run instead: no rotation happened, a chunk is
  /// missing, every chunk was silent, or a chunk failed with a real error. Throws
  /// CancellationError when the session was cancelled — the caller must NOT fall back
  /// then (the user asked for no result at all).
  func finalTranscript() async throws -> String? {
    guard let finalIndex = finalChunkIndex else { return nil }
    if isCancelled { throw CancellationError() }

    var parts: [String] = []
    for index in 0...finalIndex {
      guard let task = chunkTasks[index] else {
        DebugLogger.logWarning("STREAMING-DICTATE: Chunk \(index) missing, falling back to single-shot")
        return nil
      }
      do {
        let text = try await task.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append(text) }
      } catch TranscriptionError.noSpeechDetected {
        DebugLogger.logSpeech("STREAMING-DICTATE: Chunk \(index) contained no speech, skipping")
      } catch {
        if isCancelled || error is CancellationError {
          throw CancellationError()
        }
        DebugLogger.logWarning(
          "STREAMING-DICTATE: Chunk \(index) failed (\(error.localizedDescription)), falling back to single-shot")
        return nil
      }
      if isCancelled { throw CancellationError() }
    }

    guard !parts.isEmpty else {
      DebugLogger.logSpeech("STREAMING-DICTATE: All chunks empty, deferring to single-shot path")
      return nil
    }

    let elapsed = CFAbsoluteTimeGetCurrent() - sessionStart
    DebugLogger.logSpeech(
      "SPEED: STREAMING-DICTATE: Assembled \(finalIndex + 1)-chunk transcript (\(parts.map(\.count).reduce(0, +)) chars, session \(String(format: "%.1f", elapsed))s)")
    return parts.joined(separator: " ")
  }
}

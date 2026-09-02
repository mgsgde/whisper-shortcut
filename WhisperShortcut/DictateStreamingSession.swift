import Foundation

/// Slice 2 of plans/active/streaming-dictate.md: transcribes dictate chunks while the
/// user is still speaking, so pressing Stop only leaves the tail chunk to process.
///
/// One session is created per Dictate recording when the selected transcription model is
/// a cloud STT provider — Gemini, OpenAI, or xAI — or a downloaded on-device Whisper
/// (`makeIfEligible`). It consumes
/// `ChunkedDictateRecorder`'s chunk callbacks and transcribes each rotated-out chunk
/// immediately through the regular `SpeechService.transcribe` pipeline, which routes per
/// provider and brings AAC transcoding (Gemini), retries, and SPEED logging for free.
/// `finalTranscript()` joins the per-chunk transcripts in order.
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

  /// Creates a session when streaming can help: the chunked recorder is active and the selected
  /// Dictate model is either a cloud STT provider (Gemini, OpenAI, xAI) with a credential or an
  /// on-device Whisper whose weights are already downloaded. Self-hosted endpoints stay out —
  /// unknown latency and rate-limit semantics — and keep the single-shot path.
  ///
  /// Offline Whisper was excluded until slice 4 (2026-09-02) over "whisper.cpp concurrency during
  /// recording untested". It is not actually concurrent: `LocalSpeechService` is an actor, so chunk
  /// decodes serialise behind one another, and at the measured rtf ≈ 0.15 a chunk decodes about six
  /// times faster than it was spoken — in-flight chunks cannot pile up behind the speaker.
  ///
  /// The **downloaded** check is the load-bearing half of the offline gate: an in-flight chunk must
  /// never be what triggers a multi-gigabyte download, mid-recording, behind the user's back. When
  /// the model is absent this returns nil and `SpeechService` still offers the download, with
  /// progress, at dictation time — exactly as before.
  static func makeIfEligible(speechService: SpeechService) -> DictateStreamingSession? {
    guard AppConstants.useChunkedDictateRecorder else { return nil }
    let model = TranscriptionModel.loadSelected()
    guard isEligible(
      model: model,
      hasCredential: model.hasRequiredCredential,
      offlineModelDownloaded: model.isOfflineModelAvailable())
    else { return nil }
    return DictateStreamingSession(speechService: speechService)
  }

  /// The gate's whole decision, with its two pieces of global state passed in.
  ///
  /// Split out the way `OfflineMode.shouldBlock(_:offlineMode:)` is: the real inputs are the
  /// Keychain and the model folder on disk, and a test that had to plant a credential and a
  /// 1.6 GB download to assert "xAI streams, an undownloaded Whisper does not" would assert
  /// nothing useful. Pure, so every model can be checked.
  static func isEligible(
    model: TranscriptionModel, hasCredential: Bool, offlineModelDownloaded: Bool
  ) -> Bool {
    if model.isOffline { return offlineModelDownloaded }
    guard model.isGemini || model.isOpenAI || model.isXAI else { return false }
    return hasCredential
  }

  /// Called from `ChunkedDictateRecorder.onChunkFinalized` while recording continues.
  func addChunk(url: URL, index: Int, isSilent: Bool) {
    cancelLock.lock()
    defer { cancelLock.unlock() }
    guard !_isCancelled, chunkTasks[index] == nil else { return }
    if isSilent {
      DebugLogger.logSpeech("STREAMING-DICTATE: Chunk \(index) is silent, skipping API call")
      chunkTasks[index] = Task { "" }
      return
    }
    DebugLogger.logSpeech("STREAMING-DICTATE: Transcribing chunk \(index) in flight (\(url.lastPathComponent))")
    chunkTasks[index] = Task { [speechService] in
      // reportsProgress: false — a long chunk (>45s of speech without a silence boundary)
      // gets chunk-split internally; letting that drive the global progress delegate would
      // hijack the app state machine away from `.recording` and strand the main pipeline.
      try await speechService.transcribe(audioURL: url, cancellable: false, reportsProgress: false)
    }
  }

  /// Called from `ChunkedDictateRecorder.onFinalChunk` at stop, before the merged WAV is
  /// delivered. Only ever fires when at least one rotation happened.
  func addFinalChunk(url: URL, index: Int, isSilent: Bool) {
    cancelLock.lock()
    let cancelled = _isCancelled
    let hasChunks = !chunkTasks.isEmpty
    cancelLock.unlock()
    guard !cancelled, hasChunks else { return }
    cancelLock.lock()
    finalChunkIndex = index
    cancelLock.unlock()
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
    let tasks = Array(chunkTasks.values)
    cancelLock.unlock()
    guard !alreadyCancelled else { return }
    for task in tasks { task.cancel() }
    DebugLogger.logSpeech("STREAMING-DICTATE: Session cancelled")
  }

  /// Awaits all chunk transcripts and joins them in recording order. Returns nil whenever
  /// the single-shot fallback should run instead: no rotation happened, a chunk is
  /// missing, every chunk was silent, or a chunk failed with a real error. Throws
  /// CancellationError when the session was cancelled — the caller must NOT fall back
  /// then (the user asked for no result at all).
  func finalTranscript() async throws -> String? {
    cancelLock.lock()
    let finalIndex = finalChunkIndex
    let snapshot = chunkTasks
    cancelLock.unlock()
    guard let finalIndex else { return nil }
    if isCancelled { throw CancellationError() }

    var parts: [String] = []
    for index in 0...finalIndex {
      guard let task = snapshot[index] else {
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

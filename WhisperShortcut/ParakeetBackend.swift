//
//  ParakeetBackend.swift
//  WhisperShortcut
//
//  Parakeet Ultra (NVIDIA Parakeet TDT 0.6B v3, retrained by Moondream) through FluidAudio.
//  The only file that imports FluidAudio — its `Language`, `AudioConverter` and friends stay out
//  of the rest of the app's namespace.
//

import AVFoundation
import Foundation
import FluidAudio

/// Offline dictation on a FastConformer/TDT model instead of Whisper.
///
/// Why this exists is in `LocalSpeechService`'s doc comment and in
/// `benchmarks/local-asr/README.md` → Results: on the user's own German recordings Parakeet Ultra
/// matched Whisper large-v3 turbo's accuracy (8.1 % vs 8.4 % WER against the cloud transcript) at
/// about 1/20 of the wait — 0.1 s instead of 1.9 s for a sentence, 0.5 s instead of 10 s for a
/// minute — because its encoder does not pad every call to a 30 s window.
///
/// Files live where FluidAudio puts them by default, `Application Support/FluidAudio/Models/`.
/// Both app targets are sandboxed, so that is inside the app container, next to
/// `WhisperShortcut/`. Keeping FluidAudio's default matters: its vocabulary boosting
/// (`VocabularyBoostingSession`) looks the CTC tokenizer up in the default directory, whatever
/// directory the models were loaded from.
final class ParakeetBackend: @unchecked Sendable {
  // `@unchecked`: every stored property is an actor or `Sendable`, and none is reassigned.
  private let manager: AsrManager
  /// Kept so the live preview can decode with the same weights (`makeSlidingWindowEngine`): handing
  /// `AsrModels` to another manager shares the loaded `MLModel`s, it does not load or download.
  private let models: AsrModels
  private let vocabulary = VocabularyBooster()
  private static let version: AsrModelVersion = .ultra
  private let converter = AudioConverter()

  private init(manager: AsrManager, models: AsrModels) {
    self.manager = manager
    self.models = models
  }

  // MARK: - Files

  /// FluidAudio's model root. Holds exactly the Parakeet download (Ultra + the CTC model), so it
  /// is also what Settings deletes and sizes.
  static var modelsRoot: URL {
    AsrModels.defaultCacheDirectory(for: version).deletingLastPathComponent()
  }

  private static var ultraDirectory: URL { AsrModels.defaultCacheDirectory(for: version) }
  /// Internal (not private) so the live test can remove just this part and watch it re-download.
  static var ctcDirectory: URL { CtcModels.defaultCacheDirectory(for: .ctc110m) }

  /// Every file the transcriber and (from S2) the vocabulary booster load. Checked before any
  /// load, so a partial download surfaces as "not downloaded" rather than as a load attempt.
  static var isDownloaded: Bool {
    AsrModels.modelsExist(at: ultraDirectory, version: version)
      && CtcModels.modelsExist(at: ctcDirectory)
  }

  /// Downloads Ultra (~600 MB), then the CTC model (~100 MB) the Glossary needs. Progress is one
  /// 0…1 fraction across both, weighted by size, so Settings shows a single bar.
  static func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
    _ = networkShutByDefault
    ModelHub.offlineMode = false
    defer { ModelHub.offlineMode = true }
    let ultraShare = 0.86
    try await AsrModels.download(version: version) { progress in
      onProgress(progress.fractionCompleted * ultraShare)
    }
    try Task.checkCancellation()
    // `CtcModels.download` reports no progress, which left the bar sitting at 86 % for the whole
    // ~100 MB. The ModelHub call underneath it does report, so the files come from there…
    if !CtcModels.modelsExist(at: ctcDirectory) {
      try await ModelHub.download(
        CtcModelVariant.ctc110m.repo, to: ctcDirectory.deletingLastPathComponent()
      ) { progress in
        onProgress(ultraShare + progress.fractionCompleted * (1 - ultraShare))
      }
    }
    try Task.checkCancellation()
    // …and one load compiles the model now, as `CtcModels.download` did, so the first dictation
    // with a Glossary does not pay for it.
    _ = try await CtcModels.load(from: ctcDirectory)
    onProgress(1)
  }

  // MARK: - Load

  /// Weights into memory. The first load after a download compiles the models for the Neural
  /// Engine; later loads come from the system's compile cache (0.4 s measured on an M1 Pro).
  ///
  /// FluidAudio's network switch is forced shut first. Left open, its loader contacts
  /// HuggingFace on its own: it re-downloads when a file is missing or the cached revision marker
  /// does not match, and on a load failure it *deletes the whole model folder* and fetches it again.
  /// None of that may happen at dictation time — not in Offline Mode, not in a practice without
  /// internet, and not as a silent 600 MB download. A load failure is surfaced instead, and
  /// Settings' Delete + Download is the repair. The switch opens only inside `download`.
  static func load() async throws -> ParakeetBackend {
    guard isDownloaded else {
      throw ParakeetBackendError.notDownloaded
    }
    let models = try await loadModelsOffline(from: ultraDirectory)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    return ParakeetBackend(manager: manager, models: models)
  }

  /// The FluidAudio load call with the network switch shut. Separate so a test can point it at
  /// an empty folder and see it fail as "missing" instead of reaching for HuggingFace.
  static func loadModelsOffline(from directory: URL) async throws -> AsrModels {
    _ = networkShutByDefault
    return try await AsrModels.load(from: directory, version: version)
  }

  /// FluidAudio's network switch, shut once per process before its first use. Loads only read
  /// it — writing it from every load could flip it back on under a running Settings download,
  /// which FluidAudio checks per request and would abort. Only `download` opens it, and puts it
  /// back when done.
  fileprivate static let networkShutByDefault: Void = { ModelHub.offlineMode = true }()

  // No `unload()`: `AsrManager.cleanup()` nils the models a decode in flight is still reading
  // across its suspension points, which failed dictations as "not initialized" when memory
  // pressure or a model switch unloaded mid-decode. Dropping the last reference to this object
  // frees everything once any running decode has let go of it.

  // MARK: - Transcribe

  /// - Parameters:
  ///   - language: ISO code from the Whisper language setting. Passed as FluidAudio's script hint
  ///     when it is one of the languages it knows; otherwise no hint (the model covers 25 European
  ///     languages and picks among them itself).
  ///   - vocabulary: the Glossary as terms (`SpeechService.glossaryKeywords`). Parakeet takes no
  ///     conditioning text; instead FluidAudio's CTC keyword spotter listens for these terms in the
  ///     audio and rescores the transcript where it hears one. Benchmarked on German practice
  ///     terms: 18/24 → 23/24, for ~0.2 s on a short clip. Empty → the plain, faster path.
  func transcribe(audioURL: URL, language: String?, vocabulary terms: [String]) async throws -> String {
    var state = TdtDecoderState.make(decoderLayers: Self.version.decoderLayers)
    let hint = language.flatMap(Language.init(rawValue:))
    if let language, hint == nil {
      DebugLogger.logWarning(
        "LOCAL-SPEECH: Parakeet does not cover language '\(language)'; transcribing without a hint")
    }
    do {
      guard !terms.isEmpty else {
        return try await manager.transcribe(audioURL, decoderState: &state, language: hint).text
      }
      // The spotter needs the samples too, so decode from them rather than reading the file twice.
      let samples = try converter.resampleAudioFile(audioURL)
      let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
      return await vocabulary.rescore(result, samples: samples, terms: terms)
    } catch let error as ASRError {
      switch error {
      case .invalidAudioData: throw ParakeetBackendError.audioTooShort
      case .notInitialized: throw ParakeetBackendError.notLoaded
      default: throw error
      }
    }
  }

  // MARK: - Live preview

  /// A sliding-window engine on this backend's weights, for the live text panel while dictating
  /// (`plans/active/live-dictate-preview.md`). No second download and no second copy of the
  /// model: FluidAudio's manager keeps references to the `MLModel`s already loaded here, and its
  /// decoder state is its own.
  ///
  /// Same language hint and Glossary as `transcribe`. A Glossary that cannot be applied (CTC
  /// model missing, no usable term) costs the preview its boosting, never the preview itself.
  fileprivate func makeSlidingWindowEngine(
    language: String?, vocabulary terms: [String]
  ) async throws -> SlidingWindowAsrManager {
    let hint = language.flatMap(Language.init(rawValue:))
    let engine = SlidingWindowAsrManager(config: ParakeetLivePreview.windowConfig.applying(language: hint))
    try await engine.loadModels(models)
    if !terms.isEmpty {
      do {
        let ctcModels = try await vocabulary.ctcModels()
        let context = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
        try await engine.configureVocabularyBoosting(vocabulary: context, ctcModels: ctcModels)
      } catch {
        DebugLogger.logWarning(
          "LIVE-PREVIEW: Glossary boosting skipped for the preview (\(error.localizedDescription))")
      }
    }
    return engine
  }
}

/// One dictation's live preview: 16 kHz mono buffers in, the engine's text out.
///
/// Created before the engine exists, so the audio tap can start with the recording: buffers queue
/// in `input` while the model loads and the engine is built, and `connect` drains them. Without
/// that, the first seconds of every dictation never reached the preview.
///
/// Never part of the result. Stopping does not flush or finish the engine — the pasted text comes
/// from `ParakeetBackend.transcribe` on the complete recording, so the preview's tail is simply
/// dropped.
final class ParakeetLivePreview: @unchecked Sendable {
  // `@unchecked`: the continuation and stream are thread-safe; `engine`, `tasks` and `stopped`
  // are only touched under `lock`.

  /// New audio per window. FluidAudio's default layout (2 s left + 11 s + 2 s right) updates once
  /// every 11 s, far too slowly to read along. 9 + 4 + 2 still fills the model's fixed 15 s input
  /// (`validate()` passes at exactly 240 000 samples): text arrives at 6 s, 10 s, 14 s, … Each
  /// window decodes from a fresh decoder state and suppresses audio earlier windows covered, so the
  /// left context only warms the decoder up; FluidAudio itself considers ~4 s enough. Cost: the
  /// full 15 s window every 4 s (3.75× the audio, against 1.36× for the default) — the cost guard
  /// (plan, Design 6) decides whether 4 s holds or the hop must grow.
  static let hopSeconds: TimeInterval = 4
  static let rightContextSeconds: TimeInterval = 2
  static let windowConfig = SlidingWindowAsrConfig(
    chunkSeconds: hopSeconds,
    leftContextSeconds: 9,
    rightContextSeconds: rightContextSeconds,
    minContextForConfirmation: 10,
    confirmationThreshold: 0.85)
  /// The format `append` expects. Converting in the app with one long-lived converter lets
  /// FluidAudio take its fast path; its own `resampleBuffer` builds a new converter per buffer and
  /// resets the resampler state each time.
  static let sampleRate: Double = 16_000

  private let input: AsyncStream<AVAudioPCMBuffer>
  private let audioInput: AsyncStream<AVAudioPCMBuffer>.Continuation
  private let lock = NSLock()
  private var engine: SlidingWindowAsrManager?
  private var tasks: [Task<Void, Never>] = []
  private var stopped = false

  init() {
    let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
    input = stream
    audioInput = continuation
  }

  /// From any thread (the audio tap calls it on its render thread). Never blocks; queues until
  /// `connect` has built the engine.
  func append(_ buffer: AVAudioPCMBuffer) {
    audioInput.yield(buffer)
  }

  /// Builds the engine on `backend`'s weights and starts decoding, beginning with the audio queued
  /// so far. `onText` receives FluidAudio's own `confirmedTranscript` / `volatileTranscript` after
  /// every window, on a background task. Throws `CancellationError` when stopped meanwhile.
  func connect(
    to backend: ParakeetBackend, language: String?, vocabulary terms: [String],
    onText: @escaping @Sendable (_ confirmed: String, _ volatile: String) -> Void
  ) async throws {
    let engine = try await backend.makeSlidingWindowEngine(language: language, vocabulary: terms)
    // Subscribed before the engine starts, so not even the first window's update is missed.
    let updates = await engine.transcriptionUpdates
    try await engine.startStreaming(source: .microphone)
    let input = self.input
    let attached = lock.withLock { () -> Bool in
      guard !stopped else { return false }
      self.engine = engine
      // One consumer, so buffers reach the engine in capture order.
      tasks = [
        Task {
          for await buffer in input {
            await engine.streamAudio(buffer)
          }
        },
        Task {
          // The update only signals "a window was decoded"; the text is read from the engine,
          // which has already repaired the seam the update cannot describe.
          for await _ in updates {
            let snapshot = await engine.livePreviewSnapshot()
            onText(snapshot.confirmed, snapshot.volatile)
          }
        },
      ]
      return true
    }
    guard attached else {
      await engine.cancel()
      throw CancellationError()
    }
  }

  /// Idempotent. Drops whatever audio is still queued.
  func stop() {
    let (engine, tasks) = lock.withLock { () -> (SlidingWindowAsrManager?, [Task<Void, Never>]) in
      stopped = true
      let running = (self.engine, self.tasks)
      self.engine = nil
      self.tasks = []
      return running
    }
    audioInput.finish()
    tasks.forEach { $0.cancel() }
    if let engine {
      Task { await engine.cancel() }
    }
  }
}

private extension SlidingWindowAsrManager {
  /// Both texts in one actor turn, so no window lands between the two reads.
  func livePreviewSnapshot() -> (confirmed: String, volatile: String) {
    (confirmedTranscript, volatileTranscript)
  }
}

/// CTC vocabulary boosting for one glossary at a time.
///
/// Building a session tokenises every term and loads the CTC model (~100 MB), so it is built on
/// the first dictation that has a glossary and reused until the glossary text changes. An actor
/// because a meeting's live chunks and a dictation can decode side by side.
private actor VocabularyBooster {
  /// A task, not a value: two cold-cache rescores (a meeting chunk and a dictation) would
  /// otherwise both pass a nil check across the `await` and load the ~100 MB model twice.
  private var ctcLoad: Task<CtcModels, Error>?
  private var session: (terms: [String], session: VocabularyBoostingSession)?

  /// The rescored transcript, or the plain one when boosting cannot run — a missing CTC model or
  /// a glossary with no usable term must cost the Glossary, never the dictation.
  func rescore(_ result: ASRResult, samples: [Float], terms: [String]) async -> String {
    do {
      let session = try await session(for: terms)
      let rescored = await session.rescore(
        text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
      if let rescored, rescored.wasModified {
        DebugLogger.log(
          "LOCAL-SPEECH: Parakeet vocabulary applied \(rescored.replacements.filter(\.shouldReplace).count) replacement(s)")
      }
      return rescored?.text ?? result.text
    } catch {
      DebugLogger.logWarning(
        "LOCAL-SPEECH: Parakeet vocabulary boosting skipped (\(error.localizedDescription))")
      return result.text
    }
  }

  /// The CTC model, loaded once and shared by the final rescore and the live preview.
  func ctcModels() async throws -> CtcModels {
    let load = ctcLoad ?? Task {
      // Same network rule as the transcriber: the CTC model goes through FluidAudio's ModelHub.
      _ = ParakeetBackend.networkShutByDefault
      return try await CtcModels.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
    }
    ctcLoad = load
    do {
      return try await load.value
    } catch {
      ctcLoad = nil  // retry on the next dictation rather than caching the failure
      throw error
    }
  }

  private func session(for terms: [String]) async throws -> VocabularyBoostingSession {
    if let cached = session, cached.terms == terms { return cached.session }
    let ctcModels = try await self.ctcModels()
    let context = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
    let built = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels)
    session = (terms, built)
    DebugLogger.log("LOCAL-SPEECH: Parakeet vocabulary built from \(terms.count) glossary term(s)")
    return built
  }
}

enum ParakeetBackendError: LocalizedError {
  case notDownloaded
  /// FluidAudio refuses audio under 0.3 s — a tap, not a dictation.
  case audioTooShort
  /// The models went away under a decode; the caller reloads once and retries.
  case notLoaded

  var errorDescription: String? {
    switch self {
    case .notDownloaded: return String(localized: "Parakeet Ultra is not fully downloaded.")
    case .audioTooShort: return String(localized: "The recording is too short to transcribe.")
    case .notLoaded: return String(localized: "Parakeet Ultra was not loaded.")
    }
  }
}

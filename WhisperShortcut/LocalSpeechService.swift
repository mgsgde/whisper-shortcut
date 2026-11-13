//
//  LocalSpeechService.swift
//  WhisperShortcut
//
//  Offline speech-to-text using WhisperKit or Parakeet (CoreML)
//

import Foundation
import AVFoundation
import CoreML
import Darwin
import WhisperKit

/// Offline dictation through WhisperKit — or, for `OfflineEngine.parakeet`, through
/// `ParakeetBackend`. Loading, the silence gate, idle/memory-pressure unloads, deadlines and the
/// `SPEED:` lines are shared; only the decode call differs. Everything below about the ~3 s floor
/// is Whisper's.
///
/// # Why offline dictation feels slow, and what does not fix it (measured 2026-09-03)
///
/// Read this before optimising anything here — the four obvious ideas have all been tried and
/// three of them are dead ends. Every WhisperKit call costs a **fixed ~3 s floor on an M1 Pro**,
/// whether the audio holds 1.8 s or 16 s of speech, and that floor is what the user waits through
/// after Stop once streaming has taken the rest. The full table, method and falsifiers are in
/// `plans/active/streaming-dictate.md` → "Where the fixed cost per call goes"; the benchmark that
/// produces it is `OfflineWhisperBenchmarkTests.realRecordingBreakdown`, and every decode logs its
/// own breakdown as `SPEED: LOCAL-SPEECH timings …` (see `timingsSummary`).
///
/// The floor is **the model, not this code**:
///
/// - **The encoder is half to two thirds of every call**, because Whisper pads every window to
///   30 s and runs the full large-v3 encoder over it: 2–6 s of encoder for a 2 s clip just as for
///   a 15 s one. So **shortening `dictateChunkMinDuration` cannot lower the wait** — the cost is
///   per 30 s window, not per second of speech. (An earlier note in the plan claimed the encoder
///   was cheap and decode tracked output tokens; that came from a clip that produced no tokens
///   and was written before the encoder timing was visible.)
/// - **The Whisper Glossary roughly doubles the decoder loops.** `promptTokens` are pushed through
///   the decoder one at a time before the first real token (52 prompt tokens → 65 loops for a
///   12-token transcript) at 7–25 tok/s, i.e. +1.5–3 s per window, and on a 30 s recording it also
///   triggered two temperature fallbacks the no-glossary arm did not need. Same characters out.
///   Dropping it is not the answer (it exists because those terms get misheard); keeping it short
///   is.
/// - **Chunk decodes overlap on the GPU** and slow each other down. This actor does *not* serialise
///   them: `transcribe` suspends at `await whisperKit.transcribe`, so a rotated in-flight chunk and
///   the tail decode run side by side (logged 2026-09-03: a 16 s chunk took 4.3 s instead of 3.3 s
///   with the tail beside it). The plan's older "the actor serialises chunk decodes" claim is wrong.
/// - **`.vad` chunking is not a lever either** — measured, shipped and reverted the same day; see
///   the `chunkingStrategy` parameter on `transcribe`.
///
/// What is actually left, in order of expected payoff — none of it measured yet, none of it
/// started:
///
/// 1. **A FastConformer/TDT model instead of Whisper** — *done as `OfflineModelType.parakeetUltra`
///    (`plans/active/parakeet-offline.md`); measured at ~0.1 s for a sentence on the same M1 Pro.*
///    Original note: Parakeet TDT 0.6B v3 via FluidAudio,
///    CoreML/ANE, 25 European languages incl. German). Its encoder is ~20 ms per window against
///    Whisper's seconds, so a 2 s tail would cost ~100 ms rather than ~3 s. This is the only path
///    to the latency users compare us against — and note that **Wispr Flow, the usual comparison,
///    is cloud-only** (no on-device model; ≤700 ms p99 from their server pipeline), so its speed is
///    not evidence that a local model can be that fast. Open question: no `promptTokens` glossary;
///    FluidAudio offers CTC vocabulary boosting (+97 MB) whose value for German domain terms is
///    untested. Tracked as `plans/improvement-plan-2026-09.md` F15, second half.
/// 2. **Encoder on the ANE with the `_632MB` turbo variant.** See `OfflineModelType.usesNeuralEngine`
///    for why large models are on the GPU today — and note the 14-minute ANE compile behind that
///    decision was never allowed to finish, so it is unknown, not disproven.
/// 3. **Serialising chunk decodes**, so the tail never shares the GPU with a still-running chunk.
actor LocalSpeechService {
  static let shared = LocalSpeechService()
  
  /// The one resident engine, with the model it was loaded for — the single source of truth for
  /// "what is in memory". `nil` after an unload.
  private var loaded: Loaded?
  private var whisperKit: WhisperKit? {
    if case .whisper(let kit, _)? = loaded { return kit }
    return nil
  }
  private var parakeet: ParakeetBackend? {
    if case .parakeet(let backend, _)? = loaded { return backend }
    return nil
  }
  private var currentModelType: OfflineModelType? { loaded?.modelType }
  /// The load `initializeModel` is currently running, so concurrent callers share it.
  private var inFlightLoad: (type: OfflineModelType, task: Task<Void, Error>)?
  /// The last model that was loaded, kept across unloads so `transcribe` can put it back.
  /// `currentModelType` is cleared by `unloadModel`; this deliberately is not.
  private var lastLoadedModelType: OfflineModelType?
  private let lifetime = ModelLifetimeGuards()
  /// WhisperKit's own breakdown of the most recent decode, in the shape `timingsSummary` renders.
  /// Read by `OfflineWhisperBenchmarkTests` so a benchmark can attribute a slow call to the
  /// encoder, the prefill or the token loop instead of guessing from the total.
  private(set) var lastDecodeTimingsSummary: String?

  /// Same threshold `AudioRecorder` uses (−45 dB). Duplicated because that type is not shared
  /// with this actor; do not invent a second VAD.
  private static let silenceThresholdDB: Float = -45
  /// RMS amplitude a 100 ms frame must exceed to count as voice activity, for the Whisper-only
  /// gate in `hasVoiceActivity(in:)`. WhisperKit's own `EnergyVAD` default, kept rather than
  /// tuned: the gate only has to answer "is there any speech in this clip at all", and a higher
  /// value starts rejecting quiet dictation.
  private static let vadEnergyThreshold: Float = 0.02
  /// How far above the −45 dB silence gate a clip's peak must sit before the VAD verdict is
  /// overruled. A clip that is quiet overall (breath, room noise) stays gated; one with a clear
  /// peak is decoded even when no 100 ms frame crossed the RMS threshold, because that is quiet
  /// speech rather than silence.
  private static let vadGatePeakMarginDB: Float = 15
  /// Matches typical Ollama `keep_alive` so Whisper Turbo is not held for the app's lifetime —
  /// but only for a model that is no longer selected, see `unloadIfNotSelected`.
  private static let idleUnloadAfter: TimeInterval = 5 * 60

  /// Superset of the two former copies. The decode path added `"load"` in `02feb4dd`; the
  /// init path now uses the same predicate, so a load-time error that only mentions "load"
  /// is classified as a missing model too.
  private static func looksLikeMissingModel(_ message: String) -> Bool {
    let lowercasedError = message.lowercased()
    return lowercasedError.contains("mil network") ||
      lowercasedError.contains("mlmodelc") ||
      lowercasedError.contains("model") && (lowercasedError.contains("not found") || lowercasedError.contains("missing") || lowercasedError.contains("read") || lowercasedError.contains("load"))
  }

  /// Wall-clock ceilings for the two WhisperKit calls that previously ran until the user
  /// cancelled. Turbo weights load in 3.7–6.1 s on an M1 Pro; `preparingMessage` promises "a few
  /// minutes" for the one-time compile; the 14-minute ANE compile is what `usesNeuralEngine`
  /// already prevents. 300 s honours that copy and still catches the pathological case. Decode
  /// realtime-factor on real recordings is 0.34–0.54 with Turbo
  /// (`plans/active/streaming-dictate.md`); large-v3 is several times slower. Floor + 3× audio
  /// is 4–9× the measured cost and fires only on a wedged decode, never on a long recording on
  /// a slow Mac.
  static let modelLoadDeadline: TimeInterval = 300
  static let decodeDeadlineFloor: TimeInterval = 60
  static let decodeDeadlineRealtimeFactor: Double = 3
  static func decodeDeadline(forAudioSeconds seconds: Double?) -> TimeInterval {
    decodeDeadlineFloor + decodeDeadlineRealtimeFactor * max(0, seconds ?? 0)
  }

  /// Exactly one engine is ever resident. `@unchecked Sendable` because `WhisperKit` is not
  /// Sendable: a value is built inside the deadline's closure and only stored by this actor
  /// afterwards, never touched from two places at once.
  private enum Loaded: @unchecked Sendable {
    case whisper(WhisperKit, OfflineModelType)
    case parakeet(ParakeetBackend, OfflineModelType)

    var modelType: OfflineModelType {
      switch self {
      case .whisper(_, let type), .parakeet(_, let type): return type
      }
    }
  }

  /// Weights of either engine are in memory.
  private var hasLoadedModel: Bool { loaded != nil }
  
  private init() {}
  
  // MARK: - Initialize Model
  /// Single-flight: this actor suspends inside the load, so without it the prewarmer and the
  /// dictation path both passed the "already loaded" check and loaded twice, and two different
  /// models could end up resident at once. Same-type callers join the running load; a different
  /// type waits for it to finish first.
  func initializeModel(_ modelType: OfflineModelType) async throws {
    while let current = inFlightLoad {
      if current.type == modelType {
        // Joiner: its own cancellation does not stop a load somebody else owns.
        try await current.task.value
        return
      }
      _ = try? await current.task.value
      if inFlightLoad?.task == current.task { inFlightLoad = nil }  // guarantees progress, no spin
    }
    let task = Task { try await self.performInitializeModel(modelType) }
    inFlightLoad = (modelType, task)
    defer { if inFlightLoad?.task == task { inFlightLoad = nil } }
    // Only the owner propagates cancellation (`ModelStore.cancelDownload` cancels the
    // `ensureReady` run that awaits this); the load used to be cancelled structurally.
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func performInitializeModel(_ modelType: OfflineModelType) async throws {
    // Check if already initialized with the same model
    if let current = currentModelType, current == modelType, hasLoadedModel {
      DebugLogger.log("LOCAL-SPEECH: Model \(modelType.displayName) already loaded")
      scheduleIdleUnload()
      return
    }

    DebugLogger.log("LOCAL-SPEECH: Initializing model: \(modelType.displayName)")
    
    // Unload previous model if exists
    if hasLoadedModel {
      unloadModel()
    }

    if modelType.engine == .parakeet {
      // The completeness check is not a formality here — FluidAudio downloads a missing file on load.
      try await loadEngine(
        modelType, incompleteFolder: "model folder",
        load: { .parakeet(try await ParakeetBackend.load(), modelType) },
        mapFailure: { error in
          if case ParakeetBackendError.notDownloaded = error {
            return TranscriptionError.modelNotAvailable(modelType)
          }
          let errorMessage = error.localizedDescription
          DebugLogger.logError("LOCAL-SPEECH: Parakeet initialization failed: \(errorMessage)")
          return TranscriptionError.localModelFailed(String(localized: "Failed to load model: \(errorMessage). The model may be incomplete or corrupted. Please try downloading it again in Settings."))
        })
      return
    }

    // Resolve the actual model path using ModelManager
    guard let modelPath = ModelManager.shared.resolveModelPath(for: modelType) else {
      DebugLogger.logError("LOCAL-SPEECH: Model path not found for \(modelType.displayName)")
      throw TranscriptionError.modelNotAvailable(modelType)
    }

    DebugLogger.log("LOCAL-SPEECH: Using model path: \(modelPath.path)")

    // Initialize WhisperKit with the specific model folder.
    //
    // `computeOptions` is the load-time decision, not a speed knob: leaving the audio encoder on
    // WhisperKit's `.cpuAndNeuralEngine` default makes the first load of a large model wait on a
    // CoreML→ANE compile that took over 14 minutes here without finishing. See
    // `OfflineModelType.usesNeuralEngine`.
    let encoderCompute: MLComputeUnits = modelType.usesNeuralEngine ? .cpuAndNeuralEngine : .cpuAndGPU
    let usesNeuralEngine = modelType.usesNeuralEngine
    let modelPathString = modelPath.path

    try await loadEngine(
      modelType, incompleteFolder: "compiled model folder",
      load: {
        // `prefillCompute` exists only on WhisperKit main after 1.1.0; the 1.1.0 pin we
        // ship against has no such knob — prefill follows `textDecoderCompute`.
        DebugLogger.log(
          "LOCAL-SPEECH: Compute units — encoder/decoder: \(usesNeuralEngine ? "CPU+ANE" : "CPU+GPU")")
        // Build `WhisperKitConfig` inside the Sendable closure from String + MLComputeUnits —
        // the config class itself is not Sendable. Assign actor state only after the call returns.
        let config = WhisperKitConfig(
          modelFolder: modelPathString,
          computeOptions: ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: encoderCompute,
            textDecoderCompute: encoderCompute)
        )
        return .whisper(try await WhisperKit(config), modelType)
      },
      mapFailure: { error in
        // Check if error is related to missing or incomplete model files
        let errorMessage = error.localizedDescription
        DebugLogger.logError("LOCAL-SPEECH: WhisperKit initialization failed: \(errorMessage)")

        if Self.looksLikeMissingModel(errorMessage) {
          // This is a model availability issue
          DebugLogger.logError("LOCAL-SPEECH: Model appears to be missing or incomplete")
          return TranscriptionError.modelNotAvailable(modelType)
        }

        // For other errors, wrap in fileError with more context
        return TranscriptionError.localModelFailed(String(localized: "Failed to load model: \(errorMessage). The model may be incomplete or corrupted. Please try downloading it again in Settings."))
      })
  }

  /// What both engines share: the completeness gate, the wall-clock deadline, committing the
  /// resident engine and the load log lines. Engine-specific work is `load` (builds the engine)
  /// and `mapFailure` (turns a non-timeout, non-cancellation load error into the error to throw).
  private func loadEngine(
    _ modelType: OfflineModelType,
    incompleteFolder: String,
    load: @escaping @Sendable () async throws -> Loaded,
    mapFailure: (Error) -> TranscriptionError
  ) async throws {
    guard ModelManager.shared.isModelAvailable(modelType) else {
      DebugLogger.logError(
        "LOCAL-SPEECH: Not loading \(modelType.displayName) — its \(incompleteFolder) is incomplete; the download has to finish first")
      throw TranscriptionError.modelNotAvailable(modelType)
    }
    let loadStart = CFAbsoluteTimeGetCurrent()
    do {
      let engine = try await WallClockDeadline.run(seconds: Self.modelLoadDeadline, operation: load)
      loaded = engine  // exactly one engine resident
      lastLoadedModelType = modelType
      startLifetimeGuardsIfNeeded()
      scheduleIdleUnload()
      let elapsed = CFAbsoluteTimeGetCurrent() - loadStart
      DebugLogger.logSuccess(
        "LOCAL-SPEECH: Model initialized successfully in \(String(format: "%.1f", elapsed))s")
      // Machine-readable twin of the line above, greppable next to the transcription numbers.
      // On a cold model this load is the single biggest item in front of the transcript, and the
      // only question that matters is whether it lands inside the recording window
      // (`ConnectionPrewarmer.warmOfflineModel`) or after Stop, where the user waits on it.
      DebugLogger.logSpeech(
        "SPEED: LOCAL-SPEECH load model=\(modelType.rawValue) "
          + "loadMs=\(String(format: "%.0f", elapsed * 1000))")
    } catch TranscriptionError.requestTimeout {
      DebugLogger.logError(
        "LOCAL-SPEECH: model load exceeded \(Int(Self.modelLoadDeadline))s wall-clock deadline for \(modelType.displayName) — aborting (LocalDeadline)")
      ContextLogger.shared.logRequestTimedOut(
        timeoutSeconds: Int(Self.modelLoadDeadline),
        logPrefix: "LOCAL-SPEECH",
        origin: .transcription,
        stage: "modelLoad",
        model: modelType.rawValue)
      throw TranscriptionError.localProcessingTimeout(
        stage: .modelLoad, seconds: Int(Self.modelLoadDeadline))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw mapFailure(error)
    }
  }

  // MARK: - Unload Model
  func unloadModel() {
    unloadModel(reason: "explicit")
  }

  private func unloadModel(reason: String) {
    guard hasLoadedModel else { return }
    DebugLogger.log("LOCAL-SPEECH: Unloading model (\(reason))")
    // Dropping the reference is the whole unload — see the note in `ParakeetBackend` on why it
    // must not call FluidAudio's `cleanup()` while a decode may still be running.
    loaded = nil
    lifetime.cancelIdleUnload()
  }

  private func startLifetimeGuardsIfNeeded() {
    lifetime.installMemoryPressureHandler {
      Task { await LocalSpeechService.shared.unloadModel(reason: "memory pressure") }
    }
  }

  private func scheduleIdleUnload() {
    lifetime.scheduleIdleUnload(after: Self.idleUnloadAfter) {
      await self.unloadIfNotSelected()
    }
  }

  /// The idle unload skips the model the user is actually dictating with.
  ///
  /// Measured on an M1 Pro with Turbo, a reload costs ~5 s for the weights plus ~4 s on the first
  /// decode that produces text — and dictations in the deployment this was measured for are minutes
  /// apart, so a five-minute idle window fired before nearly every one of them. Paying nine seconds
  /// per dictation to hand back memory the user is about to need again is the wrong trade; the
  /// memory-pressure source still unloads when the system genuinely wants the RAM back, and
  /// `SpeechService.setModel` unloads as soon as the selection moves to a cloud model, so this only
  /// ever keeps the model that is one keystroke away from being used.
  private func unloadIfNotSelected() {
    guard let current = currentModelType else { return }
    if TranscriptionModel.loadSelected().offlineModelType == current {
      DebugLogger.log(
        "LOCAL-SPEECH: Keeping \(current.displayName) loaded — it is the selected dictation model")
      return
    }
    unloadModel(reason: "idle")
  }
  
  // MARK: - Transcribe Audio
  /// - Parameter chunkingStrategy: `.vad` lets WhisperKit split audio longer than one 30 s window
  ///   at voice-activity boundaries and hand the pieces to `concurrentWorkerCount` workers (16 on
  ///   macOS) instead of walking the windows in sequence. Inert below 30 s — a single window is
  ///   not chunkable.
  ///
  ///   **Off by default, after being on by default for a few hours on 2026-09-02.** It was
  ///   switched on for a measured ~7–10 % (68 s of synthetic speech: 10.03/10.20 s sequential
  ///   against 8.92/9.25 s), with identical transcripts. That measurement was on `say`-synthesised
  ///   German, which has clean pauses, and it hid what real speech shows — the same 64 s recording,
  ///   decoded both ways:
  ///
  ///   | prompt | sequential | `.vad` |
  ///   |---|---|---|
  ///   | none | 958 chars, correct | 945 chars, "is twice" dropped at a seam |
  ///   | glossary | 975 / 975 chars | 688 / 676 chars — ~30 % of the transcript gone |
  ///
  ///   Chunks decode independently, so each one re-applies `promptTokens` with no carried context,
  ///   and the seams lose words. Eight percent does not buy that. The parameter stays so the
  ///   comparison can be re-run (`OfflineWhisperBenchmarkTests.chunkingStrategyComparison`); the
  ///   lever that actually removes the wait is streaming, not intra-file parallelism.
  /// - Parameter vocabulary: the Glossary as terms, for Parakeet (CTC vocabulary boosting).
  ///   Whisper ignores it and conditions on `prompt` instead.
  /// - Parameter spokenMarksOnly: Parakeet only, "Only when spoken" punctuation: guessed commas,
  ///   periods, "?" and "!" are removed by token timing (`ParakeetPunctuationTiming`). Whisper ignores it.
  func transcribe(
    audioURL: URL, language: String? = nil, prompt: String? = nil,
    vocabulary: [String] = [],
    spokenMarksOnly: Bool = false,
    chunkingStrategy: ChunkingStrategy? = nil
  ) async throws -> String {
    let transcribeStartTime = CFAbsoluteTimeGetCurrent()
    
    // Reload rather than fail if the weights went away since the caller checked.
    //
    // `SpeechService` asks `isLoaded` and then calls this — two hops into the actor, and the
    // memory-pressure source can unload in between. Before slice 4 that race was nearly
    // unreachable: one decode per dictation, started immediately after the check. Now a dictation
    // makes one call per chunk across the whole recording, and the window is the whole recording.
    // It was observed: a chunk failed with `fileError("WhisperKit not initialized")`, which made
    // `DictateStreamingSession` discard every other chunk's work and fall back to decoding the
    // merged WAV — correct output, but the streaming benefit silently lost.
    //
    // Reloading here closes the race for good, because inside the actor the check and the decode
    // cannot be separated by an unload.
    //
    // A model switch unloads the old model before it loads the new one, so a transcribe that
    // lands mid-switch also sees nothing loaded — and `lastLoadedModelType` is still the OLD
    // model. Reloading that would queue behind the switch, then unload the model the user just
    // selected. So first wait for a load of a DIFFERENT model that is already running; its
    // failure is its owner's to report, and the reload below then covers it. A running load of
    // the same model is joined by `initializeModel` below, which surfaces its error instead of
    // starting a second load after it failed.
    if !hasLoadedModel, let running = inFlightLoad, running.type != lastLoadedModelType {
      DebugLogger.log(
        "LOCAL-SPEECH: Model load in flight (\(running.type.displayName)) — waiting for it instead of reloading")
      _ = try? await running.task.value
    }
    if !hasLoadedModel, let reloadType = lastLoadedModelType {
      DebugLogger.logWarning(
        "LOCAL-SPEECH: Model was unloaded since the caller checked — reloading \(reloadType.displayName)")
      try await initializeModel(reloadType)
    }

    guard hasLoadedModel, currentModelType != nil else {
      throw TranscriptionError.localModelFailed(String(localized: "Offline model not initialized"))
    }
    
    DebugLogger.log("LOCAL-SPEECH: Starting transcription")
    DebugLogger.log("LOCAL-SPEECH: Audio file: \(audioURL.path)")
    if let language = language {
      DebugLogger.log("LOCAL-SPEECH: Language specified: \(language)")
    } else {
      DebugLogger.log("LOCAL-SPEECH: Language: auto-detect")
    }
    
    // Validate audio file
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
      throw TranscriptionError.fileError(String(localized: "Audio file not found"))
    }

    // Reuse AudioRecorder's peak-power gate before invoking Whisper: silence hallucinations
    // ("Thank you.") are cheaper to skip than to catch after the fact.
    if let peakDb = peakPowerDecibels(of: audioURL), peakDb < Self.silenceThresholdDB {
      DebugLogger.log(
        "LOCAL-SPEECH: Skipping Whisper — peak \(String(format: "%.1f", peakDb)) dB "
          + "below \(Self.silenceThresholdDB) dB silence gate")
      throw TranscriptionError.noSpeechDetected
    }
    scheduleIdleUnload()
    
    // Not just for the log line: this is the denominator of the realtime factor emitted at the
    // end of this method — the number that decides whether transcribing chunks *while* the user
    // still speaks can keep up with the recording at all (see `plans/active/streaming-dictate.md`
    // slice 4).
    var audioDuration: Double?
    do {
      let duration = try AudioDuration.avAudioFileSeconds(audioURL)
      audioDuration = duration
      DebugLogger.log("LOCAL-SPEECH: Audio duration: \(String(format: "%.2f", duration))s")
    } catch {
      DebugLogger.log("LOCAL-SPEECH: Could not determine audio duration")
    }
    let deadline = Self.decodeDeadline(forAudioSeconds: audioDuration)

    let text: String
    let decodeElapsed: Double
    if let parakeet {
      let decodeStart = CFAbsoluteTimeGetCurrent()
      do {
        text = try await performParakeetTranscription(
          parakeet, audioURL: audioURL, language: language, vocabulary: vocabulary, spokenMarksOnly: spokenMarksOnly,
          deadline: deadline, audioSeconds: audioDuration)
      } catch ParakeetBackendError.notLoaded {
        // Defensive: the backend object is never torn down under a decode any more, but if
        // FluidAudio still reports "not initialized", one clean reload is cheap (0.2 s) and
        // beats losing the dictation.
        guard let reloadType = currentModelType ?? lastLoadedModelType else { throw TranscriptionError.localModelFailed(String(localized: "Offline model not initialized")) }
        DebugLogger.logWarning("LOCAL-SPEECH: Parakeet reported not initialized — reloading once and retrying")
        unloadModel(reason: "not initialized")
        try await initializeModel(reloadType)
        guard let reloaded = self.parakeet else { throw TranscriptionError.localModelFailed(String(localized: "Offline model not initialized")) }
        do {
          text = try await performParakeetTranscription(
            reloaded, audioURL: audioURL, language: language, vocabulary: vocabulary, spokenMarksOnly: spokenMarksOnly,
            deadline: deadline, audioSeconds: audioDuration)
        } catch ParakeetBackendError.notLoaded {
          // Second failure after a clean reload: typed, so the recording is kept and Retry offered.
          throw TranscriptionError.localModelFailed(String(localized: "Offline model not initialized"))
        }
      }
      decodeElapsed = CFAbsoluteTimeGetCurrent() - decodeStart
    } else if let whisperKit {
      // Whisper-only voice-activity gate. The peak gate above only catches digital silence;
      // breath, a chair and keyboard noise sit well above −45 dB and still make Whisper emit
      // subtitle filler ("Thank you."). Measured on 400 non-speech clips with large-v3: text on
      // 112 (28 %) with the peak gate alone, 97 after lowering `no_speech_threshold` to 0.3, and
      // 9 with a VAD gate in front of the decode. Tightening the threshold is not the lever — a
      // confident hallucination has a high logprob and passes Whisper's own silence check, which
      // only discards a segment when `no_speech_prob > threshold` AND `avg_logprob` is low.
      //
      // A gate, never a chunker: `.vad` chunking loses words at the seams (see the
      // `chunkingStrategy` doc comment on `transcribe`), so the clip is either decoded whole or
      // not at all.
      //
      // The gate is deliberately conservative. `EnergyVAD` answers "did any 100 ms frame exceed
      // the RMS threshold", and quiet-but-real dictation can sit under it — dropping that would
      // lose a recording the user actually made. So the verdict only counts when the clip is also
      // quiet overall: a peak well above the silence gate contradicts "no speech" and is decoded
      // anyway. The hallucination this gate exists for is breath and room noise, which is quiet on
      // both measures.
      if let hasVoice = hasVoiceActivity(in: audioURL), !hasVoice {
        let peakDb = peakPowerDecibels(of: audioURL)
        let contradictsVAD = peakDb.map { $0 > Self.silenceThresholdDB + Self.vadGatePeakMarginDB } ?? false
        if contradictsVAD {
          DebugLogger.log(
            "LOCAL-SPEECH: VAD found no active frame but peak is "
              + "\(String(format: "%.1f", peakDb ?? 0)) dB — decoding anyway (fail-open)")
        } else {
          DebugLogger.log(
            "LOCAL-SPEECH: Skipping Whisper — no voice activity in the clip (VAD gate)")
          ContextLogger.shared.logNoSpeechDetected(
            source: "localVADGate", peakDb: peakDb.map { String(format: "%.1f", $0) } ?? "n/a",
            durationMs: "n/a", logPrefix: "LOCAL-SPEECH")
          throw TranscriptionError.noSpeechDetected
        }
      }
      (text, decodeElapsed) = try await transcribeWithWhisper(
        whisperKit, audioURL: audioURL, language: language, prompt: prompt,
        chunkingStrategy: chunkingStrategy, deadline: deadline, audioSeconds: audioDuration)
    } else {
      throw TranscriptionError.localModelFailed(String(localized: "Offline model not initialized"))
    }

    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(text)
    // Phrase filter is offline Whisper only. Parakeet does not write subtitle filler, so a
    // short "Vielen Dank." from it is kept — nil duration fails open inside the filter.
    try TextProcessingUtility.validateSpeechText(
      normalizedText, mode: "LOCAL-SPEECH",
      audioSeconds: parakeet == nil ? audioDuration : nil)
    
    let totalElapsedTime = CFAbsoluteTimeGetCurrent() - transcribeStartTime
    DebugLogger.logSuccess("LOCAL-SPEECH: Transcription completed")
    DebugLogger.logSpeech("SPEED: Offline transcription total time: \(String(format: "%.3f", totalElapsedTime))s (\(String(format: "%.0f", totalElapsedTime * 1000))ms)")
    // One greppable line per offline transcription carrying everything the streaming decision
    // needs: `rtf` well below 1 means chunks can be decoded during the recording; near or above 1
    // means in-flight chunks would queue up behind the speech and streaming would make it worse.
    let rtfText = audioDuration.map { duration -> String in
      duration > 0 ? String(format: "%.3f", decodeElapsed / duration) : "n/a"
    } ?? "n/a"
    DebugLogger.logSpeech(
      "SPEED: LOCAL-SPEECH rtf model=\(currentModelType?.rawValue ?? "unknown") "
        + "audioS=\(audioDuration.map { String(format: "%.2f", $0) } ?? "n/a") "
        + "decodeS=\(String(format: "%.2f", decodeElapsed)) "
        + "totalS=\(String(format: "%.2f", totalElapsedTime)) "
        + "rtf=\(rtfText)")
    
    return normalizedText
  }

  /// Whisper's decode: glossary as `promptTokens`, the empty-result retry without them, and the
  /// segments joined. Returns the raw text and the decode time (retry included).
  private func transcribeWithWhisper(
    _ whisperKit: WhisperKit, audioURL: URL, language: String?, prompt: String?,
    chunkingStrategy: ChunkingStrategy?, deadline: TimeInterval, audioSeconds: Double?
  ) async throws -> (String, Double) {
    // Build promptTokens from dictation prompt if available
    let promptTokens: [Int]? = buildPromptTokens(prompt: prompt, whisperKit: whisperKit)
    let usedPrompt = promptTokens != nil && !(promptTokens!.isEmpty)
    
    // Build DecodingOptions
    // When language is nil we want auto-detect: must set detectLanguage: true explicitly,
    // because DecodingOptions defaults detectLanguage to !usePrefillPrompt (false when prefill is true).
    let decodeOptions = buildDecodingOptions(
      language: language, promptTokens: promptTokens, chunkingStrategy: chunkingStrategy)
    
    // Transcribe (with fallback retry if prompt causes empty result)
    let decodeStart = CFAbsoluteTimeGetCurrent()
    var transcriptionResults = try await performWhisperTranscription(
      whisperKit: whisperKit, audioURL: audioURL, decodeOptions: decodeOptions,
      deadline: deadline, audioSeconds: audioSeconds
    )
    
    // Fallback: if prompt was used and result is empty, retry without prompt (WhisperKit #372)
    if usedPrompt && isEmptyResult(transcriptionResults) {
      DebugLogger.logWarning("LOCAL-SPEECH: Prompt caused empty result; retrying without prompt")
      let fallbackOptions = buildDecodingOptions(
        language: language, promptTokens: nil, chunkingStrategy: chunkingStrategy)
      transcriptionResults = try await performWhisperTranscription(
        whisperKit: whisperKit, audioURL: audioURL, decodeOptions: fallbackOptions,
        deadline: deadline, audioSeconds: audioSeconds
      )
    }
    
    // Spans the retry too: a prompt that produces an empty result costs a second full decode,
    // and hiding that would flatter the realtime factor.
    let decodeElapsed = CFAbsoluteTimeGetCurrent() - decodeStart

    // Combine all segments into a single text
    guard !transcriptionResults.isEmpty else {
      throw TranscriptionError.localModelFailed(String(localized: "No transcription result"))
    }
    
    // Extract text from all segments
    return (transcriptionResults.map { $0.text }.joined(separator: " "), decodeElapsed)
  }

  /// Parakeet's decode under the same wall-clock deadline and error mapping as Whisper's.
  private func performParakeetTranscription(
    _ backend: ParakeetBackend, audioURL: URL, language: String?, vocabulary: [String],
    spokenMarksOnly: Bool, deadline: TimeInterval, audioSeconds: Double?
  ) async throws -> String {
    try await Self.withDecodeDeadline(
      seconds: deadline, audioSeconds: audioSeconds,
      model: currentModelType?.rawValue ?? "unknown",
      op: {
        try await backend.transcribe(
          audioURL: audioURL, language: language, vocabulary: vocabulary,
          spokenMarksOnly: spokenMarksOnly)
      },
      mapFailure: { error in
        switch error {
        case ParakeetBackendError.audioTooShort:
          return TranscriptionError.noSpeechDetected
        case ParakeetBackendError.notLoaded:
          return ParakeetBackendError.notLoaded
        default:
          // Not "corrupted, download again": the files passed the completeness check before this
          // load, and sending someone to re-download 700 MB for a decode error helps nobody.
          let errorMessage = error.localizedDescription
          DebugLogger.logError("LOCAL-SPEECH: Parakeet transcription failed: \(errorMessage)")
          return TranscriptionError.localModelFailed(String(localized: "Offline transcription failed: \(errorMessage)"))
        }
      })
  }

  /// The decode-deadline tail both engines share: run `op` under the wall-clock deadline, map the
  /// deadline to `localProcessingTimeout` (with the log line and the `ContextLogger` entry), let
  /// cancellation through untouched, and hand every other error to the engine's `mapFailure`.
  /// A cancelled decode is the caller's cancellation, never a model problem.
  static func withDecodeDeadline<T: Sendable>(
    seconds deadline: TimeInterval,
    audioSeconds: Double?,
    model: String,
    op: @escaping @Sendable () async throws -> T,
    mapFailure: (Error) -> Error
  ) async throws -> T {
    do {
      return try await WallClockDeadline.run(seconds: deadline, operation: op)
    } catch TranscriptionError.requestTimeout {
      let audioSecondsText = audioSeconds.map { String(format: "%.1f", $0) } ?? "?"
      DebugLogger.logError(
        "LOCAL-SPEECH: decode exceeded \(Int(deadline))s wall-clock deadline (audio \(audioSecondsText)s) — aborting (LocalDeadline)")
      ContextLogger.shared.logRequestTimedOut(
        timeoutSeconds: Int(deadline),
        logPrefix: "LOCAL-SPEECH",
        origin: .transcription,
        stage: "decode",
        model: model)
      throw TranscriptionError.localProcessingTimeout(stage: .decode, seconds: Int(deadline))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw mapFailure(error)
    }
  }

  /// Whisper's mapping for a failed decode. The missing-model heuristic is Whisper-only: its
  /// errors are free-form CoreML text, whereas Parakeet's are typed.
  static func whisperDecodeFailure(_ error: Error, modelType: OfflineModelType?) -> Error {
    let errorMessage = error.localizedDescription
    DebugLogger.logError("LOCAL-SPEECH: Transcription failed: \(errorMessage)")

    if looksLikeMissingModel(errorMessage) {
      DebugLogger.logError("LOCAL-SPEECH: Model appears to be missing or incomplete during transcription")
      if let modelType {
        return TranscriptionError.modelNotAvailable(modelType)
      } else {
        return TranscriptionError.localModelFailed(String(localized: "Model is missing or incomplete. Please download it in Settings."))
      }
    }

    return TranscriptionError.localModelFailed(String(localized: "Transcription failed: \(errorMessage). The model may be incomplete or corrupted. Please try downloading it again in Settings."))
  }

  // MARK: - Prompt Token Building
  
  /// Rewrites the user's glossary into something Whisper can safely be conditioned on.
  ///
  /// `promptTokens` is not an instruction channel. It is *example text in the style the transcript
  /// should have*, and the decoder simply continues it. The Whisper Glossary is authored for the
  /// cloud models too, where `Claude (not "Cloud")` reads as a rule — fed to Whisper verbatim it
  /// reads as a writing sample full of parentheses and quotation marks, and the decoder duly
  /// produces those.
  ///
  /// Measured on a 64 s recording (2026-09-02), same audio, same model:
  ///
  /// | prompt | result |
  /// |---|---|
  /// | none | 958 chars, correct |
  /// | glossary verbatim | **51 chars** on one run, 560 on another — the dictation is simply gone |
  /// | glossary verbatim, `.vad` | 1190 chars: `"Guardian"), "Guardian"), …` twenty times over |
  /// | glossary sanitised | 975 / 975 chars, correct |
  ///
  /// A user reported exactly this shape (`Cursor "Gigawats"), BNI, "Gigawatt")`) — their glossary's
  /// own terms and punctuation, looped. It was never a chunking bug; it predates streaming and hit
  /// every offline dictation with a non-empty glossary.
  ///
  /// Deliberately conservative: drop a leading `Terms:` label, drop parenthesised asides, drop
  /// quotation marks, tidy the separators. Everything else — the terms themselves, their spelling,
  /// their order — is left exactly as the user wrote it, because those are the whole point.
  static func sanitizeGlossaryForWhisper(_ glossary: String) -> String {
    var text = glossary.trimmingCharacters(in: .whitespacesAndNewlines)

    // A label, not example prose. Only an exact leading "Terms:" — anything else is the user's text.
    if let range = text.range(of: "Terms:", options: [.caseInsensitive, .anchored]) {
      text = String(text[range.upperBound...])
    }

    // `(not "Cloud")` and friends: the instruction half of an entry, and the source of the
    // parenthesis-and-quote shape the decoder copies.
    text = text.replacingOccurrences(
      of: "\\([^()]*\\)", with: "", options: .regularExpression)
    text = text.replacingOccurrences(
      of: "[\"\u{201C}\u{201D}\u{201E}\u{00AB}\u{00BB}]", with: "", options: .regularExpression)

    // Re-join the entries so stripping does not leave ", ," or trailing separators behind.
    let entries = text
      .split(whereSeparator: { $0 == "," || $0 == "\n" })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return entries.joined(separator: ", ")
  }

  /// Encodes the dictation prompt into token IDs suitable for Whisper's promptTokens,
  /// filtering out special tokens and truncating to 224 (Whisper's effective limit).
  private func buildPromptTokens(prompt: String?, whisperKit: WhisperKit) -> [Int]? {
    guard let rawPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawPrompt.isEmpty else {
      DebugLogger.log("LOCAL-SPEECH: No Whisper glossary sent (prompt empty)")
      return nil
    }
    let promptText = Self.sanitizeGlossaryForWhisper(rawPrompt)
    guard !promptText.isEmpty else {
      DebugLogger.log("LOCAL-SPEECH: No Whisper glossary sent (nothing left after sanitising)")
      return nil
    }
    if promptText != rawPrompt {
      DebugLogger.log(
        "LOCAL-SPEECH: Whisper glossary sanitised (\(rawPrompt.count) → \(promptText.count) chars); "
          + "parentheses and quotes make Whisper reproduce them")
    }
    
    guard let tokenizer = whisperKit.tokenizer else {
      DebugLogger.logWarning("LOCAL-SPEECH: No Whisper glossary sent (tokenizer not available)")
      return nil
    }
    
    let encoded = tokenizer.encode(text: promptText)
    let filtered = encoded.filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    let maxPromptTokens = 224
    let truncated = Array(filtered.prefix(maxPromptTokens))
    
    if truncated.isEmpty {
      DebugLogger.log("LOCAL-SPEECH: No Whisper glossary sent (encoded prompt empty after filter)")
      return nil
    }
    
    if filtered.count > maxPromptTokens {
      DebugLogger.log("LOCAL-SPEECH: Whisper glossary truncated from \(filtered.count) to \(maxPromptTokens) tokens")
    }
    DebugLogger.log("LOCAL-SPEECH: Whisper glossary sent as conditioning prompt (\(truncated.count) tokens, \(DebugLogger.redacted(promptText)))")
    
    return truncated
  }
  
  // MARK: - DecodingOptions Builder
  
  /// Fallback decodes cost a full re-run of the window each, and WhisperKit's default of 5 makes
  /// the worst case six times the normal one. Dictation is interactive — a user staring at the menu
  /// bar notices that far more than the rare marginal decode the last three attempts would have
  /// rescued. Two still covers the common case (temperature 0.0 → 0.2 → 0.4).
  private static let temperatureFallbackCount = 2

  private func buildDecodingOptions(
    language: String?, promptTokens: [Int]?, chunkingStrategy: ChunkingStrategy?
  ) -> DecodingOptions {
    // `suppressBlank` removes the empty leading token Whisper likes to start a window with. It is
    // cheap and harmless, and it takes away the token that the silence hallucinations grow out of
    // ("Thank you." is what the decoder writes after an empty first token on non-speech audio).
    if let language = language {
      return DecodingOptions(
        language: language,
        temperatureFallbackCount: Self.temperatureFallbackCount,
        skipSpecialTokens: true,
        promptTokens: promptTokens,
        suppressBlank: true,
        chunkingStrategy: chunkingStrategy
      )
    } else {
      return DecodingOptions(
        language: nil,
        temperatureFallbackCount: Self.temperatureFallbackCount,
        detectLanguage: true,
        skipSpecialTokens: true,
        promptTokens: promptTokens,
        suppressBlank: true,
        chunkingStrategy: chunkingStrategy
      )
    }
  }
  
  // MARK: - WhisperKit Transcription Call
  
  private func performWhisperTranscription(
    whisperKit: WhisperKit,
    audioURL: URL,
    decodeOptions: DecodingOptions,
    deadline: TimeInterval,
    audioSeconds: Double?
  ) async throws -> [TranscriptionResult] {
    let whisperKitStartTime = CFAbsoluteTimeGetCurrent()
    let audioPath = audioURL.path
    let modelType = currentModelType
    let results = try await Self.withDecodeDeadline(
      seconds: deadline, audioSeconds: audioSeconds,
      model: modelType?.rawValue ?? "unknown",
      op: {
        try await whisperKit.transcribe(
          audioPath: audioPath,
          decodeOptions: decodeOptions
        ) { _ in
          // Returning false stops the decode at the next token. Before slice 4 this always
          // returned true, which was harmless: the only decode ran after Stop, with the user
          // waiting on its result. Now chunks decode *during* the recording, so a cancelled
          // dictation used to leave the GPU finishing work whose transcript is already discarded.
          //
          // `Task.isCancelled` is read from the deadline's work task. That task is cancelled by
          // the timer and by the caller's cancellation, so a timed-out decode stops at its next
          // token instead of finishing on the GPU. WhisperKit invokes the callback synchronously
          // from inside the decoding loop. If that ever stops holding, this reads false and the
          // behaviour is exactly the pre-slice-4 one.
          return !Task.isCancelled
        }
      },
      mapFailure: { Self.whisperDecodeFailure($0, modelType: modelType) })
    let whisperKitTime = CFAbsoluteTimeGetCurrent() - whisperKitStartTime
    DebugLogger.logSpeech("SPEED: WhisperKit transcribe call took \(String(format: "%.3f", whisperKitTime))s (\(String(format: "%.0f", whisperKitTime * 1000))ms)")
    // Where the call's time went, from WhisperKit's own stopwatch. The total alone cannot
    // tell a slow encoder pass from a long token loop or a temperature fallback, and those
    // call for different fixes (compute placement, model, thresholds).
    let summary = Self.timingsSummary(of: results)
    lastDecodeTimingsSummary = summary
    DebugLogger.logSpeech("SPEED: LOCAL-SPEECH timings \(summary)")
    return results
  }
  
  /// One line per decode: how many 30 s windows ran, and the seconds spent in each stage.
  /// `encodeS` is the audio encoder (one pass per window, always a full 30 s frame regardless
  /// of how much of it is speech), `initS` the decoder init (prompt/SOT prefill), `loopS` the autoregressive
  /// token loop, `fallbacks` how many windows were re-decoded at a higher temperature.
  static func timingsSummary(of results: [TranscriptionResult]) -> String {
    func f(_ v: Double) -> String { String(format: "%.2f", v) }
    let t = results.map(\.timings)
    var windows = 0.0, encodeRuns = 0.0, loops = 0.0, fallbacks = 0.0
    var encoding = 0.0, prefill = 0.0, loop = 0.0, predictions = 0.0, fallbackTime = 0.0
    var audioLoad = 0.0, mels = 0.0, kv = 0.0, full = 0.0
    for timing in t {
      windows += timing.totalDecodingWindows
      encodeRuns += timing.totalEncodingRuns
      loops += timing.totalDecodingLoops
      fallbacks += timing.totalDecodingFallbacks
      encoding += timing.encoding
      prefill += timing.decodingInit
      loop += timing.decodingLoop
      predictions += timing.decodingPredictions
      fallbackTime += timing.decodingFallback
      audioLoad += timing.audioLoading + timing.audioProcessing
      mels += timing.logmels
      kv += timing.decodingKvCaching
      full += timing.fullPipeline
    }
    let firstToken = t.first.map { $0.firstTokenTime - $0.pipelineStart } ?? 0
    let tokensPerSecond = loop > 0 ? loops / loop : 0
    return "windows=\(Int(windows)) encodeRuns=\(Int(encodeRuns)) encodeS=\(f(encoding)) "
      + "initS=\(f(prefill)) loopS=\(f(loop)) predictS=\(f(predictions)) kvS=\(f(kv)) "
      + "loops=\(Int(loops)) tokPerS=\(f(tokensPerSecond)) fallbacks=\(Int(fallbacks)) "
      + "fallbackS=\(f(fallbackTime)) audioLoadS=\(f(audioLoad)) melS=\(f(mels)) "
      + "firstTokenS=\(f(firstToken)) fullS=\(f(full))"
  }

  private func isEmptyResult(_ results: [TranscriptionResult]) -> Bool {
    results.isEmpty || results.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  /// True when the clip contains at least one frame of voice activity. `nil` when the file cannot
  /// be read — the caller then decodes rather than dropping a real recording, the same fail-open
  /// rule `peakPowerDecibels` follows.
  ///
  /// WhisperKit's `EnergyVAD` is used as a **gate**, not a chunker: it answers "is there speech in
  /// this clip at all" and the clip is still decoded in one piece. `.vad` *chunking* is a different
  /// lever and stays rejected — see the `chunkingStrategy` doc comment on `transcribe`.
  ///
  /// Frames are 100 ms at the file's own rate, so no resampling is needed: `EnergyVAD` compares
  /// RMS energy against a threshold, which does not depend on the sample rate. The file is read
  /// incrementally frame by frame, and all channels are considered (loudest channel per frame).
  private func hasVoiceActivity(in audioURL: URL) -> Bool? {
    do {
      let file = try AVAudioFile(
        forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
      let format = file.processingFormat
      let sampleRate = format.sampleRate
      let channelCount = Int(format.channelCount)
      let frameLength = max(1, Int(sampleRate * 0.1))
      guard file.length > 0, channelCount > 0,
            let buffer = AVAudioPCMBuffer(
              pcmFormat: format, frameCapacity: AVAudioFrameCount(frameLength))
      else { return nil }

      // Streamed in 100 ms frames; per frame the loudest channel decides, so a clip with speech
      // on any channel counts. Same RMS-vs-threshold test as `EnergyVAD`.
      var activeFrames = 0
      var totalFrames = 0
      while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frameLength))
        let n = Int(buffer.frameLength)
        if n == 0 { break }
        guard let channels = buffer.floatChannelData else { return nil }
        var frameRMS: Float = 0
        for ch in 0..<channelCount {
          var sumSquares: Float = 0
          let samples = UnsafeBufferPointer(start: channels[ch], count: n)
          for sample in samples { sumSquares += sample * sample }
          frameRMS = max(frameRMS, (sumSquares / Float(n)).squareRoot())
        }
        totalFrames += 1
        if frameRMS > Self.vadEnergyThreshold { activeFrames += 1 }
      }
      guard totalFrames > 0 else { return nil }
      DebugLogger.log(
        "LOCAL-SPEECH: VAD gate — \(activeFrames)/\(totalFrames) active frame(s) in "
          + "\(String(format: "%.2f", Double(file.length) / sampleRate))s")
      return activeFrames > 0
    } catch {
      DebugLogger.logWarning(
        "LOCAL-SPEECH: Could not run the VAD gate (\(error.localizedDescription))")
      return nil
    }
  }

  /// Peak sample magnitude as dBFS. Same units `AVAudioRecorder.peakPower` reports, so the
  /// −45 dB threshold matches `AudioRecorder`. Returns nil when the file cannot be read —
  /// Whisper then runs rather than a failed meter silently dropping a real recording.
  private func peakPowerDecibels(of audioURL: URL) -> Float? {
    do {
      let file = try AVAudioFile(forReading: audioURL)
      let format = file.processingFormat
      let frameCount = AVAudioFrameCount(file.length)
      guard frameCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
      else { return nil }
      try file.read(into: buffer)
      var peak: Float = 0
      let frames = Int(buffer.frameLength)
      if let channels = buffer.floatChannelData {
        for ch in 0..<Int(format.channelCount) {
          let samples = UnsafeBufferPointer(start: channels[ch], count: frames)
          for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
          }
        }
      } else if let channels = buffer.int16ChannelData {
        for ch in 0..<Int(format.channelCount) {
          let samples = UnsafeBufferPointer(start: channels[ch], count: frames)
          for sample in samples {
            let magnitude = abs(Float(sample) / 32768)
            if magnitude > peak { peak = magnitude }
          }
        }
      } else {
        return nil
      }
      if peak <= 0 { return -160 }
      return 20 * log10(peak)
    } catch {
      DebugLogger.logWarning(
        "LOCAL-SPEECH: Could not measure peak power (\(error.localizedDescription))")
      return nil
    }
  }
  
  // MARK: - Loaded Model Queries
  /// Returns true if the given model type is currently loaded (so we use the selected model, not a previously pre-loaded one).
  func isLoaded(modelType: OfflineModelType) -> Bool {
    return currentModelType == modelType
  }

  // MARK: - Get Current Model Info
  func getCurrentModelInfo() -> String? {
    return currentModelType?.displayName
  }
}

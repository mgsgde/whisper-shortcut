//
//  LocalSpeechService.swift
//  WhisperShortcut
//
//  Offline speech-to-text using Whisper.cpp via SwiftWhisper
//

import Foundation
import AVFoundation
import CoreML
import Darwin
import WhisperKit

actor LocalSpeechService {
  static let shared = LocalSpeechService()
  
  private var whisperKit: WhisperKit?
  private var currentModelType: OfflineModelType?
  /// The last model that was loaded, kept across unloads so `transcribe` can put it back.
  /// `currentModelType` is cleared by `unloadModel`; this deliberately is not.
  private var lastLoadedModelType: OfflineModelType?
  private var memoryPressureSource: DispatchSourceMemoryPressure?
  private var idleUnloadTask: Task<Void, Never>?
  /// WhisperKit's own breakdown of the most recent decode, in the shape `timingsSummary` renders.
  /// Read by `OfflineWhisperBenchmarkTests` so a benchmark can attribute a slow call to the
  /// encoder, the prefill or the token loop instead of guessing from the total.
  private(set) var lastDecodeTimingsSummary: String?

  /// Same threshold `AudioRecorder` uses (−45 dB). Duplicated because that type is not shared
  /// with this actor; do not invent a second VAD.
  private static let silenceThresholdDB: Float = -45
  /// Matches typical Ollama `keep_alive` so Whisper Turbo is not held for the app's lifetime —
  /// but only for a model that is no longer selected, see `unloadIfNotSelected`.
  private static let idleUnloadAfter: TimeInterval = 5 * 60
  
  private init() {}
  
  // MARK: - Initialize Model
  func initializeModel(_ modelType: OfflineModelType) async throws {
    // Check if already initialized with the same model
    if let current = currentModelType, current == modelType, whisperKit != nil {
      DebugLogger.log("LOCAL-SPEECH: Model \(modelType.displayName) already loaded")
      scheduleIdleUnload()
      return
    }

    DebugLogger.log("LOCAL-SPEECH: Initializing WhisperKit model: \(modelType.displayName)")
    
    // Unload previous model if exists
    if whisperKit != nil {
      unloadModel()
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
    // `prefillCompute` exists only on WhisperKit main after 1.1.0; the 1.1.0 pin we
    // ship against has no such knob — prefill follows `textDecoderCompute`.
    let config = WhisperKitConfig(
      modelFolder: modelPath.path,
      computeOptions: ModelComputeOptions(
        melCompute: .cpuAndGPU,
        audioEncoderCompute: encoderCompute,
        textDecoderCompute: encoderCompute)
    )
    DebugLogger.log(
      "LOCAL-SPEECH: Compute units — encoder/decoder: \(modelType.usesNeuralEngine ? "CPU+ANE" : "CPU+GPU")")
    let loadStart = CFAbsoluteTimeGetCurrent()
    
    do {
      whisperKit = try await WhisperKit(config)
      currentModelType = modelType
      lastLoadedModelType = modelType
      startLifetimeGuardsIfNeeded()
      scheduleIdleUnload()
      let elapsed = CFAbsoluteTimeGetCurrent() - loadStart
      DebugLogger.logSuccess(
        "LOCAL-SPEECH: Model initialized successfully in \(String(format: "%.1f", elapsed))s")
      // Machine-readable twin of the line above, greppable next to the transcription numbers.
      // On a cold model this load is the single biggest item in front of the transcript, and the
      // only question that matters is whether it lands inside the recording window
      // (`ConnectionPrewarmer.warmOfflineWhisper`) or after Stop, where the user waits on it.
      DebugLogger.logSpeech(
        "SPEED: LOCAL-SPEECH load model=\(modelType.rawValue) "
          + "loadMs=\(String(format: "%.0f", elapsed * 1000))")
    } catch {
      // Check if error is related to missing or incomplete model files
      let errorMessage = error.localizedDescription
      DebugLogger.logError("LOCAL-SPEECH: WhisperKit initialization failed: \(errorMessage)")
      
      // Check for common model-related errors
      let lowercasedError = errorMessage.lowercased()
      if lowercasedError.contains("mil network") ||
         lowercasedError.contains("mlmodelc") ||
         lowercasedError.contains("model") && (lowercasedError.contains("not found") || lowercasedError.contains("missing") || lowercasedError.contains("read")) {
        // This is a model availability issue
        DebugLogger.logError("LOCAL-SPEECH: Model appears to be missing or incomplete")
        throw TranscriptionError.modelNotAvailable(modelType)
      }
      
      // For other errors, wrap in fileError with more context
      throw TranscriptionError.fileError("Failed to load model: \(errorMessage). The model may be incomplete or corrupted. Please try downloading it again in Settings.")
    }
  }
  
  // MARK: - Unload Model
  func unloadModel() {
    unloadModel(reason: "explicit")
  }

  private func unloadModel(reason: String) {
    guard whisperKit != nil || currentModelType != nil else { return }
    DebugLogger.log("LOCAL-SPEECH: Unloading model (\(reason))")
    whisperKit = nil
    currentModelType = nil
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
  }

  private func startLifetimeGuardsIfNeeded() {
    guard memoryPressureSource == nil else { return }
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: .global(qos: .utility))
    source.setEventHandler {
      Task { await LocalSpeechService.shared.unloadModel(reason: "memory pressure") }
    }
    source.resume()
    memoryPressureSource = source
  }

  private func scheduleIdleUnload() {
    idleUnloadTask?.cancel()
    idleUnloadTask = Task {
      try? await Task.sleep(for: .seconds(Self.idleUnloadAfter))
      guard !Task.isCancelled else { return }
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
  func transcribe(
    audioURL: URL, language: String? = nil, prompt: String? = nil,
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
    if whisperKit == nil, let reloadType = lastLoadedModelType {
      DebugLogger.logWarning(
        "LOCAL-SPEECH: Model was unloaded since the caller checked — reloading \(reloadType.displayName)")
      try await initializeModel(reloadType)
    }

    guard let whisperKit = whisperKit, currentModelType != nil else {
      throw TranscriptionError.fileError("WhisperKit not initialized")
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
      throw TranscriptionError.fileError("Audio file not found")
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
      let audioFile = try AVAudioFile(forReading: audioURL)
      let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
      audioDuration = duration
      DebugLogger.log("LOCAL-SPEECH: Audio duration: \(String(format: "%.2f", duration))s")
    } catch {
      DebugLogger.log("LOCAL-SPEECH: Could not determine audio duration")
    }
    
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
      whisperKit: whisperKit, audioURL: audioURL, decodeOptions: decodeOptions
    )
    
    // Fallback: if prompt was used and result is empty, retry without prompt (WhisperKit #372)
    if usedPrompt && isEmptyResult(transcriptionResults) {
      DebugLogger.logWarning("LOCAL-SPEECH: Prompt caused empty result; retrying without prompt")
      let fallbackOptions = buildDecodingOptions(
        language: language, promptTokens: nil, chunkingStrategy: chunkingStrategy)
      transcriptionResults = try await performWhisperTranscription(
        whisperKit: whisperKit, audioURL: audioURL, decodeOptions: fallbackOptions
      )
    }
    
    // Spans the retry too: a prompt that produces an empty result costs a second full decode,
    // and hiding that would flatter the realtime factor.
    let decodeElapsed = CFAbsoluteTimeGetCurrent() - decodeStart

    // Combine all segments into a single text
    guard !transcriptionResults.isEmpty else {
      throw TranscriptionError.fileError("No transcription result")
    }
    
    // Extract text from all segments
    let text = transcriptionResults.map { $0.text }.joined(separator: " ")
    
    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(text)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "LOCAL-SPEECH")
    
    let totalElapsedTime = CFAbsoluteTimeGetCurrent() - transcribeStartTime
    DebugLogger.logSuccess("LOCAL-SPEECH: Transcription completed")
    DebugLogger.logSpeech("SPEED: Whisper transcription total time: \(String(format: "%.3f", totalElapsedTime))s (\(String(format: "%.0f", totalElapsedTime * 1000))ms)")
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
    let previewLen = 80
    let preview = promptText.count <= previewLen
      ? promptText
      : String(promptText.prefix(previewLen)).trimmingCharacters(in: .whitespaces) + "..."
    DebugLogger.log("LOCAL-SPEECH: Whisper glossary sent as conditioning prompt (\(truncated.count) tokens). Preview: \"\(preview)\"")
    
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
    if let language = language {
      return DecodingOptions(
        language: language,
        temperatureFallbackCount: Self.temperatureFallbackCount,
        skipSpecialTokens: true,
        promptTokens: promptTokens,
        chunkingStrategy: chunkingStrategy
      )
    } else {
      return DecodingOptions(
        language: nil,
        temperatureFallbackCount: Self.temperatureFallbackCount,
        detectLanguage: true,
        skipSpecialTokens: true,
        promptTokens: promptTokens,
        chunkingStrategy: chunkingStrategy
      )
    }
  }
  
  // MARK: - WhisperKit Transcription Call
  
  private func performWhisperTranscription(
    whisperKit: WhisperKit,
    audioURL: URL,
    decodeOptions: DecodingOptions
  ) async throws -> [TranscriptionResult] {
    let whisperKitStartTime = CFAbsoluteTimeGetCurrent()
    do {
      let results = try await whisperKit.transcribe(
        audioPath: audioURL.path,
        decodeOptions: decodeOptions
      ) { _ in
        // Returning false stops the decode at the next token. Before slice 4 this always
        // returned true, which was harmless: the only decode ran after Stop, with the user
        // waiting on its result. Now chunks decode *during* the recording, so a cancelled
        // dictation used to leave the GPU finishing work whose transcript is already discarded.
        //
        // `Task.isCancelled` is read from the task that awaits this call, since WhisperKit
        // invokes the callback synchronously from inside the decoding loop. If that ever stops
        // holding, this reads false and the behaviour is exactly the pre-slice-4 one.
        return !Task.isCancelled
      }
      let whisperKitTime = CFAbsoluteTimeGetCurrent() - whisperKitStartTime
      DebugLogger.logSpeech("SPEED: WhisperKit transcribe call took \(String(format: "%.3f", whisperKitTime))s (\(String(format: "%.0f", whisperKitTime * 1000))ms)")
      // Where the call's time went, from WhisperKit's own stopwatch. The total alone cannot
      // tell a slow encoder pass from a long token loop or a temperature fallback, and those
      // call for different fixes (compute placement, model, thresholds).
      let summary = Self.timingsSummary(of: results)
      lastDecodeTimingsSummary = summary
      DebugLogger.logSpeech("SPEED: LOCAL-SPEECH timings \(summary)")
      return results
    } catch {
      let errorMessage = error.localizedDescription
      DebugLogger.logError("LOCAL-SPEECH: Transcription failed: \(errorMessage)")
      
      let lowercasedError = errorMessage.lowercased()
      if lowercasedError.contains("mil network") ||
         lowercasedError.contains("mlmodelc") ||
         lowercasedError.contains("model") && (lowercasedError.contains("not found") || lowercasedError.contains("missing") || lowercasedError.contains("read") || lowercasedError.contains("load")) {
        DebugLogger.logError("LOCAL-SPEECH: Model appears to be missing or incomplete during transcription")
        if let modelType = currentModelType {
          throw TranscriptionError.modelNotAvailable(modelType)
        } else {
          throw TranscriptionError.fileError("Model is missing or incomplete. Please download it in Settings.")
        }
      }
      
      throw TranscriptionError.fileError("Transcription failed: \(errorMessage). The model may be incomplete or corrupted. Please try downloading it again in Settings.")
    }
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
  
  // MARK: - Check if Model is Ready
  func isReady() -> Bool {
    return currentModelType != nil && whisperKit != nil
  }

  /// Returns true if the given model type is currently loaded (so we use the selected model, not a previously pre-loaded one).
  func isLoaded(modelType: OfflineModelType) -> Bool {
    return currentModelType == modelType
  }

  // MARK: - Get Current Model Info
  func getCurrentModelInfo() -> String? {
    return currentModelType?.displayName
  }
}

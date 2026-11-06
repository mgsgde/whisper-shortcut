//
//  Qwen3TTSService.swift
//  WhisperShortcut
//
//  On-device Read Aloud through Qwen3-TTS VoiceDesign (MLX, `mlx-audio-swift`).
//
//  One checkpoint: VoiceDesign 1.7B. The voice *is* a natural-language description, so it can be
//  told "native German speaker, no foreign accent" — which is the whole point of a local voice
//  here. The 0.6B CustomVoice checkpoint was dropped: its nine fixed speakers are Chinese,
//  English, Japanese and Korean natives, so German came out as a non-native speaker reading
//  German.
//
//  Output contract: s16le, 24 kHz, mono — the same raw PCM every other Read Aloud provider
//  returns, so `MenuBarController`'s playback path needs no change.
//
//  Long text is synthesized in sentence-boundary chunks, one after another, against the *same*
//  loaded model. That is the difference between a 3000-character article taking one very long
//  generation and taking several short ones: the model's own generation cost grows faster than
//  linearly with the audio length, and a single long request also holds the whole waveform in
//  memory before anything can be played. Chunks are sequential, not parallel — one model instance
//  cannot run two generations at once, and the weights must not be loaded twice.
//

import AVFoundation
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS

/// Errors a Qwen3 synthesis can fail with, phrased for the Read Aloud popup.
enum Qwen3TTSError: LocalizedError {
  case unsupportedMac
  case modelNotDownloaded
  case emptyAudio

  var errorDescription: String? {
    switch self {
    case .unsupportedMac:
      return String(localized: "On-device Qwen3 voices need a Mac with Apple silicon.")
    case .modelNotDownloaded:
      return String(localized: "The Qwen3 voice model is not downloaded yet. Download it in Settings → Read Aloud.")
    case .emptyAudio:
      return String(localized: "The Qwen3 voice model returned no audio.")
    }
  }
}

/// Owns the loaded Qwen3-TTS model. One model is resident at a time, mirroring `MLXModelLoader`
/// for the chat models: loading is expensive (2.9 GB of weights) and a menu-bar app must not hold
/// it forever. There is only one TTS checkpoint, so no type slot is needed.
actor Qwen3TTSModelLoader {
  static let shared = Qwen3TTSModelLoader()

  private var loaded: SpeechGenerationModel?
  private var inFlight: Task<SpeechGenerationModel, Error>?
  private let lifetime = ModelLifetimeGuards()

  /// 2.9 GB of weights must not stay resident in a menu-bar app that reads aloud a few times a
  /// day. Same window as `MLXModelLoader`: long enough that a second Read Aloud in the same
  /// session reuses the model, short enough that an idle app gives the memory back.
  private static let idleUnloadAfter: TimeInterval = 5 * 60

  /// Loads (or returns) the VoiceDesign model. The cached instance is reused for every chunk of a
  /// long text — that is the point of caching it here rather than in the caller.
  func model() async throws -> SpeechGenerationModel {
    if let loaded {
      scheduleIdleUnload()
      return loaded
    }
    if let inFlight { return try await inFlight.value }

    let task = Task<SpeechGenerationModel, Error> {
      // Load from the app's own model folder, not the shared HuggingFace cache: the app's
      // download path writes there, and `TTS.loadModel` resolves a local directory before it
      // ever touches the network.
      let type = Qwen3ModelType.voiceDesign
      guard let local = Qwen3ModelManager.shared.resolveModelPath(for: type) else {
        throw Qwen3TTSError.modelNotDownloaded
      }
      DebugLogger.log("QWEN3-TTS: loading \(type.rawValue) from \(local.path)")
      let start = Date()
      let model = try await TTS.loadModel(modelRepo: local.path)
      DebugLogger.log(
        "QWEN3-TTS: loaded \(type.rawValue) in "
          + "\(String(format: "%.1f", Date().timeIntervalSince(start)))s, "
          + "sampleRate=\(model.sampleRate)")
      return model
    }
    inFlight = task
    defer { inFlight = nil }
    let model = try await task.value
    loaded = model
    startLifetimeGuardsIfNeeded()
    scheduleIdleUnload()
    return model
  }

  func unload() {
    loaded = nil
    lifetime.cancelIdleUnload()
  }

  /// A 2.9 GB model next to Parakeet and the system is exactly the situation memory pressure is
  /// for; dropping the weights is always safe, the next Read Aloud reloads them.
  private func startLifetimeGuardsIfNeeded() {
    lifetime.installMemoryPressureHandler {
      Task { await self.unloadLoaded(reason: "memory pressure") }
    }
  }

  private func scheduleIdleUnload() {
    lifetime.scheduleIdleUnload(after: Self.idleUnloadAfter) {
      await self.unloadLoaded(reason: "idle")
    }
  }

  private func unloadLoaded(reason: String) {
    guard loaded != nil else { return }
    DebugLogger.log("QWEN3-TTS: unloading VoiceDesign (\(reason))")
    loaded = nil
    lifetime.cancelIdleUnload()
  }
}

/// Synthesizes Read Aloud audio with Qwen3-TTS.
struct Qwen3TTSService {
  static let shared = Qwen3TTSService()

  /// The rate every Read Aloud provider emits, and what the playback path expects.
  private static let outputSampleRate: Double = 24_000

  /// Hard cap for a single sentence. A sentence longer than this is cut at a word boundary, so
  /// one run-on sentence cannot turn into a multi-minute generation.
  private static let maxSentenceChars = 400

  /// Synthesizes `text` with `persona` to s16le 24 kHz mono PCM.
  ///
  /// `onChunkReady` receives each chunk's PCM as soon as it is done, in playback order, so
  /// playback can start while the rest is still being generated.
  ///
  /// **One generation per sentence.** Not per paragraph: a sentence is the unit the model's
  /// prosody is trained on, the first audio arrives after one sentence instead of after a whole
  /// paragraph, and a failure costs one sentence.
  ///
  /// **Voice consistency.** VoiceDesign has no speaker id: the voice is sampled from the
  /// description on every call, so two calls with the same description produce two different
  /// speakers. The fix is the library's ICL path — a reference clip (audio + transcript) is fed
  /// back as `refAudio`/`refText` for every sentence, which pins the speaker. Measured on a
  /// four-sentence German text: no reference gave F0 spread 20.7 Hz and mean MFCC similarity
  /// 0.8764; with a reference 15.4 Hz and 0.9484.
  ///
  /// **The reference is frozen per persona, not per text** (`Qwen3VoiceReferenceStore`). The
  /// first Read Aloud with a persona synthesizes a short calibration sentence, stores it, and
  /// from then on every Read Aloud — in any session — starts from that same clip, so a persona
  /// is the same voice forever. "Reset voice" in Settings deletes the clip; the next Read Aloud
  /// generates and stores a new one.
  func synthesizePCM(
    text: String,
    persona: Qwen3VoicePersona,
    onChunkReady: ((Data, Int, Int) -> Void)? = nil
  ) async throws -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return Data() }

    // Loaded once, before the loop: every sentence below reuses this instance.
    let model = try await Qwen3TTSModelLoader.shared.model()
    let sentences = Self.splitIntoSentences(trimmed, maxChars: Self.maxSentenceChars)
    DebugLogger.log(
      "QWEN3-TTS: \(persona.id), \(trimmed.count) chars in \(sentences.count) sentence(s)")

    var merged = Data()
    // The speaker reference for every sentence: the persona's frozen clip when one exists,
    // otherwise nil until the first sentence has defined the voice.
    var referenceAudio: MLXArray?
    var referenceText: String?

    if let cached = Qwen3VoiceReferenceStore.reference(for: persona.id),
      cached.sampleRate == model.sampleRate
    {
      referenceAudio = MLXArray(cached.samples)
      referenceText = cached.text
      DebugLogger.log(
        "QWEN3-TTS: using frozen voice reference for \(persona.id) "
          + "(\(cached.samples.count) samples)")
    } else if Qwen3VoiceReferenceStore.hasReference(for: persona.id) {
      // A reference exists but does not fit the loaded checkpoint (sample-rate mismatch from a
      // future model update). Treat it as absent: the calibration below writes a fresh one.
      DebugLogger.log("QWEN3-TTS: frozen voice reference for \(persona.id) does not match the model; recalibrating")
    }

    // The library default (temperature 0.9) re-samples the voice on every call. Measured on a
    // four-sentence German text: default 0.9 + reference gave F0 spread 31.0 Hz and mean
    // MFCC similarity 0.8885; temperature 0.3 + reference gives 15.4 Hz and 0.9484. Lower
    // (0.1) is worse again (21.3 Hz / 0.8811) — 0.3 is the sweet spot.
    let parameters = GenerateParameters(
      maxTokens: 4096,
      temperature: 0.3,
      topP: 1.0,
      repetitionPenalty: 1.05
    )

    // When the persona has no frozen clip yet, the first generation of this Read Aloud is the
    // calibration: a fixed short sentence, spoken once, stored, and used as the reference for
    // every sentence of every future Read Aloud with this persona. It is *not* part of the
    // playback audio. An empty calibration degrades to per-run pinning (the first sentence
    // defines the voice) instead of failing the whole Read Aloud — the user asked to hear text,
    // not to calibrate.
    let needsCalibration = referenceAudio == nil
    if needsCalibration {
      let calibration = Self.calibrationText(for: persona.language)
      DebugLogger.log("QWEN3-TTS: calibrating voice for \(persona.id)")
      let clip = try await model.generate(
        text: calibration,
        voice: persona.prompt,
        refAudio: nil,
        refText: nil,
        language: persona.language,
        generationParameters: parameters
      )
      let clipSamples = clip.asArray(Float.self)
      if clipSamples.isEmpty {
        DebugLogger.log("QWEN3-TTS: calibration returned no audio; falling back to per-run pinning")
      } else {
        Qwen3VoiceReferenceStore.store(
          samples: clipSamples, sampleRate: model.sampleRate, text: calibration, for: persona.id)
        referenceAudio = clip
        referenceText = calibration
      }
    }

    for (index, sentence) in sentences.enumerated() {
      try Task.checkCancellation()
      let start = Date()
      let audio = try await model.generate(
        text: sentence,
        voice: persona.prompt,
        refAudio: referenceAudio,
        refText: referenceText,
        language: persona.language,
        generationParameters: parameters
      )
      let samples = audio.asArray(Float.self)
      guard !samples.isEmpty else { throw Qwen3TTSError.emptyAudio }

      // Without a frozen clip the first sentence is still the one that defines the voice (the
      // calibration above failed to store, e.g. disk full). Later sentences must never
      // overwrite the reference, or the voice would drift sentence by sentence.
      let referenceWasNil = referenceAudio == nil
      if referenceWasNil {
        referenceAudio = audio
        referenceText = sentence
      }

      let pcm = Self.pcm16(from: samples, sourceRate: Double(model.sampleRate))
      merged.append(pcm)
      let seconds = Double(samples.count) / Double(model.sampleRate)
      let elapsed = Date().timeIntervalSince(start)
      let role = referenceWasNil ? "defines the voice" : "reference-pinned"
      DebugLogger.log(
        "QWEN3-TTS: sentence \(index + 1)/\(sentences.count) \(samples.count) samples "
          + "(\(String(format: "%.2f", seconds))s) "
          + "in \(String(format: "%.1f", elapsed))s (\(role))")
      if let onChunkReady {
        await MainActor.run { onChunkReady(pcm, index, sentences.count) }
      }
    }

    DebugLogger.log("QWEN3-TTS: \(persona.id) total \(merged.count) bytes")
    return merged
  }

  /// The calibration sentence for a persona's frozen voice reference. Delegates to the store so
  /// the text and its on-disk consumer live in one place.
  static func calibrationText(for language: String) -> String {
    Qwen3VoiceReferenceStore.calibrationText(for: language)
  }

  /// Splits `text` into one entry per sentence, cutting any sentence longer than `maxChars` at a
  /// word boundary. Never returns an empty entry, and never returns an entry over the cap.
  ///
  /// A terminator only ends a sentence when whitespace follows it, so "3.5" stays in one piece.
  /// That rule does *not* protect spaced abbreviations ("z. B. das ist…" splits after "z."),
  /// and none are special-cased: a false split costs a slightly odd pause, a missed split costs
  /// a long generation.
  static func splitIntoSentences(_ text: String, maxChars: Int) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var sentences: [String] = []
    var current = ""
    var index = trimmed.startIndex
    while index < trimmed.endIndex {
      let character = trimmed[index]
      current.append(character)
      let next = trimmed.index(after: index)
      let followedBySpace = next == trimmed.endIndex || trimmed[next].isWhitespace
      if ".!?…".contains(character), followedBySpace {
        sentences.append(current)
        current = ""
      }
      index = next
    }
    if !current.isEmpty { sentences.append(current) }

    return sentences
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .flatMap { $0.count > maxChars ? splitLongSentence($0, maxChars: maxChars) : [$0] }
  }

  /// A single sentence longer than the cap: cut at the last space before the limit.
  private static func splitLongSentence(_ sentence: String, maxChars: Int) -> [String] {
    var chunks: [String] = []
    var rest = Substring(sentence.trimmingCharacters(in: .whitespacesAndNewlines))
    while rest.count > maxChars {
      let window = rest.prefix(maxChars)
      // No space at all in the window (one enormous "word"): hard-cut at the cap so the loop
      // always makes progress.
      let cut = window.lastIndex(of: " ") ?? window.endIndex
      let piece = rest[rest.startIndex..<cut]
      if !piece.isEmpty { chunks.append(String(piece)) }
      rest = rest[cut...].drop { $0 == " " }
    }
    if !rest.isEmpty { chunks.append(String(rest)) }
    return chunks
  }

  /// Float samples → s16le at `outputSampleRate`, mono. Linear resampling is enough here: the
  /// model emits 24 kHz already for the 12 Hz checkpoints, so this is a no-op in practice and a
  /// safety net for a checkpoint that does not.
  private static func pcm16(from samples: [Float], sourceRate: Double) -> Data {
    let resampled: [Float]
    if abs(sourceRate - outputSampleRate) < 1 {
      resampled = samples
    } else {
      let ratio = outputSampleRate / sourceRate
      let count = Int(Double(samples.count) * ratio)
      resampled = (0..<count).map { index in
        let position = Double(index) / ratio
        let lower = Int(position)
        let upper = min(lower + 1, samples.count - 1)
        let fraction = Float(position - Double(lower))
        return samples[lower] * (1 - fraction) + samples[upper] * fraction
      }
    }

    var data = Data(capacity: resampled.count * 2)
    for sample in resampled {
      let clamped = max(-1, min(1, sample))
      var value = Int16(clamped * 32_767)
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    return data
  }
}

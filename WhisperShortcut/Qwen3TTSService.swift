//
//  Qwen3TTSService.swift
//  WhisperShortcut
//
//  On-device Read Aloud through Qwen3-TTS (MLX, `mlx-audio-swift`).
//
//  Two checkpoints, two trade-offs:
//
//  - VoiceDesign 1.7B — the voice *is* a natural-language description. This is the default,
//    because CustomVoice's nine speakers are all Chinese, English, Japanese or Korean natives and
//    asking one of them to read German produces an audibly translated voice. VoiceDesign can be
//    told "native German speaker, no foreign accent", which is the whole point.
//  - CustomVoice 0.6B — nine fixed speakers, a third of the download and several times faster.
//    Offered as the fast local option; German comes out as a non-native speaker reading German.
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
  /// A reference clip was imported without a transcript, and the on-device ASR checkpoint that
  /// could produce one is not downloaded.
  case transcriptRequired

  var errorDescription: String? {
    switch self {
    case .unsupportedMac:
      return String(localized: "On-device Qwen3 voices need a Mac with Apple silicon.")
    case .modelNotDownloaded:
      return String(localized: "The Qwen3 voice model is not downloaded yet. Download it in Settings → Read Aloud.")
    case .emptyAudio:
      return String(localized: "The Qwen3 voice model returned no audio.")
    case .transcriptRequired:
      return String(
        localized:
          "Type what the recording says, or download the Qwen3 ASR model in Settings → Dictate so the text can be transcribed on this Mac."
      )
    }
  }
}

/// Owns the loaded Qwen3-TTS model. One model is resident at a time, mirroring `MLXModelLoader`
/// for the chat models: loading is expensive (up to 2.9 GB of weights) and a menu-bar app must
/// not hold both checkpoints forever. Switching between VoiceDesign and CustomVoice unloads the
/// other one.
actor Qwen3TTSModelLoader {
  static let shared = Qwen3TTSModelLoader()

  private var loadedType: Qwen3ModelType?
  private var loaded: SpeechGenerationModel?
  private var inFlightType: Qwen3ModelType?
  private var inFlight: Task<SpeechGenerationModel, Error>?
  private let lifetime = ModelLifetimeGuards()

  /// 2.9 GB of weights must not stay resident in a menu-bar app that reads aloud a few times a
  /// day. Same window as `MLXModelLoader`: long enough that a second Read Aloud in the same
  /// session reuses the model, short enough that an idle app gives the memory back.
  private static let idleUnloadAfter: TimeInterval = 5 * 60

  /// Loads (or returns) the model for `type`. The cached instance is reused for every chunk of a
  /// long text — that is the point of caching it here rather than in the caller.
  ///
  /// A concurrent request for a *different* checkpoint must not join the in-flight load: it
  /// would receive the other checkpoint's model and synthesize with a voice string that makes
  /// no sense for it (a CustomVoice `"speaker, instruction"` read as a VoiceDesign description).
  /// So the join only happens when the types match; otherwise the joiner waits for the running
  /// load to finish (the actor serializes state, the model load itself runs off-actor) and then
  /// starts its own.
  func model(_ type: Qwen3ModelType) async throws -> SpeechGenerationModel {
    if let loaded, loadedType == type {
      scheduleIdleUnload()
      return loaded
    }
    if let inFlight, inFlightType == type { return try await inFlight.value }
    if let inFlight {
      // A different checkpoint is loading. Wait it out so the two loads do not race the
      // `loaded` slot, then load ours.
      _ = try? await inFlight.value
    }

    let task = Task<SpeechGenerationModel, Error> {
      // Load from the app's own model folder, not the shared HuggingFace cache: the app's
      // download path writes there, and `TTS.loadModel` resolves a local directory before it
      // ever touches the network.
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
    inFlightType = type
    // Ownership-checked teardown: a concurrent joiner for another checkpoint may have
    // registered its own task by the time ours finishes (resumption order of two waiters on
    // one Task is unspecified). Clearing unconditionally would wipe that registration and
    // let a third caller start a duplicate load of the same checkpoint. `Task` is a struct,
    // so identity is tracked via the type slot the registration itself wrote.
    defer {
      if inFlightType == type {
        inFlight = nil
        inFlightType = nil
      }
    }
    let model = try await task.value
    loaded = model
    loadedType = type
    startLifetimeGuardsIfNeeded()
    scheduleIdleUnload()
    return model
  }

  func unload() {
    loaded = nil
    loadedType = nil
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
    DebugLogger.log("QWEN3-TTS: unloading \(loadedType?.rawValue ?? "model") (\(reason))")
    loaded = nil
    loadedType = nil
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
  /// generates and stores a new one. CustomVoice personas skip all of this: their speaker is a
  /// fixed id, the checkpoint does not drift.
  func synthesizePCM(
    text: String,
    persona: Qwen3VoicePersona,
    modelType: Qwen3ModelType,
    onChunkReady: ((Data, Int, Int) -> Void)? = nil
  ) async throws -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return Data() }

    // Loaded once, before the loop: every sentence below reuses this instance.
    let model = try await Qwen3TTSModelLoader.shared.model(modelType)
    let sentences = Self.splitIntoSentences(trimmed, maxChars: Self.maxSentenceChars)
    DebugLogger.log(
      "QWEN3-TTS: \(persona.id) via \(modelType.rawValue), \(trimmed.count) chars in "
        + "\(sentences.count) sentence(s)")

    var merged = Data()
    // The speaker reference for every sentence: the persona's frozen clip when one exists,
    // otherwise nil until the first sentence has defined the voice.
    var referenceAudio: MLXArray?
    var referenceText: String?

    if modelType == .voiceDesign {
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
        // future model update). Treat it as absent: the calibration below writes a fresh one —
        // unless the user supplied the clip, which is never silently replaced.
        DebugLogger.log("QWEN3-TTS: frozen voice reference for \(persona.id) does not match the model; recalibrating")
      }
    }

    // The library default (temperature 0.9) re-samples the voice on every call; see
    // `generationParameters` for the measurements behind 0.3.
    let parameters = Self.generationParameters

    // When the persona has no frozen clip yet, the first generation of this Read Aloud is the
    // calibration: a fixed short sentence, spoken once, stored, and used as the reference for
    // every sentence of every future Read Aloud with this persona. It is *not* part of the
    // playback audio. An empty calibration degrades to per-run pinning (the first sentence
    // defines the voice) instead of failing the whole Read Aloud — the user asked to hear text,
    // not to calibrate.
    //
    // A clip the user imported is never overwritten here: it is the voice they chose, and a
    // calibration run would silently replace it with a described one.
    let needsCalibration =
      modelType == .voiceDesign && referenceAudio == nil
      && !Qwen3VoiceReferenceStore.isUserProvided(for: persona.id)
    if needsCalibration {
      let calibration = Self.calibrationText(for: persona.language)
      DebugLogger.log("QWEN3-TTS: calibrating voice for \(persona.id)")
      let clip = try await model.generate(
        text: calibration,
        voice: Self.voiceArgument(for: persona, modelType: modelType),
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
        voice: Self.voiceArgument(for: persona, modelType: modelType),
        refAudio: referenceAudio,
        refText: referenceText,
        language: persona.language,
        generationParameters: parameters
      )
      let samples = audio.asArray(Float.self)
      guard !samples.isEmpty else { throw Qwen3TTSError.emptyAudio }

      // The checkpoint pads chunks it cannot speak (a URL without a scheme, a byline, "7–8
      // minutes") with seconds of near-silence at the front — measured 15 s of lead-in on a
      // text whose first chunk held a news-site header. Trim that padding before it reaches
      // playback, or the user waits through silence and hears the text start mid-way.
      let trimmedSamples = Self.trimmingSilence(samples, sampleRate: model.sampleRate)
      // A sentence that is entirely silence (a bare domain the model cannot vocalize at all)
      // must not enqueue an empty chunk: playback would schedule zero bytes and stall.
      guard !trimmedSamples.isEmpty else {
        DebugLogger.log(
          "QWEN3-TTS: sentence \(index + 1)/\(sentences.count) was silent after trimming; skipping")
        continue
      }
      // Without a frozen clip the first sentence is still the one that defines the voice (the
      // calibration above failed to store, e.g. disk full). Later sentences must never
      // overwrite the reference, or the voice would drift sentence by sentence. A silent
      // sentence was skipped above, so it never becomes the reference.
      let referenceWasNil = referenceAudio == nil
      if referenceWasNil {
        referenceAudio = audio
        referenceText = sentence
      }
      let pcm = Self.pcm16(from: trimmedSamples, sourceRate: Double(model.sampleRate))
      merged.append(pcm)
      let seconds = Double(trimmedSamples.count) / Double(model.sampleRate)
      let elapsed = Date().timeIntervalSince(start)
      let role = referenceWasNil ? "defines the voice" : "reference-pinned"
      DebugLogger.log(
        "QWEN3-TTS: sentence \(index + 1)/\(sentences.count) \(trimmedSamples.count) samples "
          + "(\(String(format: "%.2f", seconds))s) "
          + "in \(String(format: "%.1f", elapsed))s (\(role))"
          + (trimmedSamples.count != samples.count
            ? " (trimmed \(samples.count - trimmedSamples.count) silent samples)" : ""))
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

  // MARK: - Settings: create and audition a voice

  /// What the Settings preview reads. Short enough to judge a voice in a few seconds, long enough
  /// to hear prosody rather than one word, and free of anything that biases the speaker (no
  /// numbers, no foreign words). The transcript is never stored — only the calibration clip is.
  static func previewText(for language: String) -> String {
    switch language {
    case "English":
      return "This is how this voice sounds when it reads a longer passage aloud to you."
    default:
      return "So klingt diese Stimme, wenn sie dir einen längeren Absatz vorliest."
    }
  }

  /// Creates (or re-creates) a persona's frozen voice without starting a Read Aloud, and returns
  /// the calibration clip as playback-ready PCM so Settings can play it immediately.
  ///
  /// This is the same generation `synthesizePCM` performs on the first Read Aloud — same sentence,
  /// same parameters, same store — so a voice created here is exactly the voice the next Read
  /// Aloud uses. CustomVoice has no freezable voice: its speaker is a fixed id, so there is
  /// nothing to create and the call returns the preview of that speaker instead.
  func createVoiceReference(
    for persona: Qwen3VoicePersona, modelType: Qwen3ModelType
  ) async throws -> Data {
    guard modelType == .voiceDesign else {
      return try await previewPCM(for: persona, modelType: modelType)
    }
    let model = try await Qwen3TTSModelLoader.shared.model(modelType)
    let calibration = Self.calibrationText(for: persona.language)
    DebugLogger.log("QWEN3-TTS: creating voice for \(persona.id) from Settings")
    let clip = try await model.generate(
      text: calibration,
      voice: Self.voiceArgument(for: persona, modelType: modelType),
      refAudio: nil,
      refText: nil,
      language: persona.language,
      generationParameters: Self.generationParameters
    )
    let samples = clip.asArray(Float.self)
    guard !samples.isEmpty else { throw Qwen3TTSError.emptyAudio }
    Qwen3VoiceReferenceStore.store(
      samples: samples, sampleRate: model.sampleRate, text: calibration, for: persona.id)
    return Self.pcm16(from: samples, sourceRate: Double(model.sampleRate))
  }

  /// Synthesizes a short sample with the persona's current voice — the frozen clip when one
  /// exists, otherwise a freshly created one — so Settings can play it before the user commits to
  /// a Read Aloud. Returns playback-ready PCM.
  func previewPCM(
    for persona: Qwen3VoicePersona, modelType: Qwen3ModelType
  ) async throws -> Data {
    let model = try await Qwen3TTSModelLoader.shared.model(modelType)
    let text = Self.previewText(for: persona.language)

    var referenceAudio: MLXArray?
    var referenceText: String?
    if modelType == .voiceDesign {
      if let cached = Qwen3VoiceReferenceStore.reference(for: persona.id),
        cached.sampleRate == model.sampleRate
      {
        referenceAudio = MLXArray(cached.samples)
        referenceText = cached.text
      } else {
        // No usable clip yet: create one first, so the preview is the voice the user will get and
        // not a one-off sample that the next Read Aloud would replace.
        _ = try await createVoiceReference(for: persona, modelType: modelType)
        if let cached = Qwen3VoiceReferenceStore.reference(for: persona.id),
          cached.sampleRate == model.sampleRate
        {
          referenceAudio = MLXArray(cached.samples)
          referenceText = cached.text
        }
      }
    }

    let audio = try await model.generate(
      text: text,
      voice: Self.voiceArgument(for: persona, modelType: modelType),
      refAudio: referenceAudio,
      refText: referenceText,
      language: persona.language,
      generationParameters: Self.generationParameters
    )
    let samples = audio.asArray(Float.self)
    guard !samples.isEmpty else { throw Qwen3TTSError.emptyAudio }
    return Self.pcm16(from: samples, sourceRate: Double(model.sampleRate))
  }

  /// Imports a user-supplied audio file as a persona's voice reference, so the persona speaks in
  /// that recording's voice instead of a described one.
  ///
  /// The checkpoint's ICL path needs the clip *and* its transcript (`refText`); the transcript is
  /// what aligns the reference with the text being read. If the user did not type one, the
  /// on-device Qwen3-ASR checkpoint transcribes the clip — no audio leaves the Mac either way.
  ///
  /// The clip is resampled to the model's rate and stored as `userProvided`, which is what stops
  /// the next Read Aloud from replacing it with a generated calibration.
  func importVoiceReference(
    from url: URL, for persona: Qwen3VoicePersona, transcript: String?
  ) async throws -> Data {
    let model = try await Qwen3TTSModelLoader.shared.model(.voiceDesign)
    // The loader mixes stereo files to mono — the library's `loadAudioArray` would read only
    // channel 0 and lose a voice that sits on the right channel.
    let resampled = try AudioFileMonoLoader.loadMonoSamples(
      from: url, targetRate: model.sampleRate).samples
    guard !resampled.isEmpty else { throw Qwen3TTSError.emptyAudio }

    let text = try await referenceTranscript(for: url, typed: transcript, language: persona.language)
    Qwen3VoiceReferenceStore.store(
      samples: resampled, sampleRate: model.sampleRate, text: text, for: persona.id,
      source: .userProvided)
    DebugLogger.log(
      "QWEN3-TTS: imported voice reference for \(persona.id) from \(url.lastPathComponent) "
        + "(\(resampled.count) samples, \(text.count) chars of transcript)")
    return Self.pcm16(from: resampled, sourceRate: Double(model.sampleRate))
  }

  /// The transcript that belongs to an imported reference clip: the user's own text when they
  /// typed one, otherwise a local transcription. Cloud transcription is deliberately not used —
  /// a voice sample is personal audio and importing a voice must not upload it.
  private func referenceTranscript(
    for url: URL, typed: String?, language: String
  ) async throws -> String {
    let trimmed = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    guard Qwen3ModelManager.shared.isModelAvailable(.asr) else {
      throw Qwen3TTSError.transcriptRequired
    }
    let text = try await Qwen3ASRService.shared.transcribe(audioURL: url, language: language)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw Qwen3TTSError.transcriptRequired }
    return text
  }

  /// The generation parameters every Qwen3-TTS call uses. The library default (temperature 0.9)
  /// re-samples the voice on every call; measured on a four-sentence German text, default 0.9 +
  /// reference gave F0 spread 31.0 Hz and mean MFCC similarity 0.8885, temperature 0.3 + reference
  /// gives 15.4 Hz and 0.9484. Lower (0.1) is worse again (21.3 Hz / 0.8811) — 0.3 is the sweet
  /// spot. Shared so a voice created in Settings is generated exactly like one created by a
  /// Read Aloud.
  private static var generationParameters: GenerateParameters {
    GenerateParameters(maxTokens: 4096, temperature: 0.3, topP: 1.0, repetitionPenalty: 1.05)
  }

  /// What the model's `voice` argument means differs by checkpoint: VoiceDesign takes the
  /// description itself, CustomVoice takes `"speaker, instruction"`. A CustomVoice persona
  /// therefore carries its speaker name in `speaker`; a VoiceDesign persona leaves it nil.
  private static func voiceArgument(
    for persona: Qwen3VoicePersona, modelType: Qwen3ModelType
  ) -> String {
    switch modelType {
    case .customVoice:
      // CustomVoice has no German-native speaker, so the instruction asks for the closest thing:
      // the least accented reading of German the fixed speaker can produce.
      let speaker = persona.customVoiceSpeaker ?? "aiden"
      return "\(speaker), \(persona.prompt)"
    case .voiceDesign, .asr:
      return persona.prompt
    }
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

  /// RMS level (per 10 ms window) below which audio counts as silence when trimming.
  static let silenceRMSThreshold: Float = 0.02
  /// Silence kept before the first speech window, so soft onsets (/h/, /f/, /s/) are not clipped.
  static let silenceLeadMarginSeconds = 0.04
  /// Trailing silence kept after the last speech window: decays stay intact and consecutive
  /// chunks (played back to back) keep a natural pause between sentences.
  static let silenceTailMarginSeconds = 0.2

  /// Trims the near-silence the checkpoint pads around text it cannot vocalize (headers, bylines,
  /// bare domains), without taking the natural pause between sentences with it.
  ///
  /// Speech boundaries come from a windowed RMS (10 ms) against `silenceRMSThreshold`, so a single
  /// click inside a long pad does not count as speech and a soft onset is not cut. Only silence
  /// beyond a 40 ms lead margin and a 200 ms tail margin is removed. A 5 ms fade is applied only
  /// where a cut actually happens, so the trim cannot click. A chunk with no speech window comes
  /// back empty; the caller skips that sentence.
  static func trimmingSilence(_ samples: [Float], sampleRate: Int) -> [Float] {
    guard !samples.isEmpty else { return samples }
    let window = max(1, sampleRate / 100)  // 10 ms
    let fade = max(1, sampleRate / 200)  // ~5 ms

    var firstSpeech: Int?
    var lastSpeechEnd = 0
    var start = 0
    while start < samples.count {
      let end = min(start + window, samples.count)
      var sum: Float = 0
      for i in start..<end { sum += samples[i] * samples[i] }
      if (sum / Float(end - start)).squareRoot() >= silenceRMSThreshold {
        if firstSpeech == nil { firstSpeech = start }
        lastSpeechEnd = end
      }
      start = end
    }
    guard let firstSpeech else { return [] }

    let from = max(0, firstSpeech - Int(silenceLeadMarginSeconds * Double(sampleRate)))
    let to = min(samples.count, lastSpeechEnd + Int(silenceTailMarginSeconds * Double(sampleRate)))
    var trimmed = Array(samples[from..<to])
    if from > 0 {
      for i in 0..<min(fade, trimmed.count) { trimmed[i] *= Float(i) / Float(fade) }
    }
    if to < samples.count {
      for i in 0..<min(fade, trimmed.count) {
        trimmed[trimmed.count - 1 - i] *= Float(i) / Float(fade)
      }
    }
    return trimmed
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

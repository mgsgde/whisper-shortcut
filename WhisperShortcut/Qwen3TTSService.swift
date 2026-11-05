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
/// for the chat models: loading is expensive (up to 2.9 GB of weights) and a menu-bar app must
/// not hold both checkpoints forever. Switching between VoiceDesign and CustomVoice unloads the
/// other one.
actor Qwen3TTSModelLoader {
  static let shared = Qwen3TTSModelLoader()

  private var loadedType: Qwen3ModelType?
  private var loaded: SpeechGenerationModel?
  private var inFlight: Task<SpeechGenerationModel, Error>?

  /// Loads (or returns) the model for `type`. The cached instance is reused for every chunk of a
  /// long text — that is the point of caching it here rather than in the caller.
  func model(_ type: Qwen3ModelType) async throws -> SpeechGenerationModel {
    if let loaded, loadedType == type { return loaded }
    if let inFlight { return try await inFlight.value }

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
    defer { inFlight = nil }
    let model = try await task.value
    loaded = model
    loadedType = type
    return model
  }

  func unload() {
    loaded = nil
    loadedType = nil
  }
}

/// Synthesizes Read Aloud audio with Qwen3-TTS.
struct Qwen3TTSService {
  static let shared = Qwen3TTSService()

  /// The rate every Read Aloud provider emits, and what the playback path expects.
  private static let outputSampleRate: Double = 24_000

  /// Characters per synthesis request. The model's generation cost grows faster than linearly
  /// with audio length, and a single long request holds the whole waveform in memory before
  /// anything can play. 400 characters is roughly 25–30 seconds of speech — long enough that the
  /// per-chunk overhead disappears, short enough that a failure costs one paragraph.
  private static let chunkSizeChars = 400

  /// Synthesizes `text` with `persona` to s16le 24 kHz mono PCM.
  ///
  /// `onChunkReady` receives each chunk's PCM as soon as it is done, in playback order, so
  /// playback can start while the rest is still being generated.
  func synthesizePCM(
    text: String,
    persona: Qwen3VoicePersona,
    modelType: Qwen3ModelType,
    onChunkReady: ((Data, Int, Int) -> Void)? = nil
  ) async throws -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return Data() }

    // Loaded once, before the loop: every chunk below reuses this instance.
    let model = try await Qwen3TTSModelLoader.shared.model(modelType)
    let chunks = Self.split(trimmed, maxChars: Self.chunkSizeChars)
    DebugLogger.log(
      "QWEN3-TTS: \(persona.id) via \(modelType.rawValue), \(trimmed.count) chars in "
        + "\(chunks.count) chunk(s)")

    var merged = Data()
    for (index, chunk) in chunks.enumerated() {
      try Task.checkCancellation()
      let start = Date()
      let audio = try await model.generate(
        text: chunk,
        voice: Self.voiceArgument(for: persona, modelType: modelType),
        refAudio: nil,
        refText: nil,
        language: persona.language
      )
      let samples = audio.asArray(Float.self)
      guard !samples.isEmpty else { throw Qwen3TTSError.emptyAudio }

      let pcm = Self.pcm16(from: samples, sourceRate: Double(model.sampleRate))
      merged.append(pcm)
      DebugLogger.log(
        "QWEN3-TTS: chunk \(index + 1)/\(chunks.count) \(samples.count) samples "
          + "(\(String(format: "%.2f", Double(samples.count) / Double(model.sampleRate)))s) "
          + "in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
      if let onChunkReady {
        await MainActor.run { onChunkReady(pcm, index, chunks.count) }
      }
    }

    DebugLogger.log("QWEN3-TTS: \(persona.id) total \(merged.count) bytes")
    return merged
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

  /// Splits at sentence boundaries, falling back to word boundaries for a sentence longer than
  /// `maxChars`. Never returns an empty chunk, and never returns a chunk over the cap.
  static func split(_ text: String, maxChars: Int) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    guard trimmed.count > maxChars else { return [trimmed] }

    // First cut into sentences, keeping each terminator with the sentence it ends. A terminator
    // only ends a sentence when whitespace follows it, so "3.5" stays in one piece.
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

    // Then pack sentences into chunks up to the cap, splitting any single sentence that is
    // itself longer than the cap at its last space.
    var chunks: [String] = []
    var pending = ""
    for sentence in sentences {
      if sentence.count > maxChars {
        if !pending.isEmpty { chunks.append(pending); pending = "" }
        chunks.append(contentsOf: splitLongSentence(sentence, maxChars: maxChars))
        continue
      }
      if pending.isEmpty {
        pending = sentence
      } else if pending.count + sentence.count <= maxChars {
        pending += sentence
      } else {
        chunks.append(pending)
        pending = sentence
      }
    }
    if !pending.isEmpty { chunks.append(pending) }

    return chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
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

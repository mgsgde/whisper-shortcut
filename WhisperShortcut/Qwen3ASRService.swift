//
//  Qwen3ASRService.swift
//  WhisperShortcut
//
//  On-device dictation through Qwen3-ASR (MLX, `mlx-audio-swift`).
//
//  Why this model: it is the first on-device ASR here that is not Whisper-family. Parakeet Ultra
//  covers 25 European languages at ~1/20 of Whisper's wait, but it produces Latin-script nonsense
//  on anything outside them; Qwen3-ASR covers 11 languages including German and is the only
//  on-device option that also handles Chinese, Japanese and Korean. It is not a replacement for
//  Parakeet on German — it is the choice for the languages Parakeet cannot do.
//

import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT

/// Errors a Qwen3-ASR transcription can fail with.
enum Qwen3ASRError: LocalizedError {
  case unsupportedMac
  case modelNotDownloaded
  case emptyAudio

  var errorDescription: String? {
    switch self {
    case .unsupportedMac:
      return String(localized: "On-device Qwen3 dictation needs a Mac with Apple silicon.")
    case .modelNotDownloaded:
      return String(localized: "The Qwen3 dictation model is not downloaded yet. Download it in Settings → Speech to Text.")
    case .emptyAudio:
      return String(localized: "The recording contained no audio.")
    }
  }
}

/// Owns the loaded Qwen3-ASR model. One resident model, same lifetime policy as the TTS loader.
actor Qwen3ASRModelLoader {
  static let shared = Qwen3ASRModelLoader()

  private var loaded: Qwen3ASRModel?
  private var inFlight: Task<Qwen3ASRModel, Error>?

  func model() async throws -> Qwen3ASRModel {
    if let loaded { return loaded }
    if let inFlight { return try await inFlight.value }

    let task = Task<Qwen3ASRModel, Error> {
      guard let local = Qwen3ModelManager.shared.resolveModelPath(for: .asr) else {
        throw Qwen3ASRError.modelNotDownloaded
      }
      DebugLogger.log("QWEN3-ASR: loading \(local.path)")
      let start = Date()
      // `fromPretrained` takes a repo id and would download into the shared HuggingFace cache;
      // the app's own folder is already there, so load it directly.
      let model = try await Qwen3ASRModel.fromModelDirectory(local)
      DebugLogger.log(
        "QWEN3-ASR: loaded in \(String(format: "%.1f", Date().timeIntervalSince(start)))s, "
          + "sampleRate=\(model.sampleRate)")
      return model
    }
    inFlight = task
    defer { inFlight = nil }
    let model = try await task.value
    loaded = model
    return model
  }

  func unload() {
    loaded = nil
  }
}

/// Transcribes a recording with Qwen3-ASR.
struct Qwen3ASRService {
  static let shared = Qwen3ASRService()

  /// Transcribes `audioURL`. `language` is the model's English language name ("German", …) or
  /// nil for auto-detection.
  ///
  /// The model wants a mono float waveform at its own sample rate, so the file is decoded and
  /// resampled first — the recorder writes 16 kHz mono, the model reads at 16 kHz, but a
  /// user-supplied file need not match.
  func transcribe(audioURL: URL, language: String?) async throws -> String {
    let model = try await Qwen3ASRModelLoader.shared.model()

    let (fileRate, samples) = try loadAudioArray(from: audioURL)
    guard samples.size > 0 else { throw Qwen3ASRError.emptyAudio }

    let audio: MLXArray
    if abs(Double(fileRate) - Double(model.sampleRate)) < 1 {
      audio = samples
    } else {
      audio = Self.resample(samples, from: Double(fileRate), to: Double(model.sampleRate))
    }

    let start = Date()
    let output = model.generate(audio: audio, language: language)
    DebugLogger.log(
      "QWEN3-ASR: transcribed \(String(format: "%.1f", Double(samples.size) / Double(fileRate)))s "
        + "in \(String(format: "%.1f", Date().timeIntervalSince(start)))s → \(output.text.count) chars")
    return output.text
  }

  /// Linear resampling. The recorder's 16 kHz matches the model, so this only runs for an
  /// imported file with a different rate.
  private static func resample(_ samples: MLXArray, from source: Double, to target: Double) -> MLXArray {
    let values = samples.asArray(Float.self)
    let ratio = target / source
    let count = Int(Double(values.count) * ratio)
    guard count > 0 else { return MLXArray([Float]()) }
    let resampled: [Float] = (0..<count).map { index in
      let position = Double(index) / ratio
      let lower = Int(position)
      let upper = min(lower + 1, values.count - 1)
      let fraction = Float(position - Double(lower))
      return values[lower] * (1 - fraction) + values[upper] * fraction
    }
    return MLXArray(resampled)
  }
}

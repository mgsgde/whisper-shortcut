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
      return String(localized: "The Qwen3 dictation model is not downloaded yet. Download it in Settings → Dictate.")
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
  private let lifetime = ModelLifetimeGuards()

  /// 2.5 GB of weights must not stay resident between dictations. Same window as the TTS loader
  /// and `MLXModelLoader`.
  private static let idleUnloadAfter: TimeInterval = 5 * 60

  func model() async throws -> Qwen3ASRModel {
    if let loaded {
      scheduleIdleUnload()
      return loaded
    }
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
    startLifetimeGuardsIfNeeded()
    scheduleIdleUnload()
    return model
  }

  /// Loads (or reuses) the model and runs `generate` on this actor. `model()` hands the instance
  /// out for the prewarm, and `Qwen3ASRModel.generate` is not safe to call twice at once — two
  /// transcriptions would otherwise overlap on the one MLX model. Once `model()` has returned,
  /// decoding and `generate` do not suspend, so the next caller waits until this one finishes.
  func generate(audioURL: URL, language: String?, context: String = "") async throws -> String {
    let model = try await model()
    let (_, samples) = try AudioFileMonoLoader.loadMonoSamples(
      from: audioURL, targetRate: model.sampleRate)
    let audio = MLXArray(samples)
    guard audio.size > 0 else { throw Qwen3ASRError.emptyAudio }

    let start = Date()
    let output = model.generate(audio: audio, context: context, language: language)
    DebugLogger.log(
      "QWEN3-ASR: transcribed \(String(format: "%.1f", Double(samples.count) / Double(model.sampleRate)))s "
        + "in \(String(format: "%.1f", Date().timeIntervalSince(start)))s → \(output.text.count) chars")
    return output.text
  }

  func unload() {
    loaded = nil
    lifetime.cancelIdleUnload()
  }

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
    DebugLogger.log("QWEN3-ASR: unloading (\(reason))")
    loaded = nil
    lifetime.cancelIdleUnload()
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
  /// user-supplied file need not match (and may be stereo, which the loader mixes to mono).
  ///
  /// `context` is the library's system-context slot: a plain list of terms the audio may contain
  /// (the Glossary). It biases recognition only; the model takes no instructions.
  func transcribe(audioURL: URL, language: String?, context: String = "") async throws -> String {
    try await Qwen3ASRModelLoader.shared.generate(audioURL: audioURL, language: language, context: context)
  }
}

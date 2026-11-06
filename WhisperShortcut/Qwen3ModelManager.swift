//
//  Qwen3ModelManager.swift
//  WhisperShortcut
//
//  Download and availability for the two on-device Qwen3 audio models:
//  Qwen3-ASR (dictation) and Qwen3-TTS VoiceDesign (Read Aloud).
//
//  Both are MLX checkpoints from `mlx-community`, loaded through `mlx-audio-swift`. They share
//  one folder and one download mechanism, but they are separate models with separate sizes, so
//  each is its own catalogue entry — a user who wants Read Aloud should not have to download the
//  dictation model as well.
//

import Combine
import Foundation
import Hub

/// The on-device Qwen3 audio models.
///
/// Read Aloud has exactly one checkpoint, VoiceDesign. The 0.6B CustomVoice checkpoint was
/// dropped: its nine fixed speakers are Chinese, English, Japanese and Korean natives, so German
/// came out as a non-native speaker reading German. VoiceDesign is the only checkpoint that can be
/// told "native German speaker, no foreign accent", which is the whole point of offering a local
/// voice here.
enum Qwen3ModelType: String, CaseIterable, DownloadableModel {
  case asr = "qwen3-asr-1.7b"
  case voiceDesign = "qwen3-tts-voicedesign-1.7b"

  var displayName: String {
    switch self {
    case .asr: return "Qwen3 ASR 1.7B"
    case .voiceDesign: return "Qwen3 TTS VoiceDesign 1.7B"
    }
  }

  /// Hugging Face repo id. One constant per model, used by both the downloader and the loader.
  var huggingFaceID: String {
    switch self {
    case .asr: return "mlx-community/Qwen3-ASR-1.7B-8bit"
    case .voiceDesign: return "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit"
    }
  }

  /// Measured on disk after download (2026-11-05): ASR 2.46 GB, VoiceDesign 2.9 GB.
  var estimatedSizeMB: Int {
    switch self {
    case .asr: return 2460
    case .voiceDesign: return 2900
    }
  }

  var estimatedSizeLabel: String {
    String(format: "~%.1f GB", Double(estimatedSizeMB) / 1000)
  }

  /// MLX needs Apple silicon. Intel Macs keep the cloud and own-server paths.
  static var isSupportedOnThisMac: Bool {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
  }
}

/// Download bookkeeping for the Qwen3 audio models. Same shape as `LocalLLMModelManager`, so the
/// Settings rows, the progress popup and the delete path all behave identically.
final class Qwen3ModelManager: ModelStore<Qwen3ModelType> {
  static let shared = Qwen3ModelManager()

  private init() {
    super.init(logPrefix: "QWEN3-MODEL-MANAGER")
  }

  // MARK: - Paths

  /// Its own root, not `MLXModels`: the chat models and the audio models are unrelated
  /// downloads, and a user deleting one family should not see the other's gigabytes.
  override nonisolated var rootDirectory: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("Qwen3Models")
      .appendingPathComponent("hub")
  }

  override nonisolated func resolveModelPath(for type: Qwen3ModelType) -> URL? {
    let models = rootDirectory.appendingPathComponent("models")
    var candidates = [models.appendingPathComponent(type.huggingFaceID)]
    let parts = type.huggingFaceID.split(separator: "/").map(String.init)
    if parts.count == 2 {
      candidates.append(models.appendingPathComponent(parts[0]).appendingPathComponent(parts[1]))
    }
    for repoPath in candidates {
      if Self.hasRequiredFiles(at: repoPath) { return repoPath }
      let snapshots = repoPath.appendingPathComponent("snapshots")
      guard let hashes = try? fileManager.contentsOfDirectory(atPath: snapshots.path) else {
        continue
      }
      for hash in hashes {
        let snapshot = snapshots.appendingPathComponent(hash)
        if Self.hasRequiredFiles(at: snapshot) { return snapshot }
      }
    }
    return nil
  }

  /// Delete the whole repo, not just the snapshot folder — otherwise the blobs stay on disk
  /// while Settings reports the space as reclaimed.
  override nonisolated func deletionTarget(for modelPath: URL) -> URL {
    modelPath.deletingLastPathComponent().lastPathComponent == "snapshots"
      ? modelPath.deletingLastPathComponent().deletingLastPathComponent()
      : modelPath
  }

  /// `config.json` alone is not enough: a cancelled snapshot can land the config and the
  /// tokenizer but not the weights, and treating that as available makes Delete appear while
  /// the first load fails.
  private nonisolated static func hasRequiredFiles(at directory: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
      return false
    }
    guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
    return contents.contains { $0.hasSuffix(".safetensors") }
  }

  // MARK: - Load

  override func load(_ type: Qwen3ModelType) async throws {
    switch type {
    case .asr:
      _ = try await Qwen3ASRModelLoader.shared.model()
    case .voiceDesign:
      _ = try await Qwen3TTSModelLoader.shared.model()
    }
  }

  override func unload(_ type: Qwen3ModelType) async {
    switch type {
    case .asr:
      await Qwen3ASRModelLoader.shared.unload()
    case .voiceDesign:
      await Qwen3TTSModelLoader.shared.unload()
    }
  }

  // MARK: - Download

  override func fetch(
    _ type: Qwen3ModelType, onProgress: @escaping (Double) -> Void
  ) async throws {
    let downloader = TransformersHubDownloader(api: HubApi(downloadBase: rootDirectory))
    // Everything the checkpoint needs: weights, configs, tokenizer files and the speech
    // tokenizer subfolder. `*.safetensors` covers the nested `speech_tokenizer/` too.
    let filePatterns = ["*.safetensors", "*.json", "*.txt", "*.jinja", "*.model"]
    _ = try await downloader.download(
      id: type.huggingFaceID,
      revision: nil,
      matching: filePatterns,
      useLatest: false
    ) { progress in onProgress(progress.fractionCompleted) }
  }
}

//
//  LocalLLMModelManager.swift
//  WhisperShortcut
//
//  Catalogue, download, and load path for in-process MLX chat models.
//  Mirrors OfflineModelType / ModelManager for Dictate Prompt and Chat.
//

import Combine
import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - Model catalogue

enum LocalLLMModelType: String, CaseIterable, DownloadableModel {
  case qwen34BInstruct2507 = "qwen3-4b-instruct-2507"
  // Qwen3 8B was removed 2026-09-30: on the offline Dictate Prompt benchmark it scored 30/36 rule
  // checks vs 34/36 for 4B Instruct, appended instead of editing on every round of
  // `edit-not-append`, and ran at twice the latency (plans/model-audits/2026-09-30-offline-prompt.md).
  // Persisted selections forward via `PromptModel.migrateLegacyPromptRawValue`; its weights are
  // removed by `MLXModelPaths.removeRetiredWeights`.

  var displayName: String {
    switch self {
    case .qwen34BInstruct2507: return "Qwen3 4B Instruct"
    }
  }

  /// Hugging Face repo id passed to mlx-swift-lm's loader.
  var huggingFaceID: String {
    switch self {
    case .qwen34BInstruct2507: return "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    }
  }

  var estimatedSizeMB: Int {
    switch self {
    case .qwen34BInstruct2507: return 2300
    }
  }

  /// Derived, not a second list: two hand-maintained copies of one number drift.
  var estimatedSizeLabel: String {
    String(format: "~%.1f GB", Double(estimatedSizeMB) / 1000)
  }

  var isRecommended: Bool {
    self == .qwen34BInstruct2507
  }

  static var defaultModel: LocalLLMModelType { .qwen34BInstruct2507 }

  /// MLX is Apple Silicon only. Intel Macs keep the HTTP local-server path.
  static var isSupportedOnThisMac: Bool {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
  }

  /// Whether Settings / pickers may offer this catalogue entry on this Mac. A per-model RAM floor
  /// belongs here when a catalogue entry needs one (Qwen3 8B had 16 GB).
  var isOfferable: Bool {
    Self.isSupportedOnThisMac
  }

  /// Preference order for Offline Mode: larger models last so a downloaded smaller model wins
  /// when both exist, and the recommended default is chosen when none are on disk yet.
  static var byPreference: [LocalLLMModelType] {
    [.qwen34BInstruct2507].filter(\.isOfferable)
  }

  static var offerable: [LocalLLMModelType] { allCases.filter(\.isOfferable) }

  var promptModel: PromptModel {
    PromptModel.forLocalLLMModel(self)
  }
}

// MARK: - Paths

/// Where MLX weights live on disk.
///
/// Free-standing on purpose: the `@MainActor` manager and the `MLXModelLoader` actor both need it,
/// and reaching across that boundary for a path forced a `fileprivate` accessor whose only job was
/// to smuggle a URL out of one isolation domain into the other.
enum MLXModelPaths {
  /// Hub cache root — same layout swift-transformers uses for snapshots.
  static var hubDirectory: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("MLXModels")
      .appendingPathComponent("hub")
  }

  /// The complete on-disk copy of `type`, or nil while it is missing or half-downloaded.
  static func localDirectory(for type: LocalLLMModelType) -> URL? {
    let models = hubDirectory.appendingPathComponent("models")
    var candidates = [models.appendingPathComponent(type.huggingFaceID)]
    let parts = type.huggingFaceID.split(separator: "/").map(String.init)
    if parts.count == 2 {
      candidates.append(models.appendingPathComponent(parts[0]).appendingPathComponent(parts[1]))
    }
    for repoPath in candidates {
      if hasRequiredFiles(at: repoPath) { return repoPath }
      let snapshots = repoPath.appendingPathComponent("snapshots")
      guard let hashes = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { continue }
      for hash in hashes {
        let snap = snapshots.appendingPathComponent(hash)
        if hasRequiredFiles(at: snap) { return snap }
      }
    }
    return nil
  }

  /// `tokenizer.json` is required because Hub snapshot can finish `config.json` + the
  /// `.safetensors` shard and still be cancelled before the tokenizer lands. Treating that
  /// half-repo as "available" made Delete appear and the first load fail.
  private static let requiredFileNames = ["config.json", "tokenizer.json"]

  /// Weights of catalogue entries that were removed. Nothing in Settings can reach them any more,
  /// so without this a user who had downloaded one keeps gigabytes they cannot see or delete.
  private static let retiredHuggingFaceIDs = ["mlx-community/Qwen3-8B-4bit"]

  /// Deletes the weights of removed catalogue entries. Cheap when there is nothing to do (one
  /// `fileExists` per entry), so it runs on every launch.
  static func removeRetiredWeights() {
    let models = hubDirectory.appendingPathComponent("models")
    for id in retiredHuggingFaceIDs {
      let dir = models.appendingPathComponent(id)
      guard FileManager.default.fileExists(atPath: dir.path) else { continue }
      do {
        try FileManager.default.removeItem(at: dir)
        DebugLogger.log("MLX: removed weights of retired model \(id)")
      } catch {
        DebugLogger.logWarning("MLX: could not remove retired model \(id): \(error.localizedDescription)")
      }
    }
  }

  private static func hasRequiredFiles(at directory: URL) -> Bool {
    let fileManager = FileManager.default
    guard requiredFileNames.allSatisfy({
      fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
    }) else { return false }

    guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
      return false
    }
    return contents.contains { $0.hasSuffix(".safetensors") }
  }
}

// MARK: - Manager

/// MLX weights: Hub snapshots under `Application Support/MLXModels/hub`, loaded in-process by
/// `MLXModelLoader`. Downloads, cancellation, readiness and deletion are `ModelStore`.
final class LocalLLMModelManager: ModelStore<LocalLLMModelType> {
  static let shared = LocalLLMModelManager()

  private let loader = MLXModelLoader()

  private init() {
    super.init(logPrefix: "LOCAL-LLM-MANAGER")
  }

  // MARK: - Paths

  override nonisolated var rootDirectory: URL { MLXModelPaths.hubDirectory }

  override nonisolated func resolveModelPath(for type: LocalLLMModelType) -> URL? {
    MLXModelPaths.localDirectory(for: type)
  }

  /// Delete the repo, not just the snapshot. `resolveModelPath` may land on
  /// `…/<repo>/snapshots/<hash>`, and removing only that leaves the rest of the repo directory —
  /// gigabytes that Settings then reports as reclaimed while the disk says otherwise.
  override nonisolated func deletionTarget(for modelPath: URL) -> URL {
    modelPath.deletingLastPathComponent().lastPathComponent == "snapshots"
      ? modelPath.deletingLastPathComponent().deletingLastPathComponent()
      : modelPath
  }

  // MARK: - Load

  override func load(_ type: LocalLLMModelType) async throws {
    _ = try await loader.container(for: type)
  }

  override func unload(_ type: LocalLLMModelType) async {
    await loader.unloadIfLoaded(type)
  }

  // MARK: - Download

  override func fetch(_ type: LocalLLMModelType, onProgress: @escaping (Double) -> Void) async throws {
    let downloader = TransformersHubDownloader(api: HubApi(downloadBase: rootDirectory))
    // Files only. Instantiating weights is `MLXModelLoader.container` so RAM is paid once.
    let filePatterns = ["*.safetensors", "*.json", "*.jinja"]
    _ = try await downloader.download(
      id: type.huggingFaceID,
      revision: nil,
      matching: filePatterns,
      useLatest: false
    ) { progress in onProgress(progress.fractionCompleted) }
  }
}

// MARK: - In-process loader

/// Owns the loaded MLX model container. Join-in-flight per model type.
actor MLXModelLoader {
  private var loadedType: LocalLLMModelType?
  private var loaded: ModelContainer?
  private var inFlight: [LocalLLMModelType: Task<ModelContainer, Error>] = [:]
  private let lifetime = ModelLifetimeGuards()

  /// Prefill regresses several-fold under memory pressure when the GPU cache is unbounded
  /// (`LocalLLMBenchmarkTests`, 2026-09-02, the last open item in `plans/active/local-llm-mlx.md`).
  /// 256 MB is a conservative cap so Whisper Turbo and MLX can coexist. `GPU.set(cacheLimit:)`
  /// is the mlx-swift-lm call; it forwards to `Memory.cacheLimit`.
  private static let gpuCacheLimitBytes = 256 * 1024 * 1024
  /// Matches typical Ollama `keep_alive` so a menu-bar app does not hold ~2 GB forever.
  private static let idleUnloadAfter: TimeInterval = 5 * 60

  init() {
    MLX.GPU.set(cacheLimit: Self.gpuCacheLimitBytes)
    DebugLogger.log("MLX: GPU cacheLimit=\(Self.gpuCacheLimitBytes) bytes")
  }

  func container(for type: LocalLLMModelType) async throws -> ModelContainer {
    startLifetimeGuardsIfNeeded()
    if loadedType == type, let loaded {
      scheduleIdleUnload()
      return loaded
    }

    if let existing = inFlight[type] {
      return try await existing.value
    }

    let task = Task {
      let context: ModelContext
      if let directory = MLXModelPaths.localDirectory(for: type) {
        // Already on disk: load the folder. The Hub downloader asks huggingface.co for the repo's
        // file list on every load, even with the model complete and Offline Mode on — seen as a
        // 2.9 MB exchange at each launch in the 2026-09-29 offline capture.
        DebugLogger.log("MLX: loading \(type.huggingFaceID) from disk")
        context = try await loadModel(from: directory, using: TransformersTokenizerLoader())
      } else {
        DebugLogger.log("MLX: loading \(type.huggingFaceID) (not on disk, downloading)")
        let downloader = TransformersHubDownloader(
          api: HubApi(downloadBase: MLXModelPaths.hubDirectory))
        context = try await loadModel(
          from: downloader,
          using: TransformersTokenizerLoader(),
          id: type.huggingFaceID
        ) { progress in
          let pct = Int(progress.fractionCompleted * 100)
          if pct % 10 == 0 {
            DebugLogger.log("MLX: download/load \(pct)%")
          }
        }
      }
      DebugLogger.log("MLX: ready \(type.huggingFaceID)")
      return ModelContainer(context: context)
    }

    inFlight[type] = task
    do {
      let value = try await task.value
      loaded = value
      loadedType = type
      inFlight[type] = nil
      scheduleIdleUnload()
      return value
    } catch {
      inFlight[type] = nil
      throw error
    }
  }

  func unloadIfLoaded(_ type: LocalLLMModelType) {
    guard loadedType == type else { return }
    unloadLoaded(reason: "delete")
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
    guard loadedType != nil else { return }
    DebugLogger.log("MLX: unloading \(loadedType?.huggingFaceID ?? "model") (\(reason))")
    loaded = nil
    loadedType = nil
    lifetime.cancelIdleUnload()
    Task { await MLXPromptCache.shared.dropAll() }
  }
}

extension LocalLLMModelManager {
  /// The one in-process container. Chat and Dictate Prompt both go through here
  /// so Qwen 4B is never instantiated twice.
  func container(for type: LocalLLMModelType) async throws -> ModelContainer {
    try await loader.container(for: type)
  }
}

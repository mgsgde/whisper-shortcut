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
  /// First in `allCases`, so it stays first in every picker: this is the recommended entry and the
  /// Dictate Prompt fallback (`byPreference`).
  case qwen34BInstruct2507 = "qwen3-4b-instruct-2507"
  // Qwen3 8B was removed 2026-09-30: on the offline Dictate Prompt benchmark it scored 30/36 rule
  // checks vs 34/36 for 4B Instruct, appended instead of editing on every round of
  // `edit-not-append`, and ran at twice the latency (plans/model-audits/2026-09-30-offline-prompt.md).
  // Persisted selections forward via `PromptModel.migrateLegacyPromptRawValue`; its weights are
  // removed by `MLXModelPaths.removeRetiredWeights`.

  // Added 2026-11-03, ordered by download size ascending (which is also ascending within each
  // family) so the list reads as a ladder from "runs on any Mac" to "needs a lot of RAM". Every
  // repo, `model_type` and size was verified against Hugging Face and against the `model_type`
  // registrations in mlx-swift-lm 3.32.3 (`Libraries/MLXLLM/LLMModelFactory.swift`).
  //
  // Since 2026-11-04 five of these families also carry their 6-bit and 8-bit quantisations. They
  // are the *same* model at a higher precision, not bigger models, so each one sits directly
  // behind its 4-bit sibling and `baseModel` is what groups them in the pickers. The 4-bit entry
  // stays the default, the recommended one, and the one the benchmark notes refer to: it is the
  // smallest and fastest. Quantisation does not change `model_type`, so the loader needs no new
  // architecture support — every repo below was checked against Hugging Face (repo exists,
  // `model_type` unchanged, total size measured from the `siblings` blob sizes).
  //
  // Deliberately *not* added, because the brief scoped the quantisation pass to the five families
  // above: Qwen3 4B Instruct, Qwen3.5 2B, LFM2.5 8B A1B and Gemma 4 26B A4B stay 4-bit only.
  // (Repos do exist for three of them — Qwen3-4B-Instruct-2507-{6,8}bit, Qwen3.5-2B-{6,8}bit,
  // gemma-4-26b-a4b-it-{6,8}bit — and LFM2.5 8B A1B has an 8-bit but no 6-bit repo.)
  case lfm2512B = "lfm2.5-1.2b-instruct"
  case lfm2512B6bit = "lfm2.5-1.2b-instruct-6bit"
  case lfm2512B8bit = "lfm2.5-1.2b-instruct-8bit"
  case qwen352B = "qwen3.5-2b"
  case qwen354B = "qwen3.5-4b"
  case qwen354B6bit = "qwen3.5-4b-6bit"
  case qwen354B8bit = "qwen3.5-4b-8bit"
  case lfm258BA1B = "lfm2.5-8b-a1b"
  case qwen359B = "qwen3.5-9b"
  case qwen359B6bit = "qwen3.5-9b-6bit"
  case qwen359B8bit = "qwen3.5-9b-8bit"
  case gemma412B = "gemma-4-12b-it"
  case gemma412B6bit = "gemma-4-12b-it-6bit"
  case gemma412B8bit = "gemma-4-12b-it-8bit"
  case gemma426BA4B = "gemma-4-26b-a4b-it"
  case qwen3635BA3B = "qwen3.6-35b-a3b"
  case qwen3635BA3B6bit = "qwen3.6-35b-a3b-6bit"
  case qwen3635BA3B8bit = "qwen3.6-35b-a3b-8bit"

  var displayName: String {
    switch self {
    case .qwen34BInstruct2507: return "Qwen3 4B Instruct"
    case .lfm2512B: return "LFM2.5 1.2B"
    case .lfm2512B6bit: return "LFM2.5 1.2B (6-bit)"
    case .lfm2512B8bit: return "LFM2.5 1.2B (8-bit)"
    case .qwen352B: return "Qwen3.5 2B"
    case .qwen354B: return "Qwen3.5 4B"
    case .qwen354B6bit: return "Qwen3.5 4B (6-bit)"
    case .qwen354B8bit: return "Qwen3.5 4B (8-bit)"
    case .lfm258BA1B: return "LFM2.5 8B A1B"
    case .qwen359B: return "Qwen3.5 9B"
    case .qwen359B6bit: return "Qwen3.5 9B (6-bit)"
    case .qwen359B8bit: return "Qwen3.5 9B (8-bit)"
    case .gemma412B: return "Gemma 4 12B"
    case .gemma412B6bit: return "Gemma 4 12B (6-bit)"
    case .gemma412B8bit: return "Gemma 4 12B (8-bit)"
    case .gemma426BA4B: return "Gemma 4 26B A4B"
    case .qwen3635BA3B: return "Qwen3.6 35B A3B"
    case .qwen3635BA3B6bit: return "Qwen3.6 35B A3B (6-bit)"
    case .qwen3635BA3B8bit: return "Qwen3.6 35B A3B (8-bit)"
    }
  }

  /// The family this entry belongs to — the 4-bit entry itself for a family that ships only one
  /// quantisation. Grouping code keys on this so the variants of one model stay together instead
  /// of reading as three unrelated models in a list of twenty.
  var baseModel: LocalLLMModelType {
    switch self {
    case .lfm2512B6bit, .lfm2512B8bit: return .lfm2512B
    case .qwen354B6bit, .qwen354B8bit: return .qwen354B
    case .qwen359B6bit, .qwen359B8bit: return .qwen359B
    case .gemma412B6bit, .gemma412B8bit: return .gemma412B
    case .qwen3635BA3B6bit, .qwen3635BA3B8bit: return .qwen3635BA3B
    case .qwen34BInstruct2507, .lfm2512B, .qwen352B, .qwen354B, .lfm258BA1B, .qwen359B,
         .gemma412B, .gemma426BA4B, .qwen3635BA3B:
      return self
    }
  }

  /// "4-bit" / "6-bit" / "8-bit": the precision this repo ships, i.e. the axis a user picks on
  /// within one family. Higher is closer to the unquantised model and costs RAM and speed.
  var quantisationLabel: String {
    switch self {
    case .lfm2512B6bit, .qwen354B6bit, .qwen359B6bit, .gemma412B6bit, .qwen3635BA3B6bit:
      return String(localized: "6-bit", comment: "Model quantisation level")
    case .lfm2512B8bit, .qwen354B8bit, .qwen359B8bit, .gemma412B8bit, .qwen3635BA3B8bit:
      return String(localized: "8-bit", comment: "Model quantisation level")
    case .qwen34BInstruct2507, .lfm2512B, .qwen352B, .qwen354B, .lfm258BA1B, .qwen359B,
         .gemma412B, .gemma426BA4B, .qwen3635BA3B:
      return String(localized: "4-bit", comment: "Model quantisation level")
    }
  }

  /// Hugging Face repo id passed to mlx-swift-lm's loader.
  var huggingFaceID: String {
    switch self {
    case .qwen34BInstruct2507: return "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    case .lfm2512B: return "mlx-community/LFM2.5-1.2B-Instruct-4bit"
    case .lfm2512B6bit: return "mlx-community/LFM2.5-1.2B-Instruct-6bit"
    case .lfm2512B8bit: return "mlx-community/LFM2.5-1.2B-Instruct-8bit"
    case .qwen352B: return "mlx-community/Qwen3.5-2B-4bit"
    case .qwen354B: return "mlx-community/Qwen3.5-4B-4bit"
    case .qwen354B6bit: return "mlx-community/Qwen3.5-4B-6bit"
    case .qwen354B8bit: return "mlx-community/Qwen3.5-4B-8bit"
    case .lfm258BA1B: return "mlx-community/LFM2.5-8B-A1B-MLX-4bit"
    case .qwen359B: return "mlx-community/Qwen3.5-9B-MLX-4bit"
    case .qwen359B6bit: return "mlx-community/Qwen3.5-9B-6bit"
    case .qwen359B8bit: return "mlx-community/Qwen3.5-9B-8bit"
    case .gemma412B: return "mlx-community/gemma-4-12B-it-4bit"
    case .gemma412B6bit: return "mlx-community/gemma-4-12B-it-6bit"
    case .gemma412B8bit: return "mlx-community/gemma-4-12B-it-8bit"
    case .gemma426BA4B: return "mlx-community/gemma-4-26b-a4b-it-4bit"
    case .qwen3635BA3B: return "mlx-community/Qwen3.6-35B-A3B-4bit"
    case .qwen3635BA3B6bit: return "mlx-community/Qwen3.6-35B-A3B-6bit"
    case .qwen3635BA3B8bit: return "mlx-community/Qwen3.6-35B-A3B-8bit"
    }
  }

  /// Sum of the repo's file sizes on Hugging Face, in MB (decimal, matching `estimatedSizeLabel`).
  /// Measured 2026-11-04 from the `siblings` blob sizes of each repo, not estimated from the
  /// parameter count: 6-bit and 8-bit are not a fixed multiple of the 4-bit size.
  var estimatedSizeMB: Int {
    switch self {
    case .qwen34BInstruct2507: return 2300
    case .lfm2512B: return 663
    case .lfm2512B6bit: return 956
    case .lfm2512B8bit: return 1248
    case .qwen352B: return 1749
    case .qwen354B: return 3061
    case .qwen354B6bit: return 4112
    case .qwen354B8bit: return 5164
    case .lfm258BA1B: return 4782
    case .qwen359B: return 5600
    case .qwen359B6bit: return 8215
    case .qwen359B8bit: return 10453
    case .gemma412B: return 6773
    case .gemma412B6bit: return 9761
    case .gemma412B8bit: return 12749
    case .gemma426BA4B: return 15374
    case .qwen3635BA3B: return 20429
    case .qwen3635BA3B6bit: return 29089
    case .qwen3635BA3B8bit: return 37748
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

  /// Chat-only entries are excluded from Dictate Prompt: on the 2026-09-30 offline Dictate Prompt
  /// benchmark Qwen3.5 9B scored 28/36, formalised casual text and translated EN→DE
  /// (plans/model-audits/2026-09-30-offline-prompt.md); for Chat Q&A it beat the 4B
  /// (plans/model-audits/2026-10-18-offline-chat-larger-model.md).
  ///
  /// Deliberately conservative for the 2026-11-03 entries: only the two small Qwen3.5 models join
  /// Dictate Prompt. The same benchmark showed larger models scoring *worse* on the rule checks
  /// (30/36 for 8B vs 34/36 for 4B) while running slower, so a new entry stays chat-only until it
  /// has been measured on the edit benchmark — a bigger model is not a better editor.
  ///
  /// The 2026-11-04 quantised variants are chat-only too, including Qwen3.5 4B's, whose 4-bit
  /// sibling *is* a Dictate Prompt model: a higher-precision copy of a model has never been run
  /// through the edit benchmark, and the benchmark measures the 4-bit weights. Adding it on the
  /// strength of its sibling would put an unmeasured model in the one feature where the app's own
  /// numbers say precision is not the bottleneck.
  var supportsDictatePrompt: Bool {
    switch self {
    case .qwen34BInstruct2507, .qwen352B, .qwen354B: return true
    case .lfm2512B, .lfm2512B6bit, .lfm2512B8bit, .qwen354B6bit, .qwen354B8bit,
         .lfm258BA1B, .qwen359B, .qwen359B6bit, .qwen359B8bit, .gemma412B, .gemma412B6bit,
         .gemma412B8bit, .gemma426BA4B, .qwen3635BA3B, .qwen3635BA3B6bit, .qwen3635BA3B8bit:
      return false
    }
  }

  /// Physical RAM (GiB) a Mac needs before this entry is offered. Roughly twice the download size,
  /// rounded up to a common Mac configuration: the weights are only half of it, the rest is the OS
  /// plus the KV cache, which grows with the context the chat fills.
  ///
  /// For a quantised variant the same rule is applied to its own measured size, and the result is
  /// never allowed below its 4-bit sibling's floor — a family must not become *easier* to run at a
  /// higher precision. That is why Qwen3.5 4B's 6-bit and 8-bit stay at 16 GB (2× their size is
  /// 8.2 / 10.3 GB) and Gemma 4 12B's 6-bit stays at 32 GB (2× is 19.5 GB, but its 4-bit sibling
  /// already needs 32).
  var minimumPhysicalMemoryGB: Int {
    switch self {
    case .qwen34BInstruct2507: return 0
    case .lfm2512B, .lfm2512B6bit, .lfm2512B8bit, .qwen352B: return 8
    case .qwen354B, .qwen354B6bit, .qwen354B8bit, .lfm258BA1B, .qwen359B: return 16
    case .qwen359B6bit, .qwen359B8bit: return 24
    case .gemma412B, .gemma412B6bit, .gemma412B8bit: return 32
    case .gemma426BA4B: return 48
    case .qwen3635BA3B, .qwen3635BA3B6bit: return 64
    case .qwen3635BA3B8bit: return 96
    }
  }

  /// Whether Settings / pickers may offer this catalogue entry on this Mac: Apple Silicon plus the
  /// per-model RAM floor. A 16 GB Mac reports exactly 16 << 30 bytes, hence `>=`.
  var isOfferable: Bool {
    Self.isSupportedOnThisMac
      && ProcessInfo.processInfo.physicalMemory >= UInt64(minimumPhysicalMemoryGB) << 30
  }

  /// Preference order for Offline Mode: larger models last so a downloaded smaller model wins
  /// when both exist, and the recommended default is chosen when none are on disk yet.
  static var byPreference: [LocalLLMModelType] {
    // Chat-only entries (see `supportsDictatePrompt`) are deliberately absent: this is the Dictate Prompt fallback.
    [.qwen34BInstruct2507].filter(\.isOfferable)
  }

  static var offerable: [LocalLLMModelType] { allCases.filter(\.isOfferable) }

  /// The families in `allCases` order (ascending download size), each with its entries. Grouping
  /// key for the download list: three rows named "Qwen3.5 4B", "… 6-bit", "… 8-bit" belong under
  /// one header, not scattered through a list of nineteen.
  static func families(in models: [LocalLLMModelType]) -> [(base: LocalLLMModelType, models: [LocalLLMModelType])] {
    var order: [LocalLLMModelType] = []
    var grouped: [LocalLLMModelType: [LocalLLMModelType]] = [:]
    for model in models {
      let base = model.baseModel
      if grouped[base] == nil { order.append(base) }
      grouped[base, default: []].append(model)
    }
    return order.map { (base: $0, models: grouped[$0] ?? []) }
  }

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
        DebugLogger.logWarning("MLX: could not remove retired model \(id): \(error.logDescription)")
      }
    }
  }

  static func hasRequiredFiles(at directory: URL) -> Bool {
    let fileManager = FileManager.default
    guard requiredFileNames.allSatisfy({
      fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
    }) else { return false }

    // A sharded repo must have every shard its index names. A download cancelled mid-way leaves
    // one shard finished and the other as `.incomplete`; "any .safetensors" accepted that folder,
    // and MLX then trapped in `Module.update(modules:)` on the missing weights instead of
    // throwing (2026-10-18, Qwen3.5 9B: shard 2 of 2 on disk, shard 1 at 3.7 of ~5 GB).
    let index = directory.appendingPathComponent("model.safetensors.index.json")
    if let data = try? Data(contentsOf: index) {
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let weightMap = json["weight_map"] as? [String: String],
        !weightMap.isEmpty
      else { return false }
      return Set(weightMap.values).allSatisfy {
        fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
      }
    }

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
    _ = try await container(for: type)
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

struct MLXUnsupportedMacError: LocalizedError {
  var errorDescription: String? {
    String(localized: "Offline models need a Mac with Apple silicon. On this Mac, use a cloud model or a Local Server (Ollama / LM Studio).")
  }
}

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

  private var gpuConfigured = false

  /// No MLX call in `init`: `LocalLLMModelManager.shared` builds this loader as soon as any
  /// Settings model picker appears, and on an Intel Mac `GPU.set(cacheLimit:)` brings up the
  /// Metal device MLX cannot run on and aborts the app (customer report 2026-10-17, v8.40:
  /// Settings → Smart Improvement quit the app on an Intel MacBook Pro).
  private func configureGPUIfNeeded() {
    guard !gpuConfigured else { return }
    gpuConfigured = true
    MLX.GPU.set(cacheLimit: Self.gpuCacheLimitBytes)
    DebugLogger.log("MLX: GPU cacheLimit=\(Self.gpuCacheLimitBytes) bytes")
  }

  func isLoaded(_ type: LocalLLMModelType) -> Bool {
    loadedType == type && loaded != nil
  }

  func container(for type: LocalLLMModelType) async throws -> ModelContainer {
    guard LocalLLMModelType.isSupportedOnThisMac else { throw MLXUnsupportedMacError() }
    configureGPUIfNeeded()
    startLifetimeGuardsIfNeeded()
    if loadedType == type, let loaded {
      scheduleIdleUnload()
      return loaded
    }

    if let existing = inFlight[type] {
      return try await existing.value
    }

    let task = Task {
      // `ModelStore.fetch` is the only downloader (disk check, progress, cancel).
      guard let directory = MLXModelPaths.localDirectory(for: type) else {
        DebugLogger.logWarning("MLX: \(type.huggingFaceID) is not on disk, refusing to download in the loader")
        throw ModelStoreError.fileError("\(type.displayName) is not downloaded")
      }
      // Load the folder. The Hub downloader asks huggingface.co for the repo's
      // file list on every load, even with the model complete and Offline Mode on — seen as a
      // 2.9 MB exchange at each launch in the 2026-09-29 offline capture.
      DebugLogger.log("MLX: loading \(type.huggingFaceID) from disk")
      let context: ModelContext
      do {
        context = try await loadModel(from: directory, using: TransformersTokenizerLoader())
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Corrupt weights, memory pressure: typed so the recording is kept and Retry offered.
        DebugLogger.logError("MLX: load of \(type.huggingFaceID) failed: \(error.logDescription)")
        throw TranscriptionError.localModelFailed(String(localized: "Failed to load \(type.displayName): \(error.localizedDescription). The model may be incomplete or corrupted. Please try downloading it again in Settings."))
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
  /// True when this model's container is already in memory, so a caller can report `loadMs` 0
  /// instead of the few milliseconds a cache hit takes.
  func isContainerLoaded(_ type: LocalLLMModelType) async -> Bool {
    await loader.isLoaded(type)
  }

  /// The one in-process container. Chat and Dictate Prompt both go through here
  /// so Qwen 4B is never instantiated twice.
  func container(for type: LocalLLMModelType) async throws -> ModelContainer {
    try await loader.container(for: type)
  }
}

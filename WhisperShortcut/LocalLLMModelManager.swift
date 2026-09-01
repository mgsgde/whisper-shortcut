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
import MLXLLM
import MLXLMCommon

// MARK: - Model catalogue

enum LocalLLMModelType: String, CaseIterable {
  case qwen34BInstruct2507 = "qwen3-4b-instruct-2507"
  case qwen38B = "qwen3-8b"

  var displayName: String {
    switch self {
    case .qwen34BInstruct2507: return "Qwen3 4B Instruct"
    case .qwen38B: return "Qwen3 8B"
    }
  }

  /// Hugging Face repo id passed to mlx-swift-lm's loader.
  var huggingFaceID: String {
    switch self {
    case .qwen34BInstruct2507: return "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    case .qwen38B: return "mlx-community/Qwen3-8B-4bit"
    }
  }

  var estimatedSizeMB: Int {
    switch self {
    case .qwen34BInstruct2507: return 2300
    case .qwen38B: return 4500
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

  /// Preference order for Offline Mode: larger models last so a downloaded smaller model wins
  /// when both exist, and the recommended default is chosen when none are on disk yet.
  static var byPreference: [LocalLLMModelType] {
    [.qwen34BInstruct2507, .qwen38B]
  }

  static var offerable: [LocalLLMModelType] { allCases }

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
}

// MARK: - Manager

/// Downloads MLX weights into Application Support and owns the loaded in-process model.
///
/// `@MainActor` on the whole type, not method by method. `readyTasks` and `downloadTasks` are
/// touched by the settings UI, the prewarmer, the reconciler and the Dictate Prompt path; isolating
/// only some of those methods left the two dictionaries racing. One isolation domain also deletes
/// every hand-written hop the `@Published` properties needed. Nothing heavy runs here as a result:
/// downloading and instantiating weights happen inside `await`s that suspend, and the weights
/// themselves live in `MLXModelLoader`, which is its own actor.
@MainActor
final class LocalLLMModelManager: ObservableObject {
  static let shared = LocalLLMModelManager()

  @Published var downloadingModels: Set<LocalLLMModelType> = []
  @Published var downloadProgress: [LocalLLMModelType: Double] = [:]

  private var readyTasks: [LocalLLMModelType: Task<Void, Error>] = [:]
  private var downloadTasks: [LocalLLMModelType: Task<Void, Error>] = [:]
  private let loader = MLXModelLoader()
  private let fileManager = FileManager.default

  private init() {}

  // MARK: - Paths

  private var hubDirectory: URL { MLXModelPaths.hubDirectory }

  func resolveModelPath(for type: LocalLLMModelType) -> URL? {
    let models = hubDirectory.appendingPathComponent("models")
    var candidates = [models.appendingPathComponent(type.huggingFaceID)]
    let parts = type.huggingFaceID.split(separator: "/").map(String.init)
    if parts.count == 2 {
      candidates.append(models.appendingPathComponent(parts[0]).appendingPathComponent(parts[1]))
    }
    for repoPath in candidates {
      if hasRequiredMLXFiles(at: repoPath) { return repoPath }
      let snapshots = repoPath.appendingPathComponent("snapshots")
      guard let hashes = try? fileManager.contentsOfDirectory(atPath: snapshots.path) else { continue }
      for hash in hashes {
        let snap = snapshots.appendingPathComponent(hash)
        if hasRequiredMLXFiles(at: snap) { return snap }
      }
    }
    return nil
  }

  /// `tokenizer.json` is required because Hub snapshot can finish `config.json` + the
  /// `.safetensors` shard and still be cancelled before the tokenizer lands. Treating that
  /// half-repo as "available" made Delete appear and the first load fail.
  private static let requiredFileNames = ["config.json", "tokenizer.json"]

  private func hasRequiredMLXFiles(at directory: URL) -> Bool {
    guard Self.requiredFileNames.allSatisfy({
      fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
    }) else { return false }

    guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
      return false
    }
    return contents.contains { $0.hasSuffix(".safetensors") }
  }

  // MARK: - Availability

  func isModelAvailable(_ type: LocalLLMModelType) -> Bool {
    resolveModelPath(for: type) != nil
  }

  // MARK: - Ready to use

  func ensureReady(_ type: LocalLLMModelType, onProgress: ((String) -> Void)? = nil) async throws {
    if let existing = readyTasks[type] {
      try await existing.value
      return
    }
    let task = Task<Void, Error> { try await self.makeReady(type, onProgress: onProgress) }
    readyTasks[type] = task
    defer { readyTasks[type] = nil }
    try await task.value
  }

  /// Same progress popup Dictate Prompt uses, so Chat and a picker tap are not a silent hang.
  func ensureReadyWithUI(_ type: LocalLLMModelType, title: String) async throws {
    defer { PopupNotificationWindow.dismissProcessing() }
    try await ensureReady(type) { status in
      PopupNotificationWindow.showOrUpdateProcessing(status, title: title)
    }
  }

  private func makeReady(_ type: LocalLLMModelType, onProgress: ((String) -> Void)?) async throws {
    if !isModelAvailable(type) {
      try await downloadModel(type) { fraction in
        onProgress?("Downloading \(type.displayName) — \(Int(fraction * 100))%")
      }
    }

    onProgress?("Loading \(type.displayName) into memory…")
    _ = try await loader.container(for: type)
  }

  // MARK: - Download

  func cancelDownload(_ type: LocalLLMModelType) {
    downloadTasks[type]?.cancel()
    readyTasks[type]?.cancel()
    downloadingModels.remove(type)
    downloadProgress[type] = nil
    DebugLogger.log("LOCAL-LLM-MANAGER: Cancelled download for \(type.huggingFaceID)")
  }

  func downloadModel(
    _ type: LocalLLMModelType,
    onProgress: ((Double) -> Void)? = nil
  ) async throws {
    if let existing = downloadTasks[type] {
      try await existing.value
      return
    }
    let task = Task<Void, Error> {
      try await self.performDownload(type, onProgress: onProgress)
    }
    downloadTasks[type] = task
    defer { downloadTasks[type] = nil }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func performDownload(
    _ type: LocalLLMModelType,
    onProgress: ((Double) -> Void)?
  ) async throws {
    downloadingModels.insert(type)
    downloadProgress[type] = 0
    defer {
      downloadingModels.remove(type)
      downloadProgress[type] = nil
    }

    try fileManager.createDirectory(at: hubDirectory, withIntermediateDirectories: true)

    DebugLogger.log("LOCAL-LLM-MANAGER: Starting download for \(type.huggingFaceID)")

    let downloader = TransformersHubDownloader(api: HubApi(downloadBase: hubDirectory))
    // Files only. Instantiating weights is `MLXModelLoader.container` so RAM is paid once.
    let filePatterns = ["*.safetensors", "*.json", "*.jinja"]

    do {
      let dir = try await downloader.download(
        id: type.huggingFaceID,
        revision: nil,
        matching: filePatterns,
        useLatest: false
      ) { progress in
        let fraction = progress.fractionCompleted
        Task { @MainActor [weak self] in
          self?.downloadProgress[type] = fraction
          onProgress?(fraction)
        }
      }

      // Hub 1.1.9's snapshot returns the repo URL when `Task.isCancelled` after a file,
      // instead of throwing. Catch that before we treat a partial tree as success.
      try Task.checkCancellation()

      guard hasRequiredMLXFiles(at: dir) || isModelAvailable(type) else {
        throw LocalLLMModelError.downloadFailed(
          "Model downloaded but required files are missing. Please try again.")
      }

      DebugLogger.logSuccess("LOCAL-LLM-MANAGER: \(type.displayName) downloaded successfully")
    } catch {
      if Self.isCancellation(error) {
        DebugLogger.log("LOCAL-LLM-MANAGER: Download cancelled for \(type.huggingFaceID)")
        throw CancellationError()
      }
      if let error = error as? LocalLLMModelError {
        throw error
      }
      DebugLogger.logError("LOCAL-LLM-MANAGER: Download failed: \(error.localizedDescription)")
      throw LocalLLMModelError.downloadFailed(error.localizedDescription)
    }
  }

  // MARK: - Delete

  func deleteModel(_ type: LocalLLMModelType) throws {
    // Cancel first. Deleting the files under a running download left the download re-creating
    // what Delete had just removed, and the button looked like it had done nothing.
    cancelDownload(type)
    guard let modelPath = resolveModelPath(for: type) else {
      throw LocalLLMModelError.fileError("Model not found")
    }
    // Delete the repo, not just the snapshot. `resolveModelPath` may land on
    // `…/<repo>/snapshots/<hash>`, and removing only that leaves the rest of the repo directory —
    // gigabytes that Settings then reports as reclaimed while the disk says otherwise.
    let target = modelPath.deletingLastPathComponent().lastPathComponent == "snapshots"
      ? modelPath.deletingLastPathComponent().deletingLastPathComponent()
      : modelPath
    try fileManager.removeItem(at: target)
    Task { await loader.unloadIfLoaded(type) }
    DebugLogger.log("LOCAL-LLM-MANAGER: Deleted \(type.displayName)")
  }

  func getModelSize(_ type: LocalLLMModelType) -> Int64? {
    guard let modelPath = resolveModelPath(for: type) else { return nil }
    var totalSize: Int64 = 0
    if let enumerator = fileManager.enumerator(at: modelPath, includingPropertiesForKeys: [.fileSizeKey]) {
      for case let fileURL as URL in enumerator {
        if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
          totalSize += Int64(fileSize)
        }
      }
    }
    return totalSize > 0 ? totalSize : nil
  }

  func formatSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

enum LocalLLMModelError: LocalizedError {
  case downloadFailed(String)
  case fileError(String)

  var errorDescription: String? {
    switch self {
    case .downloadFailed(let message): return "Download failed: \(message)"
    case .fileError(let message): return "File error: \(message)"
    }
  }
}

extension LocalLLMModelManager {
  /// Hub's per-file downloader cancels the URLSession with `URLError.cancelled`; Swift
  /// concurrency uses `CancellationError`. Both must stay silent in the Settings UI.
  fileprivate static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }
}

// MARK: - In-process loader

/// Owns the loaded MLX model container. Join-in-flight per model type.
actor MLXModelLoader {
  private var loadedType: LocalLLMModelType?
  private var loaded: ModelContainer?
  private var inFlight: [LocalLLMModelType: Task<ModelContainer, Error>] = [:]

  func container(for type: LocalLLMModelType) async throws -> ModelContainer {
    if loadedType == type, let loaded { return loaded }

    if let existing = inFlight[type] {
      return try await existing.value
    }

    let task = Task {
      DebugLogger.log("MLX: loading \(type.huggingFaceID)")
      let downloader = TransformersHubDownloader(
        api: HubApi(downloadBase: MLXModelPaths.hubDirectory))
      let context = try await loadModel(
        from: downloader,
        using: TransformersTokenizerLoader(),
        id: type.huggingFaceID
      ) { progress in
        let pct = Int(progress.fractionCompleted * 100)
        if pct % 10 == 0 {
          DebugLogger.log("MLX: download/load \(pct)%")
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
      return value
    } catch {
      inFlight[type] = nil
      throw error
    }
  }

  func unloadIfLoaded(_ type: LocalLLMModelType) {
    guard loadedType == type else { return }
    loaded = nil
    loadedType = nil
  }
}

extension LocalLLMModelManager {
  /// The one in-process container. Chat and Dictate Prompt both go through here
  /// so Qwen 4B is never instantiated twice.
  func container(for type: LocalLLMModelType) async throws -> ModelContainer {
    try await loader.container(for: type)
  }
}

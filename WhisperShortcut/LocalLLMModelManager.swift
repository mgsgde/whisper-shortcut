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

  var estimatedSizeLabel: String {
    switch self {
    case .qwen34BInstruct2507: return "~2.3 GB"
    case .qwen38B: return "~4.5 GB"
    }
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

// MARK: - Manager

/// Downloads MLX weights into Application Support and owns the loaded in-process model.
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

  private var mlxRootDirectory: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL().appendingPathComponent("MLXModels")
  }

  /// Hub cache root — same layout swift-transformers uses for snapshots.
  private var hubDirectory: URL {
    mlxRootDirectory.appendingPathComponent("hub")
  }

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

  private static let requiredFileNames = ["config.json"]

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

  @MainActor
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
  @MainActor
  func ensureReadyWithUI(_ type: LocalLLMModelType, title: String) async throws {
    defer { PopupNotificationWindow.dismissProcessing() }
    try await ensureReady(type) { status in
      PopupNotificationWindow.showOrUpdateProcessing(status, title: title)
    }
  }

  @MainActor
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
    Task { @MainActor in
      downloadingModels.remove(type)
      downloadProgress[type] = nil
    }
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
    await MainActor.run {
      downloadingModels.insert(type)
      downloadProgress[type] = 0
    }

    defer {
      Task { @MainActor in
        downloadingModels.remove(type)
        downloadProgress[type] = nil
      }
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
        Task { @MainActor in
          LocalLLMModelManager.shared.downloadProgress[type] = fraction
          onProgress?(fraction)
        }
      }

      guard hasRequiredMLXFiles(at: dir) || isModelAvailable(type) else {
        throw LocalLLMModelError.downloadFailed(
          "Model downloaded but required files are missing. Please try again.")
      }

      DebugLogger.logSuccess("LOCAL-LLM-MANAGER: \(type.displayName) downloaded successfully")
    } catch is CancellationError {
      DebugLogger.log("LOCAL-LLM-MANAGER: Download cancelled for \(type.huggingFaceID)")
      throw CancellationError()
    } catch let error as LocalLLMModelError {
      throw error
    } catch {
      DebugLogger.logError("LOCAL-LLM-MANAGER: Download failed: \(error.localizedDescription)")
      throw LocalLLMModelError.downloadFailed(error.localizedDescription)
    }
  }

  // MARK: - Delete

  func deleteModel(_ type: LocalLLMModelType) throws {
    guard let modelPath = resolveModelPath(for: type) else {
      throw LocalLLMModelError.fileError("Model not found")
    }
    try fileManager.removeItem(at: modelPath)
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
      let hubDir = LocalLLMModelManager.shared.hubDirectoryForLoader
      let downloader = TransformersHubDownloader(api: HubApi(downloadBase: hubDir))
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
  fileprivate var hubDirectoryForLoader: URL { hubDirectory }

  /// The one in-process container. Chat and Dictate Prompt both go through here
  /// so Qwen 4B is never instantiated twice.
  func container(for type: LocalLLMModelType) async throws -> ModelContainer {
    try await loader.container(for: type)
  }
}

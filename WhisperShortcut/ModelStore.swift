//
//  ModelStore.swift
//  WhisperShortcut
//
//  The download-and-readiness bookkeeping every on-device model family shares. WhisperKit
//  (`ModelManager`) and MLX (`LocalLLMModelManager`) each subclass it and override only what is
//  genuinely theirs: where files live, what a complete download looks like, how to fetch, how to
//  load into memory.
//

import Combine
import Foundation

/// A model the store can download: it has a name for status lines and a size for the disk check.
protocol DownloadableModel: Hashable {
  var displayName: String { get }
  var estimatedSizeMB: Int { get }
  /// What a Settings row shows before the model is on disk. A requirement (not just an
  /// extension) so a family's own spelling wins through the generic row.
  var estimatedSizeLabel: String { get }
}

enum ModelStoreError: LocalizedError {
  case downloadFailed(String)
  case fileError(String)

  var errorDescription: String? {
    switch self {
    case .downloadFailed(let message): return "Download failed: \(message)"
    case .fileError(let message): return "File error: \(message)"
    }
  }
}

/// `@MainActor` on the whole type, not method by method. `readyTasks` and `downloadTasks` are
/// touched by the settings UI, the prewarmer, the reconciler and the dictation paths; isolating
/// only some of those methods left the two dictionaries racing (the WhisperKit manager used to
/// clear `downloadTasks` from a detached `Task` inside a `defer`, so a finished download could
/// still be joined). One isolation domain also deletes every hand-written hop the `@Published`
/// properties needed. Nothing heavy runs here as a result: downloading and instantiating weights
/// happen inside `await`s that suspend.
///
/// The disk reads (`resolveModelPath`, `isModelAvailable`, `getModelSize`) are `nonisolated`
/// because synchronous, non-main callers need them — `TranscriptionModel.hasRequiredCredential`,
/// `SpeechErrorFormatter`, the `LocalSpeechService` actor. They touch nothing but the file system.
@MainActor
class ModelStore<Model: DownloadableModel>: ObservableObject {
  @Published var downloadingModels: Set<Model> = []
  /// Fraction downloaded per model, 0…1, while a download is running. Drives the progress bar in
  /// Settings and the text in the dictation popup — a 1.6 GB download with no progress reads as a
  /// hang, which is exactly how the first turbo download was experienced.
  @Published var downloadProgress: [Model: Double] = [:]

  /// In-flight `ensureReady` work per model, so a dictation that starts while Settings is already
  /// downloading joins that download instead of starting a second one.
  private var readyTasks: [Model: Task<Void, Error>] = [:]
  /// In-flight downloads, so Settings and onboarding can cancel the same task a dictation joined.
  private var downloadTasks: [Model: Task<Void, Error>] = [:]

  nonisolated let fileManager = FileManager.default
  /// `MODEL-MANAGER` / `LOCAL-LLM-MANAGER` — keeps the log lines greppable per family.
  nonisolated let logPrefix: String

  init(logPrefix: String) {
    self.logPrefix = logPrefix
  }

  // MARK: - Backend seam (override per model family)

  /// Where this family's models are downloaded to; also where free disk space is checked.
  nonisolated var rootDirectory: URL {
    fatalError("subclass must override rootDirectory")
  }

  /// The on-disk folder for `model`, or nil when it has never been (fully) downloaded.
  nonisolated func resolveModelPath(for model: Model) -> URL? {
    fatalError("subclass must override resolveModelPath(for:)")
  }

  /// True only when the model can be loaded as it is on disk. The default treats "folder
  /// resolved" as complete; a family whose folder can exist half-written overrides this.
  nonisolated func isModelAvailable(_ model: Model) -> Bool {
    resolveModelPath(for: model) != nil
  }

  /// Fetches the files for `model` into `rootDirectory`. Report progress as a 0…1 fraction.
  /// Throw `ModelStoreError` for anything the user should read verbatim; other errors are wrapped.
  func fetch(_ model: Model, onProgress: @escaping (Double) -> Void) async throws {
    fatalError("subclass must override fetch(_:onProgress:)")
  }

  /// Instantiates the downloaded weights so the first real request does not pay the load.
  func load(_ model: Model) async throws {
    fatalError("subclass must override load(_:)")
  }

  /// Drops `model` from memory if it is the one loaded. Called after its files are deleted.
  func unload(_ model: Model) async {}

  /// Status line shown between "downloaded" and "ready". WhisperKit overrides this because its
  /// wait is CoreML compiling for the Neural Engine — minutes, once, and worth naming.
  func preparingMessage(for model: Model) -> String {
    "Loading \(model.displayName) into memory…"
  }

  /// When loading fails after the folder looked complete, delete it and fetch once more.
  /// WhisperKit turns this on: a load failure there is the verified-corrupt case, and a user
  /// waiting on a dictation would otherwise sit on a permanent "Model Not Downloaded".
  var healsCorruptDownloadOnLoadFailure: Bool { false }

  /// What `deleteModel` removes. MLX overrides this to delete the whole Hub repo, not just the
  /// snapshot `resolveModelPath` lands on.
  nonisolated func deletionTarget(for modelPath: URL) -> URL { modelPath }

  // MARK: - Ready to use

  /// Makes `model` usable: downloads it if it is missing or incomplete, then loads it. Callers can
  /// use the model as soon as this returns.
  ///
  /// This is the single answer to "the model is not there yet". Before it existed, selecting a
  /// model, downloading it, and loading it were three separate user actions with three separate
  /// failure popups — and dictating before all three were done silently produced a cloud
  /// transcription instead (see `ModelSelectionReconciler`).
  ///
  /// `onProgress` receives user-facing status lines; it is called on the main actor.
  func ensureReady(_ model: Model, onProgress: ((String) -> Void)? = nil) async throws {
    if let existing = readyTasks[model] {
      // Someone (Settings, a previous dictation, the launch pre-load) is already on it.
      try await existing.value
      return
    }
    let task = Task<Void, Error> { try await self.makeReady(model, onProgress: onProgress) }
    readyTasks[model] = task
    defer { readyTasks[model] = nil }
    try await task.value
  }

  /// Same progress popup Dictate Prompt uses, so Chat and a picker tap are not a silent hang.
  func ensureReadyWithUI(_ model: Model, title: String) async throws {
    defer { PopupNotificationWindow.dismissProcessing() }
    try await ensureReady(model) { status in
      PopupNotificationWindow.showOrUpdateProcessing(status, title: title)
    }
  }

  private func makeReady(_ model: Model, onProgress: ((String) -> Void)?) async throws {
    if !isModelAvailable(model) {
      try await downloadModel(model) { fraction in
        onProgress?("Downloading \(model.displayName) — \(Int(fraction * 100))%")
      }
    }

    onProgress?(preparingMessage(for: model))
    do {
      try await load(model)
    } catch where healsCorruptDownloadOnLoadFailure && !Self.isCancellation(error) && !Self.isDeadline(error) {
      // A network drop mid-download must NOT wipe the tree: Hub skips files that already
      // landed, so a retry resumes instead of looping from zero. Only a load failure on a
      // complete-looking folder gets here. A load that ran out of time or was cancelled is
      // not a corrupt folder; purging 1.6 GB on a slow Mac would be the prewarmer's "far
      // too destructive" case on the dictation path.
      DebugLogger.logWarning(
        "\(logPrefix): \(model.displayName) failed to load (\(error.localizedDescription)); treating as corrupt and re-downloading once")
      try? removeFiles(of: model)
      await unload(model)
      onProgress?("The previous download was incomplete — fetching \(model.displayName) again…")
      try await downloadModel(model) { fraction in
        onProgress?("Downloading \(model.displayName) — \(Int(fraction * 100))%")
      }
      onProgress?(preparingMessage(for: model))
      try await load(model)
    }
  }

  // MARK: - Download

  func cancelDownload(_ model: Model) {
    downloadTasks[model]?.cancel()
    readyTasks[model]?.cancel()
    downloadingModels.remove(model)
    downloadProgress[model] = nil
    DebugLogger.log("\(logPrefix): Cancelled download for \(model.displayName)")
  }

  func downloadModel(_ model: Model, onProgress: ((Double) -> Void)? = nil) async throws {
    if let existing = downloadTasks[model] {
      try await existing.value
      return
    }
    let task = Task<Void, Error> {
      try await self.performDownload(model, onProgress: onProgress)
    }
    downloadTasks[model] = task
    defer { downloadTasks[model] = nil }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func performDownload(_ model: Model, onProgress: ((Double) -> Void)?) async throws {
    try DiskSpace.require(estimatedSizeMB: model.estimatedSizeMB, at: rootDirectory)

    downloadingModels.insert(model)
    downloadProgress[model] = 0
    defer {
      downloadingModels.remove(model)
      downloadProgress[model] = nil
    }

    // Keep a partial tree on a network drop so the next attempt skips complete files. Nothing
    // here purges — only `makeReady`'s load-failure path deletes a verified-corrupt folder.
    try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

    DebugLogger.log("\(logPrefix): Starting download for \(model.displayName)")
    do {
      try await fetch(model) { fraction in
        Task { @MainActor [weak self] in
          self?.downloadProgress[model] = fraction
          onProgress?(fraction)
        }
      }

      // Hub 1.1.9's snapshot returns normally when `Task.isCancelled` after a file, instead of
      // throwing. Catch that before a partial tree is treated as success.
      try Task.checkCancellation()

      guard isModelAvailable(model) else {
        throw ModelStoreError.downloadFailed(
          "Model downloaded but required files are missing. Please try again.")
      }
      DebugLogger.logSuccess("\(logPrefix): \(model.displayName) downloaded successfully")
    } catch {
      if Self.isCancellation(error) {
        DebugLogger.log("\(logPrefix): Download cancelled for \(model.displayName)")
        throw CancellationError()
      }
      if let error = error as? ModelStoreError {
        throw error
      }
      DebugLogger.logError("\(logPrefix): Download failed: \(error.localizedDescription)")
      throw ModelStoreError.downloadFailed(error.localizedDescription)
    }
  }

  // MARK: - Delete

  /// Removes the files and drops the model from memory.
  ///
  /// Cancels first. Deleting the files under a running download left the download re-creating
  /// what Delete had just removed, and the button looked like it had done nothing.
  func deleteModel(_ model: Model) throws {
    cancelDownload(model)
    try removeFiles(of: model)
    Task { await unload(model) }
    DebugLogger.log("\(logPrefix): Deleted \(model.displayName)")
  }

  /// The file-system half of `deleteModel`, without the cancel — `makeReady`'s self-heal runs
  /// inside the very `readyTasks` entry that `cancelDownload` would cancel.
  private func removeFiles(of model: Model) throws {
    guard let modelPath = resolveModelPath(for: model) else {
      throw ModelStoreError.fileError("Model not found")
    }
    try fileManager.removeItem(at: deletionTarget(for: modelPath))
  }

  // MARK: - Size

  nonisolated func getModelSize(_ model: Model) -> Int64? {
    guard let modelPath = resolveModelPath(for: model) else { return nil }
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

  nonisolated func formatSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }

  /// Hub / URLSession cancel with `URLError.cancelled`; Swift concurrency uses `CancellationError`.
  /// Both must stay silent in the Settings UI.
  nonisolated static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }

  /// A wall-clock deadline on load is not a corrupt folder. Same shape as `isCancellation`.
  nonisolated static func isDeadline(_ error: Error) -> Bool {
    switch error as? TranscriptionError {
    case .requestTimeout, .localProcessingTimeout: return true
    default: return false
    }
  }
}

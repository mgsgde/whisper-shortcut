//
//  ModelManager.swift
//  WhisperShortcut
//
//  Handles downloading, storage, and management of offline models
//

import Foundation
import Combine
import WhisperKit

// MARK: - Model Type Enum
enum OfflineModelType: String, CaseIterable {
  // Whisper models for transcription (WhisperKit CoreML models)
  case whisperTiny = "whisper-tiny"
  case whisperBase = "whisper-base"
  case whisperSmall = "whisper-small"
  case whisperMedium = "whisper-medium"
  case whisperLarge = "whisper-large"
  /// large-v3-turbo (the 2024-09-30 release): large-v3's encoder with a 4-layer decoder.
  case whisperLargeTurbo = "whisper-large-turbo"

  var displayName: String {
    switch self {
    case .whisperTiny: return "Whisper Tiny"
    case .whisperBase: return "Whisper Base"
    case .whisperSmall: return "Whisper Small"
    case .whisperMedium: return "Whisper Medium"
    case .whisperLarge: return "Whisper Large"
    case .whisperLargeTurbo: return "Whisper Large v3 Turbo"
    }
  }
  
  var estimatedSizeMB: Int {
    switch self {
    case .whisperTiny: return 75
    case .whisperBase: return 140
    case .whisperSmall: return 460
    case .whisperMedium: return 1500
    case .whisperLarge: return 3000  // full large-v3 ~3 GB; compressed variant exists at ~947 MB
    case .whisperLargeTurbo: return 1600  // full turbo ~1.6 GB; compressed variant exists at ~632 MB
    }
  }
  
  /// The model the list recommends: the one a user who does not want to research Whisper sizes
  /// should take. That is turbo — large-v3 accuracy at half its download and several times its
  /// speed. Base was recommended before turbo existed; a 140 MB model that mishears names is the
  /// wrong default for dictation you intend to keep.
  var isRecommended: Bool {
    return self == .whisperLargeTurbo
  }

  /// Shown instead of the star on the model that is merely the fastest way to *try* offline
  /// dictation. Keeps Base findable for a metered connection without implying it is the best pick.
  var isQuickStart: Bool {
    return self == .whisperBase
  }

  /// Offline models ordered worst to best transcript. Used to pick a sensible model on this Mac
  /// without asking the user which Whisper size means what — Offline Mode walks it from the end.
  static var byAccuracy: [OfflineModelType] {
    [.whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge, .whisperLargeTurbo]
  }

  /// The on-device model to use when the transcript has to be right. Turbo rather than
  /// `large-v3`: same accuracy, roughly half the download and several times faster.
  static var mostAccurate: OfflineModelType { .whisperLargeTurbo }
  
  // Map to WhisperKit model name (HuggingFace: openai_whisper-{name})
  var whisperKitModelName: String {
    switch self {
    case .whisperTiny: return "tiny"
    case .whisperBase: return "base"
    case .whisperSmall: return "small"
    case .whisperMedium: return "medium"
    case .whisperLarge: return "large-v3"
    // The HuggingFace repo (argmaxinc/whisperkit-coreml) names turbo by its release date;
    // `large-v3_turbo` there is the older v2-era conversion, so the dated variant is the one
    // that corresponds to OpenAI's large-v3-turbo.
    case .whisperLargeTurbo: return "large-v3-v20240930_turbo"
    }
  }
}

// MARK: - Model Manager
class ModelManager: ObservableObject {
  static let shared = ModelManager()
  
  @Published var downloadingModels: Set<OfflineModelType> = []
  /// Fraction downloaded per model, 0…1, while a download is running. Drives the progress bar in
  /// Settings and the text in the dictation popup — a 1.6 GB download with no progress reads as a
  /// hang, which is exactly how the first turbo download was experienced.
  @Published var downloadProgress: [OfflineModelType: Double] = [:]

  /// In-flight `ensureReady` work per model, so a dictation that starts while Settings is already
  /// downloading joins that download instead of starting a second one.
  private var readyTasks: [OfflineModelType: Task<Void, Error>] = [:]
  
  private let fileManager = FileManager.default
  
  private init() {}
  
  // MARK: - Resolve Model Path
  func resolveModelPath(for type: OfflineModelType) -> URL? {
    let whisperKitDir = AppSupportPaths.whisperShortcutApplicationSupportURL().appendingPathComponent("WhisperKit")
    
    // Check nested location (standard WhisperKit download structure)
    // models/argmaxinc/whisperkit-coreml/openai_whisper-[model]
    let nestedPath = whisperKitDir
      .appendingPathComponent("models")
      .appendingPathComponent("argmaxinc")
      .appendingPathComponent("whisperkit-coreml")
      .appendingPathComponent("openai_whisper-\(type.whisperKitModelName)")
      
    if fileManager.fileExists(atPath: nestedPath.path) {
      return nestedPath
    }
    
    // Check simple location (legacy/manual downloads)
    let possibleSimpleNames = [
      "openai_whisper-\(type.whisperKitModelName)",
      "\(type.whisperKitModelName)",
      "whisper-\(type.whisperKitModelName)"
    ]
    
    for name in possibleSimpleNames {
      let path = whisperKitDir.appendingPathComponent(name)
      if fileManager.fileExists(atPath: path.path) {
        return path
      }
    }
    
    return nil
  }

  // MARK: - Model Availability
  /// Returns true only when the model folder exists and contains required WhisperKit files
  /// (e.g. AudioEncoder.mlmodelc). Avoids showing incomplete downloads as "available".
  func isModelAvailable(_ type: OfflineModelType) -> Bool {
    guard let modelPath = resolveModelPath(for: type) else {
      let whisperKitDir = AppSupportPaths.whisperShortcutApplicationSupportURL().appendingPathComponent("WhisperKit")
      DebugLogger.logDebug("MODEL-MANAGER: Checking availability for \(type.displayName)")
      DebugLogger.logDebug("MODEL-MANAGER: WhisperKit directory: \(whisperKitDir.path)")
      if fileManager.fileExists(atPath: whisperKitDir.path),
         let contents = try? fileManager.contentsOfDirectory(atPath: whisperKitDir.path) {
        DebugLogger.logDebug("MODEL-MANAGER: WhisperKit directory contents: \(contents.joined(separator: ", "))")
      }
      return false
    }
    guard hasRequiredWhisperKitFiles(at: modelPath) else {
      DebugLogger.logDebug("MODEL-MANAGER: \(type.displayName) folder exists but missing required files (e.g. AudioEncoder.mlmodelc)")
      return false
    }
    DebugLogger.logDebug("MODEL-MANAGER: Found \(type.displayName) at: \(modelPath.path)")
    return true
  }

  /// The compiled CoreML components WhisperKit loads. Checking only `AudioEncoder.mlmodelc` (what
  /// this did before) reported a half-finished download as ready: the 2026-08-31 case got as far
  /// as recording, then failed inside WhisperKit with "Unable to load model …
  /// TextDecoderContextPrefill.mlmodelc", which the error mapping turned into a "Model Not
  /// Downloaded" popup for a model the UI was showing as downloaded.
  ///
  /// `TextDecoderContextPrefill` is deliberately NOT required: it is the prefill cache, and not
  /// every variant in the repo ships it. A model missing it still loads on most paths, and the
  /// case where it does not is handled by the self-heal in `ensureReady` rather than by declaring
  /// every such model unavailable.
  private static let requiredComponents = [
    "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc",
  ]

  private func hasRequiredWhisperKitFiles(at modelPath: URL) -> Bool {
    Self.requiredComponents.allSatisfy { findFile(named: $0, in: modelPath) }
  }

  private func findFile(named filename: String, in directory: URL) -> Bool {
    guard fileManager.fileExists(atPath: directory.path) else { return false }
    if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) {
      for case let fileURL as URL in enumerator {
        if fileURL.lastPathComponent == filename {
          return true
        }
      }
    }
    return false
  }
  
  // MARK: - Ready to use

  /// Makes `type` usable: downloads it if it is missing or incomplete, then loads it into
  /// `LocalSpeechService`. Callers can transcribe as soon as this returns.
  ///
  /// This is the single answer to "the model is not there yet". Before it existed, selecting a
  /// model, downloading it, and loading it were three separate user actions with three separate
  /// failure popups — and dictating before all three were done silently produced a cloud
  /// transcription instead (see `ModelSelectionReconciler`).
  ///
  /// `onProgress` receives user-facing status lines; it is called on the main actor.
  @MainActor
  func ensureReady(_ type: OfflineModelType, onProgress: ((String) -> Void)? = nil) async throws {
    if let existing = readyTasks[type] {
      // Someone (Settings, a previous dictation, the launch pre-load) is already on it.
      try await existing.value
      return
    }
    let task = Task<Void, Error> { try await self.makeReady(type, onProgress: onProgress) }
    readyTasks[type] = task
    defer { readyTasks[type] = nil }
    try await task.value
  }

  @MainActor
  private func makeReady(_ type: OfflineModelType, onProgress: ((String) -> Void)?) async throws {
    if !isModelAvailable(type) {
      try await downloadModel(type) { fraction in
        onProgress?("Downloading \(type.displayName) — \(Int(fraction * 100))%")
      }
    }

    onProgress?(Self.preparingMessage(for: type))
    do {
      try await LocalSpeechService.shared.initializeModel(type)
    } catch {
      // A download that stopped early passes the folder check but fails to load. Rather than
      // telling the user to delete and re-download by hand — the state they cannot distinguish
      // from a bug — purge it and fetch it once more.
      DebugLogger.logWarning(
        "MODEL-MANAGER: \(type.displayName) failed to load (\(error.localizedDescription)); re-downloading once")
      try? deleteModel(type)
      await LocalSpeechService.shared.unloadModel()
      onProgress?("The previous download was incomplete — fetching \(type.displayName) again…")
      try await downloadModel(type) { fraction in
        onProgress?("Downloading \(type.displayName) — \(Int(fraction * 100))%")
      }
      onProgress?(Self.preparingMessage(for: type))
      try await LocalSpeechService.shared.initializeModel(type)
    }
  }

  /// The wait after a download is CoreML compiling the model for the Neural Engine. It happens
  /// once per model and is minutes for the large ones, so it is worth naming rather than showing
  /// a spinner that looks stuck.
  private static func preparingMessage(for type: OfflineModelType) -> String {
    "Preparing \(type.displayName) for this Mac — one-time step, can take a few minutes."
  }

  // MARK: - Download Model
  func downloadModel(_ type: OfflineModelType, onProgress: ((Double) -> Void)? = nil) async throws {
    // Add model to downloading set on main actor
    await MainActor.run {
      downloadingModels.insert(type)
      downloadProgress[type] = 0
    }
    
    // Use defer to ensure we always remove from downloading set, even on error
    defer {
      Task { @MainActor in
        downloadingModels.remove(type)
        downloadProgress[type] = nil
      }
    }
    
    // WhisperKit handles downloads automatically
    // This method triggers model initialization which will download if needed
    DebugLogger.log("MODEL-MANAGER: Triggering WhisperKit model download for \(type.displayName)")
    
    // Set explicit modelFolder so we know where models are stored
    let whisperKitDir = AppSupportPaths.whisperShortcutApplicationSupportURL().appendingPathComponent("WhisperKit")
    let modelFolderPath = whisperKitDir.path
    
    // Ensure the directory exists
    try? fileManager.createDirectory(at: whisperKitDir, withIntermediateDirectories: true)
    
    DebugLogger.log("MODEL-MANAGER: Using modelFolder: \(modelFolderPath)")
    
    // Clean up any incomplete/corrupted downloads first
    await cleanupIncompleteDownloads(type: type, whisperKitDir: whisperKitDir)
    
    // Ensure nested directory exists so WhisperKit can move downloaded files (e.g. tokenizer_config.json) into the model folder
    let expectedNestedDir = whisperKitDir
      .appendingPathComponent("models")
      .appendingPathComponent("argmaxinc")
      .appendingPathComponent("whisperkit-coreml")
    try? fileManager.createDirectory(at: expectedNestedDir, withIntermediateDirectories: true)
    
    // Use the expected model name format for WhisperKit
    let modelName = "openai_whisper-\(type.whisperKitModelName)"
    
    do {
      DebugLogger.log("MODEL-MANAGER: Starting download for \(modelName)...")
      
      // Download the model using WhisperKit's download method
      let downloadedModelPath = try await WhisperKit.download(
        variant: modelName,
        downloadBase: whisperKitDir,
        progressCallback: { progress in
          let fraction = progress.fractionCompleted
          Task { @MainActor in
            ModelManager.shared.downloadProgress[type] = fraction
            onProgress?(fraction)
          }
        }
      )
      
      DebugLogger.log("MODEL-MANAGER: Download completed to: \(downloadedModelPath.path)")
      
      // Verify the model is actually available on disk
      let isAvailable = isModelAvailable(type)
      DebugLogger.log("MODEL-MANAGER: Model availability check after download: \(isAvailable)")
      
      if !isAvailable {
        logDirectoryContents(whisperKitDir)
        throw ModelError.downloadFailed("Model downloaded but not properly available. Please try downloading again.")
      }
      
      DebugLogger.logSuccess("MODEL-MANAGER: Model \(type.displayName) downloaded successfully")
    } catch let error as ModelError {
      // Re-throw our custom errors
      throw error
    } catch {
      // Log the full error for debugging
      let errorMessage = error.localizedDescription
      DebugLogger.logError("MODEL-MANAGER: WhisperKit error: \(errorMessage)")
      
      // Check for missing required model files (incomplete or corrupted download)
      if errorMessage.contains("MelSpectrogram.mlmodelc") {
        DebugLogger.logError("MODEL-MANAGER: MelSpectrogram.mlmodelc missing - this indicates an incomplete download")
        logDirectoryContents(whisperKitDir)
        throw ModelError.downloadFailed(
          "Model download appears incomplete. The MelSpectrogram.mlmodelc file is missing. " +
          "This usually means the download was interrupted or failed. " +
          "Please try downloading again. If the problem persists, try deleting any partial downloads first."
        )
      }
      if errorMessage.contains("AudioEncoder.mlmodelc") {
        DebugLogger.logError("MODEL-MANAGER: AudioEncoder.mlmodelc missing - model folder incomplete or corrupted")
        logDirectoryContents(whisperKitDir)
        throw ModelError.downloadFailed(
          "Model folder exists but AudioEncoder.mlmodelc is missing (incomplete or corrupted). " +
          "In Settings, delete the model and download it again."
        )
      }
      
      if let nsError = error as NSError? {
        DebugLogger.logError("MODEL-MANAGER: Error domain: \(nsError.domain), code: \(nsError.code)")
        DebugLogger.logError("MODEL-MANAGER: Error userInfo: \(nsError.userInfo)")
      }
      
      throw ModelError.downloadFailed("Failed to download WhisperKit model: \(errorMessage)")
    }
  }
  
  // MARK: - Cleanup Incomplete Downloads
  private func cleanupIncompleteDownloads(type: OfflineModelType, whisperKitDir: URL) async {
    // Clean nested path (WhisperKit standard: models/argmaxinc/whisperkit-coreml/openai_whisper-xxx)
    if let modelPath = resolveModelPath(for: type),
       fileManager.fileExists(atPath: modelPath.path),
       !hasRequiredWhisperKitFiles(at: modelPath) {
      DebugLogger.log("MODEL-MANAGER: Found incomplete download at \(modelPath.lastPathComponent), cleaning up...")
      try? fileManager.removeItem(at: modelPath)
    }

    // Also try legacy top-level names under WhisperKit
    let possibleModelNames = [
      "openai_whisper-\(type.whisperKitModelName)",
      "\(type.whisperKitModelName)",
      "whisper-\(type.whisperKitModelName)",
    ]
    for modelName in possibleModelNames {
      let modelPath = whisperKitDir.appendingPathComponent(modelName)
      if fileManager.fileExists(atPath: modelPath.path),
         !hasRequiredWhisperKitFiles(at: modelPath) {
        DebugLogger.log("MODEL-MANAGER: Found incomplete download for \(modelName), cleaning up...")
        try? fileManager.removeItem(at: modelPath)
      }
    }
  }
  
  // MARK: - Verify Model Files
  private func verifyModelFiles(type: OfflineModelType, whisperKitDir: URL) -> Bool {
    guard let modelPath = resolveModelPath(for: type) else {
      return false
    }
    
    // Check for essential model files
    // WhisperKit models typically contain .mlpackage files and other resources
    if let contents = try? fileManager.contentsOfDirectory(atPath: modelPath.path) {
      // Check for at least some model files (not empty directory)
      if !contents.isEmpty {
        // Check for common WhisperKit model file patterns
        let hasModelFiles = contents.contains { file in
          file.hasSuffix(".mlpackage") || 
          file.hasSuffix(".mlmodelc") || 
          file.hasSuffix(".bin") ||
          file.hasSuffix(".json")
        }
        
        if hasModelFiles {
          DebugLogger.log("MODEL-MANAGER: Verified model files exist in \(modelPath.path)")
          
          // Also check for MelSpectrogram.mlmodelc which is a common dependency
          // It might be in the model directory or a subdirectory
          let melSpectrogramFound = findMelSpectrogramFile(in: modelPath)
          if melSpectrogramFound {
            DebugLogger.log("MODEL-MANAGER: MelSpectrogram.mlmodelc found")
          } else {
            DebugLogger.log("MODEL-MANAGER: Warning: MelSpectrogram.mlmodelc not found in model directory")
          }
          
          return true
        }
      }
    }
    
    return false
  }
  
  // MARK: - Find MelSpectrogram File
  private func findMelSpectrogramFile(in directory: URL) -> Bool {
    // Check recursively for MelSpectrogram.mlmodelc
    if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) {
      for case let fileURL as URL in enumerator {
        if fileURL.lastPathComponent == "MelSpectrogram.mlmodelc" {
          DebugLogger.log("MODEL-MANAGER: Found MelSpectrogram.mlmodelc at: \(fileURL.path)")
          return true
        }
      }
    }
    return false
  }
  
  // MARK: - Log Directory Contents (for debugging)
  private func logDirectoryContents(_ directory: URL) {
    DebugLogger.log("MODEL-MANAGER: Listing contents of \(directory.path)")
    
    guard fileManager.fileExists(atPath: directory.path) else {
      DebugLogger.log("MODEL-MANAGER: Directory does not exist")
      return
    }
    
    if let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) {
      DebugLogger.log("MODEL-MANAGER: Directory contents: \(contents.joined(separator: ", "))")
      
      // Also check subdirectories
      for item in contents {
        let itemPath = directory.appendingPathComponent(item)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: itemPath.path, isDirectory: &isDirectory) && isDirectory.boolValue {
          if let subContents = try? fileManager.contentsOfDirectory(atPath: itemPath.path) {
            DebugLogger.log("MODEL-MANAGER: \(item)/ contents: \(subContents.prefix(20).joined(separator: ", "))")
          }
        }
      }
    } else {
      DebugLogger.log("MODEL-MANAGER: Could not read directory contents")
    }
  }
  
  // MARK: - Delete Model
  func deleteModel(_ type: OfflineModelType) throws {
    guard let modelPath = resolveModelPath(for: type) else {
      throw ModelError.fileError("Model not found in WhisperKit directory")
    }
    
    try fileManager.removeItem(at: modelPath)
    DebugLogger.log("MODEL-MANAGER: Deleted \(type.displayName) from: \(modelPath.path)")
  }
  
  // MARK: - Get Model Size
  func getModelSize(_ type: OfflineModelType) -> Int64? {
    guard let modelPath = resolveModelPath(for: type) else {
      return nil
    }
    
    // Calculate total size of model directory
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
  
  // MARK: - Format Size
  func formatSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

// MARK: - Model Error
enum ModelError: LocalizedError {
  case downloadFailed(String)
  case fileError(String)
  
  var errorDescription: String? {
    switch self {
    case .downloadFailed(let message):
      return "Download failed: \(message)"
    case .fileError(let message):
      return "File error: \(message)"
    }
  }
}

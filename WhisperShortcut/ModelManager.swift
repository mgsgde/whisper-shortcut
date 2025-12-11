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
  
  var displayName: String {
    switch self {
    case .whisperTiny: return "Whisper Tiny"
    case .whisperBase: return "Whisper Base"
    case .whisperSmall: return "Whisper Small"
    case .whisperMedium: return "Whisper Medium"
    }
  }
  
  var estimatedSizeMB: Int {
    switch self {
    case .whisperTiny: return 75
    case .whisperBase: return 140
    case .whisperSmall: return 460
    case .whisperMedium: return 1500
    }
  }
  
  var isRecommended: Bool {
    return self == .whisperBase
  }
  
  // Map to WhisperKit model name
  var whisperKitModelName: String {
    switch self {
    case .whisperTiny: return "tiny"
    case .whisperBase: return "base"
    case .whisperSmall: return "small"
    case .whisperMedium: return "medium"
    }
  }
}

// MARK: - Model Manager
class ModelManager: ObservableObject {
  static let shared = ModelManager()
  
  @Published var downloadingModels: Set<OfflineModelType> = []
  
  private let fileManager = FileManager.default
  
  private init() {}
  
  // MARK: - Resolve Model Path
  func resolveModelPath(for type: OfflineModelType) -> URL? {
    let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let whisperKitDir = appSupportDir.appendingPathComponent("WhisperKit")
    
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
  func isModelAvailable(_ type: OfflineModelType) -> Bool {
    if let modelPath = resolveModelPath(for: type) {
      DebugLogger.log("MODEL-MANAGER: Found \(type.displayName) at: \(modelPath.path)")
      return true
    }
    
    // Debug logging if not found
    let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let whisperKitDir = appSupportDir.appendingPathComponent("WhisperKit")
    
    DebugLogger.log("MODEL-MANAGER: Checking availability for \(type.displayName)")
    DebugLogger.log("MODEL-MANAGER: WhisperKit directory: \(whisperKitDir.path)")
    
    if fileManager.fileExists(atPath: whisperKitDir.path) {
      if let contents = try? fileManager.contentsOfDirectory(atPath: whisperKitDir.path) {
        DebugLogger.log("MODEL-MANAGER: WhisperKit directory contents: \(contents.joined(separator: ", "))")
      }
    }
    
    return false
  }
  
  // MARK: - Download Model
  func downloadModel(_ type: OfflineModelType) async throws {
    // Add model to downloading set on main actor
    await MainActor.run {
      downloadingModels.insert(type)
    }
    
    // Use defer to ensure we always remove from downloading set, even on error
    defer {
      Task { @MainActor in
        downloadingModels.remove(type)
      }
    }
    
    // WhisperKit handles downloads automatically
    // This method triggers model initialization which will download if needed
    DebugLogger.log("MODEL-MANAGER: Triggering WhisperKit model download for \(type.displayName)")
    
    // Set explicit modelFolder so we know where models are stored
    let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let whisperKitDir = appSupportDir.appendingPathComponent("WhisperKit")
    let modelFolderPath = whisperKitDir.path
    
    // Ensure the directory exists
    try? fileManager.createDirectory(at: whisperKitDir, withIntermediateDirectories: true)
    
    DebugLogger.log("MODEL-MANAGER: Using modelFolder: \(modelFolderPath)")
    
    // Clean up any incomplete/corrupted downloads first
    await cleanupIncompleteDownloads(type: type, whisperKitDir: whisperKitDir)
    
    // Use the expected model name format for WhisperKit
    let modelName = "openai_whisper-\(type.whisperKitModelName)"
    
    do {
      DebugLogger.log("MODEL-MANAGER: Starting download for \(modelName)...")
      
      // Try to use explicit download method if available
      // This ensures files are downloaded before we try to initialize
      let downloadedModelPath = try await WhisperKit.download(
        variant: modelName,
        downloadBase: whisperKitDir
      )
      
      DebugLogger.log("MODEL-MANAGER: Download completed to: \(downloadedModelPath.path)")
      
      // Now initialize to verify it works
      // Use the actual path where the model was downloaded
      // WhisperKit.download returns the full path to the model directory
      let config = WhisperKitConfig(
        modelFolder: downloadedModelPath.path
      )
      
      DebugLogger.log("MODEL-MANAGER: Initializing WhisperKit with downloaded model at \(downloadedModelPath.path)...")
      let whisperKit = try await WhisperKit(config)
      
      // Verify WhisperKit initialized successfully
      guard whisperKit != nil else {
        throw ModelError.downloadFailed("WhisperKit initialization returned nil")
      }
      
      // Verify the model is actually available on disk
      let isAvailable = isModelAvailable(type)
      DebugLogger.log("MODEL-MANAGER: Model availability check after download: \(isAvailable)")
      
      if !isAvailable {
        logDirectoryContents(whisperKitDir)
        throw ModelError.downloadFailed("Model downloaded but not properly available. Please try downloading again.")
      }
      
      DebugLogger.logSuccess("MODEL-MANAGER: WhisperKit model \(type.displayName) is ready")
    } catch let error as ModelError {
      // Re-throw our custom errors
      throw error
    } catch {
      // Log the full error for debugging
      let errorMessage = error.localizedDescription
      DebugLogger.logError("MODEL-MANAGER: WhisperKit error: \(errorMessage)")
      
      // Check if it's the MelSpectrogram error specifically
      if errorMessage.contains("MelSpectrogram.mlmodelc") {
        DebugLogger.logError("MODEL-MANAGER: MelSpectrogram.mlmodelc missing - this indicates an incomplete download")
        logDirectoryContents(whisperKitDir)
        
        // Provide helpful error message
        throw ModelError.downloadFailed(
          "Model download appears incomplete. The MelSpectrogram.mlmodelc file is missing. " +
          "This usually means the download was interrupted or failed. " +
          "Please try downloading again. If the problem persists, try deleting any partial downloads first."
        )
      }
      
      if let nsError = error as NSError? {
        DebugLogger.logError("MODEL-MANAGER: Error domain: \(nsError.domain), code: \(nsError.code)")
        DebugLogger.logError("MODEL-MANAGER: Error userInfo: \(nsError.userInfo)")
      }
      
      throw ModelError.downloadFailed("Failed to download/initialize WhisperKit: \(errorMessage)")
    }
  }
  
  // MARK: - Cleanup Incomplete Downloads
  private func cleanupIncompleteDownloads(type: OfflineModelType, whisperKitDir: URL) async {
    // Try different possible model naming conventions
    let possibleModelNames = [
      "openai_whisper-\(type.whisperKitModelName)",
      "\(type.whisperKitModelName)",
      "whisper-\(type.whisperKitModelName)",
    ]
    
    for modelName in possibleModelNames {
      let modelPath = whisperKitDir.appendingPathComponent(modelName)
      if fileManager.fileExists(atPath: modelPath.path) {
        // Check if model directory is incomplete (missing key files)
        if !verifyModelFiles(type: type, whisperKitDir: whisperKitDir) {
          DebugLogger.log("MODEL-MANAGER: Found incomplete download for \(modelName), cleaning up...")
          try? fileManager.removeItem(at: modelPath)
        }
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

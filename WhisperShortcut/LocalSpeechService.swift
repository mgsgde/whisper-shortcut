//
//  LocalSpeechService.swift
//  WhisperShortcut
//
//  Offline speech-to-text using Whisper.cpp via SwiftWhisper
//

import Foundation
import AVFoundation
import WhisperKit

actor LocalSpeechService {
  static let shared = LocalSpeechService()
  
  private var whisperKit: WhisperKit?
  private var currentModelType: OfflineModelType?
  
  private init() {}
  
  // MARK: - Initialize Model
  func initializeModel(_ modelType: OfflineModelType) async throws {
    // Check if already initialized with the same model
    if let current = currentModelType, current == modelType, whisperKit != nil {
      DebugLogger.log("LOCAL-SPEECH: Model \(modelType.displayName) already loaded")
      return
    }

    DebugLogger.log("LOCAL-SPEECH: Initializing WhisperKit model: \(modelType.displayName)")
    
    // Unload previous model if exists
    if whisperKit != nil {
      unloadModel()
    }
    
    // Resolve the actual model path using ModelManager
    guard let modelPath = ModelManager.shared.resolveModelPath(for: modelType) else {
      DebugLogger.logError("LOCAL-SPEECH: Model path not found for \(modelType.displayName)")
      throw TranscriptionError.modelNotAvailable(modelType)
    }
    
    DebugLogger.log("LOCAL-SPEECH: Using model path: \(modelPath.path)")
    
    // Initialize WhisperKit with the specific model folder
    let config = WhisperKitConfig(
      modelFolder: modelPath.path
    )
    
    do {
      whisperKit = try await WhisperKit(config)
      currentModelType = modelType
      DebugLogger.logSuccess("LOCAL-SPEECH: Model initialized successfully")
    } catch {
      // Check if error is related to missing or incomplete model files
      let errorMessage = error.localizedDescription
      DebugLogger.logError("LOCAL-SPEECH: WhisperKit initialization failed: \(errorMessage)")
      
      // Check for common model-related errors
      let lowercasedError = errorMessage.lowercased()
      if lowercasedError.contains("mil network") ||
         lowercasedError.contains("mlmodelc") ||
         lowercasedError.contains("model") && (lowercasedError.contains("not found") || lowercasedError.contains("missing") || lowercasedError.contains("read")) {
        // This is a model availability issue
        DebugLogger.logError("LOCAL-SPEECH: Model appears to be missing or incomplete")
        throw TranscriptionError.modelNotAvailable(modelType)
      }
      
      // For other errors, wrap in fileError with more context
      throw TranscriptionError.fileError("Failed to load model: \(errorMessage). The model may be incomplete or corrupted. Please try downloading it again in Settings.")
    }
  }
  
  // MARK: - Unload Model
  func unloadModel() {
    DebugLogger.log("LOCAL-SPEECH: Unloading model")
    whisperKit = nil
    currentModelType = nil
  }
  
  // MARK: - Transcribe Audio
  func transcribe(audioURL: URL, language: String? = nil) async throws -> String {
    let transcribeStartTime = CFAbsoluteTimeGetCurrent()
    
    guard let whisperKit = whisperKit else {
      throw TranscriptionError.fileError("WhisperKit not initialized")
    }
    
    guard currentModelType != nil else {
      throw TranscriptionError.fileError("No model initialized")
    }
    
    DebugLogger.log("LOCAL-SPEECH: Starting transcription")
    DebugLogger.log("LOCAL-SPEECH: Audio file: \(audioURL.path)")
    if let language = language {
      DebugLogger.log("LOCAL-SPEECH: Language specified: \(language)")
    } else {
      DebugLogger.log("LOCAL-SPEECH: Language: auto-detect")
    }
    
    // Validate audio file
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
      throw TranscriptionError.fileError("Audio file not found")
    }
    
    // Get audio duration for reference
    do {
      let audioFile = try AVAudioFile(forReading: audioURL)
      let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
      DebugLogger.log("LOCAL-SPEECH: Audio duration: \(String(format: "%.2f", duration))s")
    } catch {
      DebugLogger.log("LOCAL-SPEECH: Could not determine audio duration")
    }
    
    // Transcribe using WhisperKit with DecodingOptions
    // Configure options to skip special tokens and use specified language
    var decodeOptions = DecodingOptions(skipSpecialTokens: true)
    
    if let language = language {
      decodeOptions = DecodingOptions(language: language, skipSpecialTokens: true)
    }
    
    // Use the correct API signature: audioPath: String, decodeOptions: DecodingOptions?
    // We use the return value for the final text to avoid duplication issues in the callback
    let transcriptionResults: [TranscriptionResult]
    let whisperKitStartTime = CFAbsoluteTimeGetCurrent()
    do {
      transcriptionResults = try await whisperKit.transcribe(
        audioPath: audioURL.path,
        decodeOptions: decodeOptions
      ) { progress in
        // Optional: Log progress if needed, but don't accumulate text here for the final result
        // to avoid "This ... This is ... This is a ..." duplication patterns
        return true // Continue processing
      }
      let whisperKitTime = CFAbsoluteTimeGetCurrent() - whisperKitStartTime
      DebugLogger.log("SPEED: WhisperKit transcribe call took \(String(format: "%.3f", whisperKitTime))s (\(String(format: "%.0f", whisperKitTime * 1000))ms)")
    } catch {
      // Check if error is related to missing or incomplete model files
      let errorMessage = error.localizedDescription
      DebugLogger.logError("LOCAL-SPEECH: Transcription failed: \(errorMessage)")
      
      // Check for common model-related errors
      let lowercasedError = errorMessage.lowercased()
      if lowercasedError.contains("mil network") ||
         lowercasedError.contains("mlmodelc") ||
         lowercasedError.contains("model") && (lowercasedError.contains("not found") || lowercasedError.contains("missing") || lowercasedError.contains("read") || lowercasedError.contains("load")) {
        // This is a model availability issue
        DebugLogger.logError("LOCAL-SPEECH: Model appears to be missing or incomplete during transcription")
        if let modelType = currentModelType {
          throw TranscriptionError.modelNotAvailable(modelType)
        } else {
          throw TranscriptionError.fileError("Model is missing or incomplete. Please download it in Settings.")
        }
      }
      
      // For other errors, re-throw as fileError with context
      throw TranscriptionError.fileError("Transcription failed: \(errorMessage). The model may be incomplete or corrupted. Please try downloading it again in Settings.")
    }
    
    // Combine all segments into a single text
    guard !transcriptionResults.isEmpty else {
      throw TranscriptionError.fileError("No transcription result")
    }
    
    // Extract text from all segments
    let text = transcriptionResults.map { $0.text }.joined(separator: " ")
    
    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(text)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "LOCAL-SPEECH")
    
    let totalElapsedTime = CFAbsoluteTimeGetCurrent() - transcribeStartTime
    DebugLogger.logSuccess("LOCAL-SPEECH: Transcription completed")
    DebugLogger.log("SPEED: Whisper transcription total time: \(String(format: "%.3f", totalElapsedTime))s (\(String(format: "%.0f", totalElapsedTime * 1000))ms)")
    
    return normalizedText
  }
  
  // MARK: - Check if Model is Ready
  func isReady() -> Bool {
    return currentModelType != nil && whisperKit != nil
  }
  
  // MARK: - Get Current Model Info
  func getCurrentModelInfo() -> String? {
    return currentModelType?.displayName
  }
}

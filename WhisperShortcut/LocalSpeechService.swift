//
//  LocalSpeechService.swift
//  WhisperShortcut
//
//  Offline speech-to-text using Whisper.cpp via SwiftWhisper
//

import Foundation
import AVFoundation
import WhisperKit

class LocalSpeechService {
  static let shared = LocalSpeechService()
  
  private var whisperKit: WhisperKit?
  private var currentModelType: OfflineModelType?
  
  private init() {}
  
  // MARK: - Initialize Model
  func initializeModel(_ modelType: OfflineModelType) async throws {
    DebugLogger.log("LOCAL-SPEECH: Initializing WhisperKit model: \(modelType.displayName)")
    
    // Resolve the actual model path using ModelManager
    guard let modelPath = ModelManager.shared.resolveModelPath(for: modelType) else {
      DebugLogger.logError("LOCAL-SPEECH: Model path not found for \(modelType.displayName)")
      throw TranscriptionError.fileError("Model not found. Please download it first in Settings.")
    }
    
    DebugLogger.log("LOCAL-SPEECH: Using model path: \(modelPath.path)")
    
    // Initialize WhisperKit with the specific model folder
    let config = WhisperKitConfig(
      modelFolder: modelPath.path
    )
    
    whisperKit = try await WhisperKit(config)
    currentModelType = modelType
    
    DebugLogger.logSuccess("LOCAL-SPEECH: Model initialized successfully")
  }
  
  // MARK: - Transcribe Audio
  func transcribe(audioURL: URL, language: String? = nil) async throws -> String {
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
    
    // Transcribe using WhisperKit with DecodingOptions
    // Configure options to skip special tokens and use specified language
    var decodeOptions = DecodingOptions(skipSpecialTokens: true)
    
    if let language = language {
      decodeOptions = DecodingOptions(language: language, skipSpecialTokens: true)
    }
    
    // Use the correct API signature: audioPath: String, decodeOptions: DecodingOptions?
    // We use the return value for the final text to avoid duplication issues in the callback
    let transcriptionResults = try await whisperKit.transcribe(
      audioPath: audioURL.path,
      decodeOptions: decodeOptions
    ) { progress in
      // Optional: Log progress if needed, but don't accumulate text here for the final result
      // to avoid "This ... This is ... This is a ..." duplication patterns
      return true // Continue processing
    }
    
    // Combine all segments into a single text
    guard !transcriptionResults.isEmpty else {
      throw TranscriptionError.fileError("No transcription result")
    }
    
    // Extract text from all segments
    let text = transcriptionResults.map { $0.text }.joined(separator: " ")
    
    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(text)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "LOCAL-SPEECH")
    
    DebugLogger.logSuccess("LOCAL-SPEECH: Transcription completed")
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

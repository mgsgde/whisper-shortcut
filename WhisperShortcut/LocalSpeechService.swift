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
  func transcribe(audioURL: URL, language: String? = nil, prompt: String? = nil) async throws -> String {
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
    
    // Build promptTokens from dictation prompt if available
    let promptTokens: [Int]? = buildPromptTokens(prompt: prompt, whisperKit: whisperKit)
    let usedPrompt = promptTokens != nil && !(promptTokens!.isEmpty)
    
    // Build DecodingOptions
    // When language is nil we want auto-detect: must set detectLanguage: true explicitly,
    // because DecodingOptions defaults detectLanguage to !usePrefillPrompt (false when prefill is true).
    let decodeOptions = buildDecodingOptions(language: language, promptTokens: promptTokens)
    
    // Transcribe (with fallback retry if prompt causes empty result)
    var transcriptionResults = try await performWhisperTranscription(
      whisperKit: whisperKit, audioURL: audioURL, decodeOptions: decodeOptions
    )
    
    // Fallback: if prompt was used and result is empty, retry without prompt (WhisperKit #372)
    if usedPrompt && isEmptyResult(transcriptionResults) {
      DebugLogger.logWarning("LOCAL-SPEECH: Prompt caused empty result; retrying without prompt")
      let fallbackOptions = buildDecodingOptions(language: language, promptTokens: nil)
      transcriptionResults = try await performWhisperTranscription(
        whisperKit: whisperKit, audioURL: audioURL, decodeOptions: fallbackOptions
      )
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
    DebugLogger.logSpeech("SPEED: Whisper transcription total time: \(String(format: "%.3f", totalElapsedTime))s (\(String(format: "%.0f", totalElapsedTime * 1000))ms)")
    
    return normalizedText
  }
  
  // MARK: - Prompt Token Building
  
  /// Encodes the dictation prompt into token IDs suitable for Whisper's promptTokens,
  /// filtering out special tokens and truncating to 224 (Whisper's effective limit).
  private func buildPromptTokens(prompt: String?, whisperKit: WhisperKit) -> [Int]? {
    guard let promptText = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
          !promptText.isEmpty else {
      DebugLogger.log("LOCAL-SPEECH: No Whisper glossary sent (prompt empty)")
      return nil
    }
    
    guard let tokenizer = whisperKit.tokenizer else {
      DebugLogger.logWarning("LOCAL-SPEECH: No Whisper glossary sent (tokenizer not available)")
      return nil
    }
    
    let encoded = tokenizer.encode(text: promptText)
    let filtered = encoded.filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    let maxPromptTokens = 224
    let truncated = Array(filtered.prefix(maxPromptTokens))
    
    if truncated.isEmpty {
      DebugLogger.log("LOCAL-SPEECH: No Whisper glossary sent (encoded prompt empty after filter)")
      return nil
    }
    
    if filtered.count > maxPromptTokens {
      DebugLogger.log("LOCAL-SPEECH: Whisper glossary truncated from \(filtered.count) to \(maxPromptTokens) tokens")
    }
    let previewLen = 80
    let preview = promptText.count <= previewLen
      ? promptText
      : String(promptText.prefix(previewLen)).trimmingCharacters(in: .whitespaces) + "..."
    DebugLogger.log("LOCAL-SPEECH: Whisper glossary sent as conditioning prompt (\(truncated.count) tokens). Preview: \"\(preview)\"")
    
    return truncated
  }
  
  // MARK: - DecodingOptions Builder
  
  private func buildDecodingOptions(language: String?, promptTokens: [Int]?) -> DecodingOptions {
    if let language = language {
      return DecodingOptions(
        language: language,
        skipSpecialTokens: true,
        promptTokens: promptTokens
      )
    } else {
      return DecodingOptions(
        language: nil,
        detectLanguage: true,
        skipSpecialTokens: true,
        promptTokens: promptTokens
      )
    }
  }
  
  // MARK: - WhisperKit Transcription Call
  
  private func performWhisperTranscription(
    whisperKit: WhisperKit,
    audioURL: URL,
    decodeOptions: DecodingOptions
  ) async throws -> [TranscriptionResult] {
    let whisperKitStartTime = CFAbsoluteTimeGetCurrent()
    do {
      let results = try await whisperKit.transcribe(
        audioPath: audioURL.path,
        decodeOptions: decodeOptions
      ) { _ in
        return true
      }
      let whisperKitTime = CFAbsoluteTimeGetCurrent() - whisperKitStartTime
      DebugLogger.logSpeech("SPEED: WhisperKit transcribe call took \(String(format: "%.3f", whisperKitTime))s (\(String(format: "%.0f", whisperKitTime * 1000))ms)")
      return results
    } catch {
      let errorMessage = error.localizedDescription
      DebugLogger.logError("LOCAL-SPEECH: Transcription failed: \(errorMessage)")
      
      let lowercasedError = errorMessage.lowercased()
      if lowercasedError.contains("mil network") ||
         lowercasedError.contains("mlmodelc") ||
         lowercasedError.contains("model") && (lowercasedError.contains("not found") || lowercasedError.contains("missing") || lowercasedError.contains("read") || lowercasedError.contains("load")) {
        DebugLogger.logError("LOCAL-SPEECH: Model appears to be missing or incomplete during transcription")
        if let modelType = currentModelType {
          throw TranscriptionError.modelNotAvailable(modelType)
        } else {
          throw TranscriptionError.fileError("Model is missing or incomplete. Please download it in Settings.")
        }
      }
      
      throw TranscriptionError.fileError("Transcription failed: \(errorMessage). The model may be incomplete or corrupted. Please try downloading it again in Settings.")
    }
  }
  
  private func isEmptyResult(_ results: [TranscriptionResult]) -> Bool {
    results.isEmpty || results.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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

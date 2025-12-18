//
//  TextProcessingUtility.swift
//  WhisperShortcut
//
//  Shared text processing utilities for transcription normalization and validation
//

import Foundation

// MARK: - Text Processing Utility
enum TextProcessingUtility {
  
  // MARK: - Text Normalization
  static func normalizeTranscriptionText(_ text: String) -> String {
    // Remove excessive whitespace and normalize line breaks
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Preserve line breaks: normalize multiple spaces/tabs to single space, but keep newlines
    // Step 1: Normalize multiple consecutive newlines to max 2
    let normalizedNewlines = trimmed.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    
    // Step 2: Normalize spaces/tabs within each line (but preserve newlines)
    // Split by newlines, normalize each line, then rejoin
    let lines = normalizedNewlines.components(separatedBy: "\n")
    let normalizedLines = lines.map { line in
      // Replace multiple consecutive spaces/tabs with single space
      line.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }
    let normalized = normalizedLines.joined(separator: "\n")
    
    // Additional cleanup to remove potential prompt remnants
    let cleaned = cleanTranscriptionText(normalized)
    
    return cleaned
  }
  
  // MARK: - Text Cleaning
  private static func cleanTranscriptionText(_ text: String) -> String {
    var cleaned = text
    let originalLength = cleaned.count
    
    // Remove common prompt remnants that might appear at the beginning
    let promptPrefixes = [
      "convert speech to",
      "clean text with",
      "proper punctuation",
      "transcribe this audio",
      "please transcribe",
      "transcription:",
      "audio transcription:",
      "here is the transcription:",
      "the transcription is:",
      "transcribed text:",
      "the audio says:"
    ]
    
    let lowercasedText = cleaned.lowercased()
    for prefix in promptPrefixes {
      if lowercasedText.hasPrefix(prefix) {
        DebugLogger.log("PROMPT-CLEANUP: Removed prefix: '\(prefix)' from transcription")
        cleaned = String(cleaned.dropFirst(prefix.count))
        break
      }
    }
    
    // Remove common prompt remnants that might appear at the end
    let promptSuffixes = [
      "with proper punctuation",
      "clean text with",
      "keep only the intended meaning",
      "remove filler words",
      "preserve correct punctuation",
      "numbers should be written as digits"
    ]
    
    for suffix in promptSuffixes {
      if lowercasedText.hasSuffix(suffix) {
        DebugLogger.log("PROMPT-CLEANUP: Removed suffix: '\(suffix)' from transcription")
        cleaned = String(cleaned.dropLast(suffix.count))
        break
      }
    }
    
    // Clean up any remaining whitespace
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    
    if cleaned.count != originalLength {
      DebugLogger.log("PROMPT-CLEANUP: Text cleaned: \(originalLength) -> \(cleaned.count) characters")
    }
    
    return cleaned
  }
  
  // MARK: - Text Validation
  static func validateSpeechText(_ text: String, mode: String = "TRANSCRIPTION-MODE") throws {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Debug logging to see what Whisper actually returned
    DebugLogger.log("VALIDATION: Received text from \(mode) (length: \(trimmedText.count)): '\(trimmedText)'")
    
    if trimmedText.isEmpty || trimmedText.count < AppConstants.minimumTextLength {
      throw TranscriptionError.textTooShort
    }
    
    // Enhanced prompt detection - check for various prompt patterns
    let defaultPrompt = AppConstants.defaultTranscriptionSystemPrompt
    let lowercasedText = trimmedText.lowercased()
    
    // Check for exact prompt match
    if trimmedText.contains(defaultPrompt) {
      throw TranscriptionError.promptLeakDetected
    }
    
    // Check for partial prompt patterns that might appear in transcription
    let promptKeywords = [
      "convert speech to",
      "clean text with",
      "proper punctuation",
      "transcribe this audio",
      "remove filler words",
      "disfluencies"
    ]
    
    let promptKeywordCount = promptKeywords.filter { lowercasedText.contains($0) }.count
    
    // If more than 2 prompt keywords are found, likely a prompt leak
    if promptKeywordCount > 2 {
      DebugLogger.log("PROMPT-DETECTION: Detected prompt leak in transcription: \(promptKeywordCount) keywords found")
      throw TranscriptionError.promptLeakDetected
    }
    
    // Check for context prefix
    if trimmedText.hasPrefix("context:") {
      throw TranscriptionError.promptLeakDetected
    }
    
    // Check for system-like responses that might be prompt echoes
    let systemPatterns = [
      "here is the transcription",
      "transcription:",
      "audio transcription:",
      "transcribed text:",
      "the audio says:",
      "the transcription is:"
    ]
    
    let systemPatternCount = systemPatterns.filter { lowercasedText.hasPrefix($0) }.count
    if systemPatternCount > 0 {
      DebugLogger.log("PROMPT-DETECTION: Detected system pattern in transcription: \(systemPatterns.filter { lowercasedText.hasPrefix($0) }.first ?? "unknown")")
      throw TranscriptionError.promptLeakDetected
    }
  }
  
  // Text validation uses AppConstants.minimumTextLength
}


//
//  AppState.swift
//  WhisperShortcut
//
//  Unified, elegant state management for the entire application
//

import Foundation

// MARK: - Unified Application State
/// A single, comprehensive state enum that handles all application states
/// including business logic, UI state, and visual feedback
enum AppState: Equatable {
  case idle
  case recording(RecordingMode)
  case processing(ProcessingMode)
  case feedback(FeedbackMode)

  // MARK: - Recording States
  enum RecordingMode: Equatable {
    case transcription
    case prompt
    case tts

    var icon: String {
      switch self {
      case .transcription: return "🔴"
      case .prompt: return "🤖"
      case .tts: return "🔊"
      }
    }

    var statusText: String {
      switch self {
      case .transcription: return "🔴 Recording for transcription..."
      case .prompt: return "🔴 Recording for AI prompt..."
      case .tts: return "🔊 Recording voice command..."
      }
    }

    var tooltip: String {
      switch self {
      case .transcription: return "Recording for transcription... Click to stop"
      case .prompt: return "Recording for AI prompt... Click to stop"
      case .tts: return "Recording voice command... Click to stop or wait"
      }
    }
  }

  // MARK: - Processing States
  enum ProcessingMode: Equatable {
    case transcribing
    case prompting
    case ttsProcessing

    // Chunking-specific states for long audio
    case splitting                                        // Splitting audio into chunks
    case processingChunks(completed: Int, total: Int)     // Processing chunk X/Y
    case merging                                          // Merging transcription results

    var icon: String {
      switch self {
      case .splitting: return "✂️"
      case .merging: return "🔗"
      default: return "⏳"
      }
    }

    var shouldBlink: Bool { return true }

    var statusText: String {
      switch self {
      case .transcribing: return "⏳ Transcribing audio..."
      case .prompting: return "⏳ Processing AI prompt..."
      case .ttsProcessing: return "⏳ Processing text-to-speech..."
      case .splitting: return "✂️ Splitting audio into chunks..."
      case .processingChunks(let completed, let total):
        return "⏳ Processing chunk \(completed)/\(total)..."
      case .merging: return "🔗 Merging transcription..."
      }
    }

    var tooltip: String {
      switch self {
      case .transcribing: return "Transcribing audio... Please wait"
      case .prompting: return "Processing AI prompt... Please wait"
      case .ttsProcessing: return "Processing text-to-speech... Please wait"
      case .splitting: return "Audio is long - splitting into chunks for processing..."
      case .processingChunks(let completed, let total):
        return "Processing chunk \(completed) of \(total)... Please wait"
      case .merging: return "All chunks complete - merging results..."
      }
    }
  }

  // MARK: - Feedback States (Temporary Visual States)
  enum FeedbackMode: Equatable {
    case success(String)
    case error(String)

    var icon: String {
      switch self {
      case .success: return "✅"
      case .error: return "❌"
      }
    }

    var statusText: String {
      switch self {
      case .success(let message): return "✅ \(message)"
      case .error(let message): return "❌ \(message)"
      }
    }

    var tooltip: String {
      switch self {
      case .success(let message): return "Success: \(message)"
      case .error(let message): return "Error: \(message)"
      }
    }

    var duration: TimeInterval {
      switch self {
      case .success: return 2.0
      case .error: return 3.0
      }
    }
  }
}

// MARK: - State Properties
extension AppState {
  /// Current icon to display
  var icon: String {
    switch self {
    case .idle: return "🎙️"
    case .recording(let mode): return mode.icon
    case .processing(let mode): return mode.icon
    case .feedback(let mode): return mode.icon
    }
  }

  /// Current status text for menu
  var statusText: String {
    switch self {
    case .idle: return "Ready to record"
    case .recording(let mode): return mode.statusText
    case .processing(let mode): return mode.statusText
    case .feedback(let mode): return mode.statusText
    }
  }

  /// Current tooltip text
  var tooltip: String {
    switch self {
    case .idle: return "WhisperShortcut - Click to record"
    case .recording(let mode): return mode.tooltip
    case .processing(let mode): return mode.tooltip
    case .feedback(let mode): return mode.tooltip
    }
  }

  /// Whether the icon should blink
  var shouldBlink: Bool {
    switch self {
    case .processing(let mode): return mode.shouldBlink
    default: return false
    }
  }

  /// Whether the app is busy (cannot start new recordings)
  var isBusy: Bool {
    switch self {
    case .idle, .feedback: return false
    default: return true
    }
  }

  /// Whether currently recording
  var isRecording: Bool {
    if case .recording = self { return true }
    return false
  }

  /// Whether currently processing
  var isProcessing: Bool {
    if case .processing = self { return true }
    return false
  }

  /// Current recording mode if recording
  var recordingMode: RecordingMode? {
    if case .recording(let mode) = self { return mode }
    return nil
  }
}

// MARK: - State Transitions
extension AppState {
  /// Start recording with specified mode
  func startRecording(_ mode: RecordingMode) -> AppState {
    guard !isBusy else { return self }
    return .recording(mode)
  }

  /// Stop recording and transition to processing
  func stopRecording() -> AppState {
    guard case .recording(let recordingMode) = self else { return self }

    let processingMode: ProcessingMode
    switch recordingMode {
    case .transcription: processingMode = .transcribing
    case .prompt: processingMode = .prompting
    case .tts: processingMode = .ttsProcessing
    }

    return .processing(processingMode)
  }



  /// Show success feedback
  func showSuccess(_ message: String) -> AppState {
    return .feedback(.success(message))
  }

  /// Show error feedback
  func showError(_ message: String) -> AppState {
    return .feedback(.error(message))
  }

  /// Return to idle state
  func finish() -> AppState {
    return .idle
  }

  /// Force return to idle (for error recovery)
  func reset() -> AppState {
    return .idle
  }
}

// MARK: - Menu Enablement Logic
extension AppState {
  /// Whether transcription can be started
  func canStartTranscription(hasAPIKey: Bool, hasOfflineModel: Bool = false) -> Bool {
    return !isBusy && (hasAPIKey || hasOfflineModel)
  }

  /// Whether prompting can be started
  func canStartPrompting(hasAPIKey: Bool, hasOfflineModel: Bool = false) -> Bool {
    return !isBusy && (hasAPIKey || hasOfflineModel)
  }

  /// Whether current recording can be stopped
  var canStopRecording: Bool {
    return isRecording
  }
}

// MARK: - Debug Support
extension AppState: CustomStringConvertible {
  var description: String {
    switch self {
    case .idle: return "idle"
    case .recording(let mode): return "recording(\(mode))"
    case .processing(let mode): return "processing(\(mode))"
    case .feedback(let mode): return "feedback(\(mode))"
    }
  }
}

extension AppState.RecordingMode: CustomStringConvertible {
  var description: String {
    switch self {
    case .transcription: return "transcription"
    case .prompt: return "prompt"
    case .tts: return "tts"
    }
  }
}

extension AppState.ProcessingMode: CustomStringConvertible {
  var description: String {
    switch self {
    case .transcribing: return "transcribing"
    case .prompting: return "prompting"
    case .ttsProcessing: return "ttsProcessing"
    case .splitting: return "splitting"
    case .processingChunks(let completed, let total): return "processingChunks(\(completed)/\(total))"
    case .merging: return "merging"
    }
  }
}

extension AppState.FeedbackMode: CustomStringConvertible {
  var description: String {
    switch self {
    case .success(let msg): return "success(\(msg))"
    case .error(let msg): return "error(\(msg))"
    }
  }
}

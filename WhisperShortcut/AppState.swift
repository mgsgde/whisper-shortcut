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
    case promptImprovement
    case tts
    case liveMeeting

    var icon: String {
      switch self {
      case .transcription: return "🔴"
      case .prompt: return "🤖"
      case .promptImprovement: return "📝"
      case .tts: return "🔊"
      case .liveMeeting: return "📝"
      }
    }

    var statusText: String {
      switch self {
      case .transcription: return "🔴 Recording for transcription..."
      case .prompt: return "🔴 Recording for AI prompt..."
      case .promptImprovement: return "🔴 Recording to improve from voice..."
      case .tts: return "🔊 Recording voice command..."
      case .liveMeeting: return "📝 Live transcription..."
      }
    }

    var tooltip: String {
      switch self {
      case .transcription: return "Recording for transcription... Click to stop"
      case .prompt: return "Recording for AI prompt... Click to stop"
      case .promptImprovement: return "Recording to improve from voice... Click to stop"
      case .tts: return "Recording voice command... Click to stop or wait"
      case .liveMeeting: return "Live meeting transcription... Click menu to stop"
      }
    }
  }

  // MARK: - Processing States
  enum ProcessingMode: Equatable {
    /// Context for chunked processing (splitting/processingChunks/merging) so UI can tell TTS from transcription.
    enum ChunkContext: Equatable {
      case transcription
      case tts
    }

    case transcribing
    case prompting
    case promptImprovement
    case ttsProcessing

    // Chunking-specific states for long audio (optional context: TTS vs transcription)
    case splitting(context: ChunkContext = .transcription)
    case processingChunks(statuses: [ChunkStatus], context: ChunkContext = .transcription)
    case merging(context: ChunkContext = .transcription)

    var icon: String {
      switch self {
      case .splitting: return "✂️"
      case .merging: return "🔗"
      default: return "⏳"
      }
    }

    /// True when this processing mode is part of TTS flow (ttsProcessing or chunk phase with TTS context).
    var isTTSContext: Bool {
      switch self {
      case .ttsProcessing: return true
      case .splitting(let ctx), .processingChunks(_, let ctx), .merging(let ctx): return ctx == .tts
      default: return false
      }
    }

    /// Current chunk context when in splitting/processingChunks/merging (or .tts when in ttsProcessing). Used to preserve context when updating state.
    var chunkContext: ChunkContext {
      switch self {
      case .ttsProcessing: return .tts
      case .splitting(let ctx), .processingChunks(_, let ctx), .merging(let ctx): return ctx
      default: return .transcription
      }
    }

    var shouldBlink: Bool { return true }

    // Computed properties for chunk status
    var completedCount: Int {
      if case .processingChunks(let statuses, _) = self {
        return statuses.filter { $0 == .completed }.count
      }
      return 0
    }

    var activeCount: Int {
      if case .processingChunks(let statuses, _) = self {
        return statuses.filter { $0 == .active }.count
      }
      return 0
    }

    var totalCount: Int {
      if case .processingChunks(let statuses, _) = self {
        return statuses.count
      }
      return 0
    }

    var statusText: String {
      switch self {
      case .transcribing: return "⏳ Transcribing audio..."
      case .prompting: return "⏳ Processing AI prompt..."
      case .promptImprovement: return "⏳ Improving from voice..."
      case .ttsProcessing: return "⏳ Processing text-to-speech..."
      case .splitting: return "✂️ Splitting audio into chunks..."
      case .processingChunks(let statuses, _):
        let active = statuses.filter { $0 == .active }.count
        let done = statuses.filter { $0 == .completed }.count
        return "⏳ \(active) processing, \(done)/\(statuses.count) done"
      case .merging: return "🔗 Merging transcription..."
      }
    }

    var tooltip: String {
      switch self {
      case .transcribing: return "Transcribing audio... Please wait"
      case .prompting: return "Processing AI prompt... Please wait"
      case .promptImprovement: return "Improving from your voice... Please wait"
      case .ttsProcessing: return "Processing text-to-speech... Please wait"
      case .splitting: return "Audio is long - splitting into chunks for processing..."
      case .processingChunks(let statuses, _):
        let active = statuses.filter { $0 == .active }.count
        let done = statuses.filter { $0 == .completed }.count
        return "Transcribing [\(done)/\(statuses.count)] - \(active) active"
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
    case .promptImprovement: processingMode = .promptImprovement
    case .tts: processingMode = .ttsProcessing
    case .liveMeeting: processingMode = .transcribing  // Live meeting uses transcribing for chunk processing
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

  /// Return to idle state (use for completion, cancel, or error recovery).
  func finish() -> AppState {
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
    case .promptImprovement: return "promptImprovement"
    case .tts: return "tts"
    case .liveMeeting: return "liveMeeting"
    }
  }
}

extension AppState.ProcessingMode: CustomStringConvertible {
  var description: String {
    switch self {
    case .transcribing: return "transcribing"
    case .prompting: return "prompting"
    case .promptImprovement: return "promptImprovement"
    case .ttsProcessing: return "ttsProcessing"
    case .splitting: return "splitting"
    case .processingChunks(let statuses, _):
      let active = statuses.filter { $0 == .active }.count
      let done = statuses.filter { $0 == .completed }.count
      return "processingChunks(\(done)/\(statuses.count), \(active) active)"
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

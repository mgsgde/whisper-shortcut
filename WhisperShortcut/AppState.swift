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
  case playback(PlaybackMode)
  case feedback(FeedbackMode)

  // MARK: - Recording States
  enum RecordingMode: Equatable {
    case transcription
    case prompt
    case voiceResponse

    var icon: String {
      switch self {
      case .transcription: return "🔴"
      case .prompt: return "🤖"
      case .voiceResponse: return "🔊"
      }
    }

    var statusText: String {
      switch self {
      case .transcription: return "🔴 Recording for transcription..."
      case .prompt: return "🔴 Recording for AI prompt..."
      case .voiceResponse: return "🔴 Recording for voice response..."
      }
    }

    var tooltip: String {
      switch self {
      case .transcription: return "Recording for transcription... Click to stop"
      case .prompt: return "Recording for AI prompt... Click to stop"
      case .voiceResponse: return "Recording for voice response... Click to stop"
      }
    }
  }

  // MARK: - Processing States
  enum ProcessingMode: Equatable {
    case transcribing
    case prompting
    case voiceResponding
    case preparingTTS

    var icon: String { return "⏳" }
    var shouldBlink: Bool { return true }

    var statusText: String {
      switch self {
      case .transcribing: return "⏳ Transcribing audio..."
      case .prompting: return "⏳ Processing AI prompt..."
      case .voiceResponding: return "⏳ Processing voice response..."
      case .preparingTTS: return "⏳ Preparing speech..."
      }
    }

    var tooltip: String {
      switch self {
      case .transcribing: return "Transcribing audio... Please wait"
      case .prompting: return "Processing AI prompt... Please wait"
      case .voiceResponding: return "Processing voice response... Please wait"
      case .preparingTTS: return "Preparing speech... Please wait"
      }
    }
  }

  // MARK: - Playback States
  enum PlaybackMode: Equatable {
    case voiceResponse
    case readingText

    var icon: String { return "🔊" }
    var shouldBlink: Bool { return false }

    var statusText: String {
      switch self {
      case .voiceResponse: return "🔊 Playing voice response..."
      case .readingText: return "🔊 Reading selected text..."
      }
    }

    var tooltip: String {
      switch self {
      case .voiceResponse: return "Playing voice response... Click to stop"
      case .readingText: return "Reading text... Click to stop"
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
    case .playback(let mode): return mode.icon
    case .feedback(let mode): return mode.icon
    }
  }

  /// Current status text for menu
  var statusText: String {
    switch self {
    case .idle: return "Ready to record"
    case .recording(let mode): return mode.statusText
    case .processing(let mode): return mode.statusText
    case .playback(let mode): return mode.statusText
    case .feedback(let mode): return mode.statusText
    }
  }

  /// Current tooltip text
  var tooltip: String {
    switch self {
    case .idle: return "WhisperShortcut - Click to record"
    case .recording(let mode): return mode.tooltip
    case .processing(let mode): return mode.tooltip
    case .playback(let mode): return mode.tooltip
    case .feedback(let mode): return mode.tooltip
    }
  }

  /// Whether the icon should blink
  var shouldBlink: Bool {
    switch self {
    case .processing(let mode): return mode.shouldBlink
    case .playback(let mode): return mode.shouldBlink
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

  /// Whether currently playing audio
  var isPlayingAudio: Bool {
    if case .playback = self { return true }
    return false
  }

  /// Current recording mode if recording
  var recordingMode: RecordingMode? {
    if case .recording(let mode) = self { return mode }
    return nil
  }

  /// Current playback mode if playing
  var playbackMode: PlaybackMode? {
    if case .playback(let mode) = self { return mode }
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
    case .voiceResponse: processingMode = .voiceResponding
    }

    return .processing(processingMode)
  }

  /// Start audio playback
  func startPlayback(_ mode: PlaybackMode) -> AppState {
    return .playback(mode)
  }

  /// Stop audio playback
  func stopPlayback() -> AppState {
    guard case .playback = self else { return self }
    return .idle
  }

  /// Start TTS preparation
  func startTTSPreparation() -> AppState {
    return .processing(.preparingTTS)
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
  func canStartTranscription(hasAPIKey: Bool) -> Bool {
    return !isBusy && hasAPIKey
  }

  /// Whether prompting can be started
  func canStartPrompting(hasAPIKey: Bool) -> Bool {
    return !isBusy && hasAPIKey
  }

  /// Whether voice response can be started
  func canStartVoiceResponse(hasAPIKey: Bool) -> Bool {
    return !isBusy && hasAPIKey
  }

  /// Whether text reading can be started
  func canStartTextReading(hasAPIKey: Bool) -> Bool {
    return !isBusy && hasAPIKey
  }

  /// Whether current recording can be stopped
  var canStopRecording: Bool {
    return isRecording
  }

  /// Whether current playback can be stopped
  var canStopPlayback: Bool {
    return isPlayingAudio
  }
}

// MARK: - Debug Support
extension AppState: CustomStringConvertible {
  var description: String {
    switch self {
    case .idle: return "idle"
    case .recording(let mode): return "recording(\(mode))"
    case .processing(let mode): return "processing(\(mode))"
    case .playback(let mode): return "playback(\(mode))"
    case .feedback(let mode): return "feedback(\(mode))"
    }
  }
}

extension AppState.RecordingMode: CustomStringConvertible {
  var description: String {
    switch self {
    case .transcription: return "transcription"
    case .prompt: return "prompt"
    case .voiceResponse: return "voiceResponse"
    }
  }
}

extension AppState.ProcessingMode: CustomStringConvertible {
  var description: String {
    switch self {
    case .transcribing: return "transcribing"
    case .prompting: return "prompting"
    case .voiceResponding: return "voiceResponding"
    case .preparingTTS: return "preparingTTS"
    }
  }
}

extension AppState.PlaybackMode: CustomStringConvertible {
  var description: String {
    switch self {
    case .voiceResponse: return "voiceResponse"
    case .readingText: return "readingText"
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

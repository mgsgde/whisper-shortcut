//
//  AppMode.swift
//  WhisperShortcut
//
//  Created by AI Assistant
//

import Foundation

// MARK: - Application Mode Management
/// A type-safe, elegant way to manage application states

enum AppMode: Equatable {
  case idle
  case recording(type: RecordingType)
  case processing(type: ProcessingType)

  enum RecordingType: Equatable {
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

    var tooltip: String {
      switch self {
      case .transcription: return "Recording for transcription... Click to stop"
      case .prompt: return "Recording for AI prompt... Click to stop"
      case .voiceResponse: return "Recording for voice response... Click to stop"
      }
    }

    var statusText: String {
      switch self {
      case .transcription: return "🔴 Recording (Transcription)..."
      case .prompt: return "🔴 Recording (Prompt)..."
      case .voiceResponse: return "🔴 Recording (Voice Response)..."
      }
    }
  }

  enum ProcessingType: Equatable {
    case transcribing
    case prompting
    case voiceResponding
    case speaking

    var statusText: String {
      switch self {
      case .transcribing: return "⏳ Transcribing..."
      case .prompting: return "🤖 Processing prompt..."
      case .voiceResponding: return "🔊 Processing voice response..."
      case .speaking: return "🔈 Playing response..."
      }
    }

    var shouldBlink: Bool {
      switch self {
      case .speaking: return false  // No blinking during audio playback
      default: return true
      }
    }

    var icon: String {
      switch self {
      case .speaking: return "🔈"
      default: return "🎙️"
      }
    }
  }
}

// MARK: - Computed Properties for Easier Logic
extension AppMode {
  /// True if currently recording audio
  var isRecording: Bool {
    if case .recording = self { return true }
    return false
  }

  /// True if currently processing (transcribing, prompting, or speaking)
  var isProcessing: Bool {
    if case .processing = self { return true }
    return false
  }

  /// True if app is busy (recording or processing)
  var isBusy: Bool {
    return isRecording || isProcessing
  }

  /// Current recording type, if recording
  var recordingType: RecordingType? {
    if case .recording(let type) = self { return type }
    return nil
  }

  /// Current processing type, if processing
  var processingType: ProcessingType? {
    if case .processing(let type) = self { return type }
    return nil
  }

  /// True if a new recording can be started
  var canStartNewRecording: Bool {
    return self == .idle
  }

  /// Icon to display in menu bar
  var icon: String {
    let iconString: String
    switch self {
    case .idle: 
      iconString = "🎙️"
    case .recording(let type): 
      iconString = type.icon
    case .processing(let type): 
      iconString = type.icon
    }
    NSLog("🎨 UI-DEBUG: AppMode.icon called for \(self) → '\(iconString)'")
    return iconString
  }

  /// Tooltip text for menu bar icon
  var tooltip: String {
    switch self {
    case .idle: return "WhisperShortcut - Click to record"
    case .recording(let type): return type.tooltip
    case .processing: return "Processing..."
    }
  }

  /// Status text for menu items
  var statusText: String {
    switch self {
    case .idle: return "Ready to record"
    case .recording(let type): return type.statusText
    case .processing(let type): return type.statusText
    }
  }

  /// Whether the menu bar icon should blink
  var shouldBlink: Bool {
    if case .processing(let type) = self {
      return type.shouldBlink
    }
    return false
  }
}

// MARK: - State Transitions
extension AppMode {
  /// Start recording with the specified type
  func startRecording(type: RecordingType) -> AppMode {
    guard self == .idle else { return self }
    return .recording(type: type)
  }

  /// Stop recording and transition to appropriate processing state
  func stopRecording() -> AppMode {
    guard case .recording(let type) = self else { return self }

    // Transition to appropriate processing state
    switch type {
    case .transcription: return .processing(type: .transcribing)
    case .prompt: return .processing(type: .prompting)
    case .voiceResponse: return .processing(type: .voiceResponding)
    }
  }

  /// Transition to speaking state (for voice response)
  func startSpeaking() -> AppMode {
    return .processing(type: .speaking)
  }

  /// Finish all processing and return to idle
  func finish() -> AppMode {
    return .idle
  }

  /// Get the last recording type for retry functionality
  var lastRecordingType: RecordingType? {
    switch self {
    case .recording(let type): return type
    case .processing(let processingType):
      // Map processing type back to recording type
      switch processingType {
      case .transcribing: return .transcription
      case .prompting: return .prompt
      case .voiceResponding, .speaking: return .voiceResponse
      }
    case .idle: return nil
    }
  }
}

// MARK: - Menu Item Enablement Logic
extension AppMode {
  /// Whether the "Start Recording" menu item should be enabled
  func shouldEnableStartRecording(hasAPIKey: Bool) -> Bool {
    return canStartNewRecording && hasAPIKey
  }

  /// Whether the "Stop Recording" menu item should be enabled
  var shouldEnableStopRecording: Bool {
    return recordingType == .transcription
  }

  /// Whether the "Start Prompting" menu item should be enabled
  func shouldEnableStartPrompting(hasAPIKey: Bool) -> Bool {
    return canStartNewRecording && hasAPIKey
  }

  /// Whether the "Stop Prompting" menu item should be enabled
  var shouldEnableStopPrompting: Bool {
    return recordingType == .prompt
  }

  /// Whether the "Start Voice Response" menu item should be enabled
  func shouldEnableStartVoiceResponse(hasAPIKey: Bool) -> Bool {
    return canStartNewRecording && hasAPIKey
  }

  /// Whether the "Stop Voice Response" menu item should be enabled
  var shouldEnableStopVoiceResponse: Bool {
    return recordingType == .voiceResponse
  }
}

// MARK: - Debug Description
extension AppMode: CustomStringConvertible {
  var description: String {
    switch self {
    case .idle: return "idle"
    case .recording(let type): return "recording(\(type))"
    case .processing(let type): return "processing(\(type))"
    }
  }
}

extension AppMode.RecordingType: CustomStringConvertible {
  var description: String {
    switch self {
    case .transcription: return "transcription"
    case .prompt: return "prompt"
    case .voiceResponse: return "voiceResponse"
    }
  }
}

extension AppMode.ProcessingType: CustomStringConvertible {
  var description: String {
    switch self {
    case .transcribing: return "transcribing"
    case .prompting: return "prompting"
    case .voiceResponding: return "voiceResponding"
    case .speaking: return "speaking"
    }
  }
}

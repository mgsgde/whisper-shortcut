import Foundation

// MARK: - TTS Playback

/// Typed errors for TTS audio playback (replaces NSError in MenuBarController.playTTSAudio).
enum TTSPlaybackError: Error, LocalizedError {
  case failedToCreateAudioFormat
  case failedToCreateBuffer
  case failedToCreateFloatFormat
  case failedToCreateFloatBuffer

  var errorDescription: String? {
    switch self {
    case .failedToCreateAudioFormat: return "Failed to create audio format"
    case .failedToCreateBuffer: return "Failed to create audio buffer"
    case .failedToCreateFloatFormat: return "Failed to create Float32 format"
    case .failedToCreateFloatBuffer: return "Failed to create Float32 buffer"
    }
  }
}

// MARK: - Live Meeting Recorder

/// Typed errors for live meeting recording (replaces NSError in LiveMeetingRecorder).
enum LiveMeetingRecorderError: Error, LocalizedError {
  case recordingFailed(reason: String)

  var errorDescription: String? {
    switch self {
    case .recordingFailed(let reason): return reason
    }
  }
}

// MARK: - Chunk Failure Message

/// Shared message for chunking failures (audio or text) to avoid duplicated string building.
enum ChunkFailureMessage {
  static func message(context: String, error: Error) -> String {
    "Failed to chunk \(context): \(error.localizedDescription)"
  }
}

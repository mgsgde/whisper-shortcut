import Foundation

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

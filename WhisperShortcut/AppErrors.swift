import Foundation

// MARK: - TTS Playback

/// Typed errors for TTS audio playback (used by MenuBarController.playTTSAudio).
enum TTSPlaybackError: Error, LocalizedError {
  case failedToCreateAudioFormat
  case failedToCreateBuffer
  case noAudioProduced

  var errorDescription: String? {
    switch self {
    case .failedToCreateAudioFormat: return "Failed to create audio format"
    case .failedToCreateBuffer: return "Failed to create audio buffer"
    case .noAudioProduced: return "No audio was generated for this text"
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

// MARK: - Log-safe error text

extension Error {
  /// English, locale-independent text for logs. Logs are grepped by literal English text
  /// (plans/agent-loops.md), so they must never carry a localized `localizedDescription`.
  ///
  /// Choice: system-framework errors (`NSError` with a non-app domain, `URLError`, ...) keep
  /// `"<domain> <code>: <localizedDescription>"` (system strings are fine and the domain/code
  /// stay greppable). The app's own errors use `String(describing:)`, which carries the enum
  /// case name and payload and never changes with the system language, plus the
  /// `errorDescription` when the type provides one.
  var logDescription: String {
    let ns = self as NSError
    if ns.domain == NSCocoaErrorDomain || ns.domain == NSURLErrorDomain
      || ns.domain == NSPOSIXErrorDomain || ns.domain == NSOSStatusErrorDomain
      || ns.domain == "AVFoundationErrorDomain" || ns.domain == "com.apple.coreaudio.avfaudio"
    {
      return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }
    let described = String(describing: self)
    if let described2 = (self as? LocalizedError)?.errorDescription, !described2.isEmpty,
      described2 != described
    {
      return "\(described) (\(described2))"
    }
    return described
  }
}

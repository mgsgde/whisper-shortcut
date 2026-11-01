import AVFoundation
import Foundation

/// The two audio-duration measurements already in the app.
/// AVURLAsset and AVAudioFile disagree on some compressed files, so those call sites keep
/// the reader they had. Recorded PCM WAV uses `secondsForRecordedAudio` (header-only).
enum AudioDuration {

  /// `AVURLAsset.load(.duration)` + `CMTimeGetSeconds`. Throws when the asset cannot be read.
  static func avURLAssetSeconds(_ url: URL) async throws -> TimeInterval {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    return CMTimeGetSeconds(duration)
  }

  /// `Double(file.length) / file.fileFormat.sampleRate`. Throws when the file cannot be opened.
  static func avAudioFileSeconds(_ url: URL) throws -> TimeInterval {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.fileFormat.sampleRate
  }

  /// Duration for audio this app records (PCM WAV / AIFF / CAF): header-only via `AVAudioFile`,
  /// so the stop→upload path does not wait on `AVURLAsset.load(.duration)`. Other containers
  /// still use the asset reader — the two disagree on some compressed files.
  static func secondsForRecordedAudio(_ url: URL) async throws -> TimeInterval {
    switch url.pathExtension.lowercased() {
    case "wav", "aiff", "caf":
      return try avAudioFileSeconds(url)
    default:
      return try await avURLAssetSeconds(url)
    }
  }
}

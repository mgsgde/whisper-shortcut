import AVFoundation
import Foundation

/// The two audio-duration measurements already in the app.
/// AVURLAsset and AVAudioFile disagree on some files, so each call site keeps the one it had.
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

  /// `avAudioFileSeconds` in whole milliseconds, or nil when the file cannot be read or the length
  /// is not a finite, non-negative number. For log fields, where "unknown" beats a guess.
  static func milliseconds(_ url: URL) -> Int? {
    guard let seconds = try? avAudioFileSeconds(url), seconds.isFinite, seconds >= 0 else { return nil }
    return Int((seconds * 1000).rounded())
  }
}

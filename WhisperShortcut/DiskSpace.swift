import Foundation

/// Pre-download and pre-recording disk-space checks.
enum DiskSpace {
  /// Headroom so a 1.6 GB model does not fill a volume that only *looks* large enough.
  static let downloadMargin = 1.2

  /// Throws when `url`'s volume does not have `estimatedSizeMB × 1.2` free for important usage.
  /// If the volume cannot report capacity, the download proceeds rather than blocking setup.
  static func require(estimatedSizeMB: Int, at url: URL) throws {
    try require(estimatedSizeMB: estimatedSizeMB, availableBytes: availableBytes(at: url))
  }

  /// Same check with an injectable free-space figure so tests do not need a real volume.
  static func require(estimatedSizeMB: Int, availableBytes: Int64?) throws {
    let neededBytes = Int64((Double(estimatedSizeMB) * 1_000_000 * downloadMargin).rounded())
    guard let available = availableBytes else { return }
    if available < neededBytes {
      let neededMB = Int((Double(neededBytes) / 1_000_000).rounded(.up))
      let availableMB = Int(available / 1_000_000)
      throw DiskSpaceError.insufficient(neededMB: neededMB, availableMB: availableMB)
    }
  }

  /// Enough free space to start a dictation or meeting recording. Unknown capacity is treated
  /// as OK — same as the download path — so a volume that cannot report usage does not block.
  static func requireForRecording(at url: URL) throws {
    try requireForRecording(availableBytes: availableBytes(at: url))
  }

  static func requireForRecording(availableBytes: Int64?) throws {
    guard let available = availableBytes else { return }
    let neededBytes = Int64(RecordingRobustness.recordingReserveMB) * 1_000_000
    if available < neededBytes {
      throw DiskSpaceError.insufficientForRecording(
        neededMB: RecordingRobustness.recordingReserveMB,
        availableMB: Int(available / 1_000_000))
    }
  }

  /// True when the next write is likely to fail. Unknown capacity is not treated as low.
  static func isCriticallyLow(at url: URL) -> Bool {
    isCriticallyLow(availableBytes: availableBytes(at: url))
  }

  static func isCriticallyLow(availableBytes: Int64?) -> Bool {
    guard let available = availableBytes else { return false }
    return available < Int64(RecordingRobustness.criticalReserveMB) * 1_000_000
  }

  static func availableBytes(at url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }
}

enum DiskSpaceError: LocalizedError {
  case insufficient(neededMB: Int, availableMB: Int)
  case insufficientForRecording(neededMB: Int, availableMB: Int)

  var errorDescription: String? {
    switch self {
    case .insufficient(let neededMB, let availableMB):
      return String(localized: "Not enough disk space to download this model. About \(neededMB) MB is needed, but only \(availableMB) MB is free. Free some space and try again.")
    case .insufficientForRecording(let neededMB, let availableMB):
      return String(localized: "Not enough disk space to start a recording. About \(neededMB) MB should be free, but only \(availableMB) MB is available. Free some space and try again.")
    }
  }
}

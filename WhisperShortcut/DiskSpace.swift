import Foundation

/// Pre-download disk-space check shared by Whisper and MLX downloads.
enum DiskSpace {
  /// Headroom so a 1.6 GB model does not fill a volume that only *looks* large enough.
  static let downloadMargin = 1.2

  /// Throws when `url`'s volume does not have `estimatedSizeMB × 1.2` free for important usage.
  /// If the volume cannot report capacity, the download proceeds rather than blocking setup;
  /// an important-usage value <= 0 (VMs, system purging) is unreliable and falls back to the plain capacity.
  static func require(estimatedSizeMB: Int, at url: URL) throws {
    let neededBytes = Int64((Double(estimatedSizeMB) * 1_000_000 * downloadMargin).rounded())
    // Test profile only (`TestProfileOverrides`, `--disk-full`).
    if TestProfileOverrides.current.diskFull {
      throw DiskSpaceError.insufficient(
        neededMB: Int((Double(neededBytes) / 1_000_000).rounded(.up)), availableMB: 312)
    }
    let values = try? url.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ])
    try check(
      neededBytes: neededBytes,
      importantUsage: values?.volumeAvailableCapacityForImportantUsage,
      plain: values?.volumeAvailableCapacity)
  }

  /// Pure comparison behind `require`: prefers `importantUsage` when > 0, else `plain`; proceeds if neither is known.
  static func check(neededBytes: Int64, importantUsage: Int64?, plain: Int?) throws {
    let available: Int64
    if let importantUsage, importantUsage > 0 {
      available = importantUsage
    } else if let plain {
      available = Int64(plain)
    } else {
      return
    }
    if available < neededBytes {
      let neededMB = Int((Double(neededBytes) / 1_000_000).rounded(.up))
      let availableMB = Int(available / 1_000_000)
      throw DiskSpaceError.insufficient(neededMB: neededMB, availableMB: availableMB)
    }
  }
}

enum DiskSpaceError: LocalizedError {
  case insufficient(neededMB: Int, availableMB: Int)

  var errorDescription: String? {
    switch self {
    case .insufficient(let neededMB, let availableMB):
      return String(localized: "Not enough disk space to download this model. About \(neededMB) MB is needed, but only \(availableMB) MB is free. Free some space and try again.")
    }
  }
}

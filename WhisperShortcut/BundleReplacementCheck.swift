import Foundation

/// Whether the app bundle on disk is a different version than the one this process launched
/// with. `runningVersion` and `runningBuild` are `static let`s, so they are filled on first
/// touch (from `currentMismatch()`). That is still the launch value: `Bundle.main.infoDictionary`
/// is cached for the life of the process, so the laziness does not re-read a replaced bundle.
enum BundleReplacementCheck {
  static let runningVersion: String? =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
  static let runningBuild: String? =
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String

  /// True only when both on-disk values could be read and version or build differs from the
  /// running process. A nil on-disk value means the plist could not be read, which is not a
  /// detected replacement.
  static func isReplaced(
    runningVersion: String?, runningBuild: String?,
    onDiskVersion: String?, onDiskBuild: String?
  ) -> Bool {
    guard let onDiskVersion, let onDiskBuild else { return false }
    return runningVersion != onDiskVersion || runningBuild != onDiskBuild
  }

  /// `"version (build)"` for the running process and the bundle on disk, when they differ.
  /// The on-disk plist is read fresh; `Bundle.main` is not.
  static func currentMismatch() -> (running: String, onDisk: String)? {
    let plistURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
    let onDisk = NSDictionary(contentsOf: plistURL)
    let onDiskVersion = onDisk?["CFBundleShortVersionString"] as? String
    let onDiskBuild = onDisk?["CFBundleVersion"] as? String
    guard
      let onDiskVersion, let onDiskBuild,
      isReplaced(
        runningVersion: runningVersion, runningBuild: runningBuild,
        onDiskVersion: onDiskVersion, onDiskBuild: onDiskBuild)
    else { return nil }
    return (
      running: "\(runningVersion ?? "?") (\(runningBuild ?? "?"))",
      onDisk: "\(onDiskVersion) (\(onDiskBuild))")
  }
}

import Foundation

/// Channels on the single Sparkle appcast (`AppConstants.sparkleFeedURL`).
/// An item tagged `<sparkle:channel>latest</sparkle:channel>` is visible only when that
/// channel is allowed. Untagged items are visible to every client, including copies that
/// do not understand channels, so Stable is the untagged items and needs no bootstrap.
/// Promotion removes the tag from one item. Latest is for people who want each release
/// the day it ships; Stable waits until a release has been promoted.
///
/// Latest is the default because Stable only advances when a release is promoted, and
/// nothing promotes on a machine without the launchd job. A Stable client then silently
/// falls behind the feed and Sparkle reports an older version as the newest one — which
/// reads as a bug. A stored choice still wins, so anyone who picked Stable keeps it.
enum UpdateChannel: String, CaseIterable, Identifiable {
  case stable
  case latest

  var id: String { rawValue }

  /// Name of the Sparkle channel a release carries until it is promoted.
  static let sparkleLatestChannel = "latest"

  /// Extra channels this choice may see, besides the untagged items every client sees.
  /// Stable allows none. Latest allows `latest`.
  var allowedSparkleChannels: Set<String> {
    switch self {
    case .stable:
      return []
    case .latest:
      return [Self.sparkleLatestChannel]
    }
  }

  /// Fallback for a client that never stored a choice. Latest, because Stable can lag behind
  /// the feed indefinitely when no promotion runs (see the type comment).
  static let defaultChannel: UpdateChannel = .latest

  /// A stored choice always wins; only a missing or unknown value falls back to the default.
  static func current(_ defaults: UserDefaults = .standard) -> UpdateChannel {
    guard let raw = defaults.string(forKey: UserDefaultsKeys.updateChannel) else {
      return defaultChannel
    }
    return UpdateChannel(rawValue: raw) ?? defaultChannel
  }
}

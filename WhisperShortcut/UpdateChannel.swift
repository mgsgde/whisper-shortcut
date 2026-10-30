import Foundation

/// Channels on the single Sparkle appcast (`AppConstants.sparkleFeedURL`).
/// An item tagged `<sparkle:channel>latest</sparkle:channel>` is visible only when that
/// channel is allowed. Untagged items are visible to every client, including copies that
/// do not understand channels, so Stable is the untagged items and needs no bootstrap.
/// Promotion removes the tag from one item. Latest is for people who want each release
/// the day it ships; Stable, the default, waits until a release has been promoted.
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

  static let defaultChannel: UpdateChannel = .stable

  /// Missing or unknown stored values stay on Stable.
  static func current(_ defaults: UserDefaults = .standard) -> UpdateChannel {
    guard let raw = defaults.string(forKey: UserDefaultsKeys.updateChannel) else {
      return defaultChannel
    }
    return UpdateChannel(rawValue: raw) ?? defaultChannel
  }
}

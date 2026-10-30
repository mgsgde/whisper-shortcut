import Foundation

/// The two Sparkle feeds of the direct (GitHub) build. Stable, the default, only offers releases
/// that were explicitly promoted. Latest offers every published release, so a practice that works
/// with the app all day is not handed each version the day it ships.
enum UpdateChannel: String, CaseIterable, Identifiable {
  case stable
  case latest

  var id: String { rawValue }

  var feedURL: String {
    switch self {
    case .stable:
      return AppConstants.sparkleStableFeedURL
    case .latest:
      return AppConstants.sparkleFeedURL
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

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The direct build's Sparkle channel. A missing or unknown preference falls back to Latest,
/// because Stable only advances when a release is promoted and can lag behind the feed. A
/// stored choice always wins, so anyone who picked Stable keeps it.
@Suite("Update channel")
struct UpdateChannelTests {

  private func freshDefaults() -> (UserDefaults, String) {
    let suite = "UpdateChannelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
  }

  @Test("Missing key defaults to latest")
  func missingKeyIsLatest() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(UpdateChannel.current(defaults) == .latest)
    #expect(UpdateChannel.defaultChannel == .latest)
  }

  @Test("Unknown stored value falls back to latest; latest is latest")
  func unknownAndLatest() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set("beta", forKey: UserDefaultsKeys.updateChannel)
    #expect(UpdateChannel.current(defaults) == .latest)

    defaults.set("latest", forKey: UserDefaultsKeys.updateChannel)
    #expect(UpdateChannel.current(defaults) == .latest)
  }

  @Test("A stored choice wins over the default")
  func storedChoiceWins() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set("stable", forKey: UserDefaultsKeys.updateChannel)
    #expect(UpdateChannel.current(defaults) == .stable)

    defaults.set("latest", forKey: UserDefaultsKeys.updateChannel)
    #expect(UpdateChannel.current(defaults) == .latest)
  }

  @Test("Stable allows no channel; Latest allows the latest channel")
  func allowedChannels() {
    #expect(UpdateChannel.sparkleLatestChannel == "latest")
    #expect(UpdateChannel.stable.allowedSparkleChannels == Set<String>())
    #expect(UpdateChannel.latest.allowedSparkleChannels == Set([UpdateChannel.sparkleLatestChannel]))
  }
}

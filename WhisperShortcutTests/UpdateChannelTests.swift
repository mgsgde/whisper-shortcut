import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The direct build's Sparkle channel. A missing or unknown preference must stay on Stable:
/// that is the feed a practice is handed until someone explicitly chooses Latest.
@Suite("Update channel")
struct UpdateChannelTests {

  private func freshDefaults() -> (UserDefaults, String) {
    let suite = "UpdateChannelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
  }

  @Test("Missing key defaults to stable")
  func missingKeyIsStable() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(UpdateChannel.current(defaults) == .stable)
    #expect(UpdateChannel.defaultChannel == .stable)
  }

  @Test("Unknown stored value falls back to stable; latest is latest")
  func unknownAndLatest() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set("beta", forKey: UserDefaultsKeys.updateChannel)
    #expect(UpdateChannel.current(defaults) == .stable)

    defaults.set("latest", forKey: UserDefaultsKeys.updateChannel)
    #expect(UpdateChannel.current(defaults) == .latest)
  }

  @Test("Each channel points at its own feed")
  func feedURLs() {
    #expect(UpdateChannel.stable.feedURL == AppConstants.sparkleStableFeedURL)
    #expect(UpdateChannel.latest.feedURL == AppConstants.sparkleFeedURL)
    #expect(UpdateChannel.stable.feedURL != UpdateChannel.latest.feedURL)
    #expect(UpdateChannel.stable.feedURL.contains("/releases/download/stable/appcast.xml"))
  }
}

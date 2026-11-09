import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The direct build's Sparkle channel. A missing or unknown preference must stay on Stable:
/// that choice sees only untagged appcast items until someone explicitly chooses Latest.
@Suite("Update channel")
struct UpdateChannelTests {

  private func freshDefaults() -> (UserDefaults, String) {
    let suite = "UpdateChannelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
  }

  @Test("Missing key and unknown value fall back to stable; latest is latest")
  func channelResolution() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(UpdateChannel.current(defaults) == .stable)
    #expect(UpdateChannel.defaultChannel == .stable)

    defaults.set("beta", forKey: UserDefaultsKeys.updateChannel)
    #expect(UpdateChannel.current(defaults) == .stable)

    defaults.set("latest", forKey: UserDefaultsKeys.updateChannel)
    #expect(UpdateChannel.current(defaults) == .latest)
  }
}

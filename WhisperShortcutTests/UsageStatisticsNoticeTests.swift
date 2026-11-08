import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Who gets the one-time usage statistics invitation. Asking someone who already answered —
/// in onboarding or in Settings — would be nagging, so every way out is pinned.
@Suite("Usage statistics notice")
struct UsageStatisticsNoticeTests {

  private func defaults(preExisting: Bool = true) -> UserDefaults {
    let suite = "UsageStatisticsNoticeTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    d.set(preExisting, forKey: UserDefaultsKeys.telemetryPreExistingInstall)
    return d
  }

  @Test("isDue: only a pre-telemetry install that never chose and was never shown the notice")
  func isDue() {
    #expect(
      UsageStatisticsNotice.isDue(defaults: defaults(), isAvailable: true),
      "due for pre-telemetry install that never chose")
    #expect(
      !UsageStatisticsNotice.isDue(defaults: defaults(preExisting: false), isAvailable: true),
      "not due for installs asked in onboarding")
    for choice in [true, false] {
      let d = defaults()
      d.set(choice, forKey: UserDefaultsKeys.telemetryEnabled)
      #expect(
        !UsageStatisticsNotice.isDue(defaults: d, isAvailable: true),
        "not due once the user chose \(choice) in Settings")
    }
    let shown = defaults()
    shown.set(true, forKey: UserDefaultsKeys.usageStatisticsNoticeShown)
    #expect(!UsageStatisticsNotice.isDue(defaults: shown, isAvailable: true), "not due twice")
    #expect(
      !UsageStatisticsNotice.isDue(defaults: defaults(), isAvailable: false),
      "waits while offline mode or admin key forces sharing off")
  }
}

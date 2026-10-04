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

  @Test func dueForPreTelemetryInstallThatNeverChose() {
    #expect(UsageStatisticsNotice.isDue(defaults: defaults(), isAvailable: true))
  }

  @Test func notDueForInstallsAskedInOnboarding() {
    #expect(!UsageStatisticsNotice.isDue(defaults: defaults(preExisting: false), isAvailable: true))
  }

  @Test func notDueOnceTheUserChoseInSettings() {
    for choice in [true, false] {
      let d = defaults()
      d.set(choice, forKey: UserDefaultsKeys.telemetryEnabled)
      #expect(!UsageStatisticsNotice.isDue(defaults: d, isAvailable: true))
    }
  }

  @Test func notDueTwice() {
    let d = defaults()
    d.set(true, forKey: UserDefaultsKeys.usageStatisticsNoticeShown)
    #expect(!UsageStatisticsNotice.isDue(defaults: d, isAvailable: true))
  }

  @Test func waitsWhileOfflineModeOrAdminKeyForcesSharingOff() {
    #expect(!UsageStatisticsNotice.isDue(defaults: defaults(), isAvailable: false))
  }
}

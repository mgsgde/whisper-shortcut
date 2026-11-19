import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The Welcome Tour turns "Save usage data" on only for a new All-features install, once.
@Suite("Usage data tour default")
struct UsageDataTourDefaultTests {

  private func makeSuite() -> (UserDefaults, String) {
    let name = "UsageDataTourDefaultTests-\(UUID())"
    return (UserDefaults(suiteName: name)!, name)
  }

  @Test("shouldTurnOn is true only when all four inputs are false")
  func shouldTurnOnRule() {
    #expect(UsageDataTourDefault.shouldTurnOn(
      alreadyApplied: false, onboardingCompleted: false, dictationOnly: false, offlineMode: false))
    #expect(!UsageDataTourDefault.shouldTurnOn(
      alreadyApplied: true, onboardingCompleted: false, dictationOnly: false, offlineMode: false))
    #expect(!UsageDataTourDefault.shouldTurnOn(
      alreadyApplied: false, onboardingCompleted: true, dictationOnly: false, offlineMode: false))
    #expect(!UsageDataTourDefault.shouldTurnOn(
      alreadyApplied: false, onboardingCompleted: false, dictationOnly: true, offlineMode: false))
    #expect(!UsageDataTourDefault.shouldTurnOn(
      alreadyApplied: false, onboardingCompleted: false, dictationOnly: false, offlineMode: true))
  }

  @Test("applyIfNeeded on a fresh install sets the switch and the marker")
  func appliesOnFreshInstall() {
    let (defaults, name) = makeSuite()
    UsageDataTourDefault.applyIfNeeded(defaults)
    #expect(defaults.bool(forKey: UserDefaultsKeys.contextLoggingEnabled))
    #expect(defaults.bool(forKey: UserDefaultsKeys.contextLoggingTourDefaultApplied))
    defaults.removePersistentDomain(forName: name)
  }

  @Test("A user who turned it off stays off on the next visit")
  func doesNotTurnBackOn() {
    let (defaults, name) = makeSuite()
    UsageDataTourDefault.applyIfNeeded(defaults)
    defaults.set(false, forKey: UserDefaultsKeys.contextLoggingEnabled)
    UsageDataTourDefault.applyIfNeeded(defaults)
    #expect(!defaults.bool(forKey: UserDefaultsKeys.contextLoggingEnabled))
    defaults.removePersistentDomain(forName: name)
  }

  @Test("Completed onboarding, Dictation only and Offline Mode write nothing")
  func writesNothingWhenExcluded() {
    for key in [
      UserDefaultsKeys.hasCompletedOnboarding,
      UserDefaultsKeys.dictationOnlyMode,
      UserDefaultsKeys.offlineModeEnabled,
    ] {
      let (defaults, name) = makeSuite()
      defaults.set(true, forKey: key)
      UsageDataTourDefault.applyIfNeeded(defaults)
      #expect(defaults.object(forKey: UserDefaultsKeys.contextLoggingEnabled) == nil, "\(key)")
      #expect(defaults.object(forKey: UserDefaultsKeys.contextLoggingTourDefaultApplied) == nil, "\(key)")
      defaults.removePersistentDomain(forName: name)
    }
  }
}

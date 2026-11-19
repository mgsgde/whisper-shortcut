import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// New installs have no `userContextLoggingEnabled` key. That absence means on (owner decision
/// 2026-11-19). A stored value still wins, and Offline Mode still suppresses the log.
@Suite("Context logging preference default")
struct ContextLoggingPreferenceDefaultTests {

  @Test("An absent key reads as on; a stored bool is kept; Offline Mode still wins")
  func absentKeyReadsAsOn() {
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(ContextLoggingPreference.storedFlag(in: defaults))

    defaults.set(false, forKey: UserDefaultsKeys.contextLoggingEnabled)
    #expect(!ContextLoggingPreference.storedFlag(in: defaults))

    defaults.set(true, forKey: UserDefaultsKeys.contextLoggingEnabled)
    #expect(ContextLoggingPreference.storedFlag(in: defaults))

    #expect(!ContextLoggingPreference.isEnabled(offlineMode: true, storedFlag: true))
  }
}

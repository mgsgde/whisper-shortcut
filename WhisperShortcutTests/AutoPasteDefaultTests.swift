import Testing

@testable import WhisperShortcut_AppStore

/// The direct-build decision for an unset auto-paste toggle. `accessibilityGranted` is injected
/// so the test does not depend on this Mac's Accessibility state, and so it still runs in the
/// App Store test bundle, where `AutoPasteDefault.effectiveDefault` is constantly false.
@Suite("Auto-paste default")
struct AutoPasteDefaultTests {

  @Test("A stored true or false wins, whether or not Accessibility is granted")
  func storedWins() {
    #expect(AutoPasteDefault.resolved(stored: true, accessibilityGranted: false))
    #expect(AutoPasteDefault.resolved(stored: true, accessibilityGranted: true))
    #expect(!AutoPasteDefault.resolved(stored: false, accessibilityGranted: true))
    #expect(!AutoPasteDefault.resolved(stored: false, accessibilityGranted: false))
  }

  @Test("When the key was never written, auto-paste follows the injected permission")
  func unsetFollowsPermission() {
    #expect(AutoPasteDefault.resolved(stored: nil, accessibilityGranted: true))
    #expect(!AutoPasteDefault.resolved(stored: nil, accessibilityGranted: false))
  }
}

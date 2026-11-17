import Testing

@testable import WhisperShortcut_AppStore

/// The status menu while the Welcome Tour is unfinished. Feature rows stay in the menu and
/// get their normal visibility back once setup is done; this pins only the allow-list.
@Suite("Status menu during setup")
struct SetupMenuVisibilityTests {
  @Test("Until setup is done only status, Finish setup, Settings and Quit stay")
  func allowedTags() {
    let allowed = Set(MenuBarController.MenuTag.allCases.filter(MenuBarController.visibleDuringSetup))
    #expect(allowed == Set([.status, .finishSetup, .finishSetupSeparator, .settings, .quit]))
  }
}

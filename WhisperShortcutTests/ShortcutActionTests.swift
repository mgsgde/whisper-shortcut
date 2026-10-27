import AppKit
import Foundation
import HotKey
import Testing

@testable import WhisperShortcut_AppStore

/// The test bundle links the App Store app, so Read Aloud is not a shortcut this build ships.
/// `assistantFacingRows` used to name it anyway.
@Suite("Shortcut actions")
struct ShortcutActionTests {

  @Test("Assistant-facing rows are the actions this build ships, in list order")
  func assistantFacingRowsFollowTheBuild() {
    let config = ShortcutConfig.default
    let actions = ShortcutAction.allCases.filter(\.isInThisBuild)
    let rows = config.assistantFacingRows

    #expect(rows.map(\.action) == actions.map(\.title))
    #expect(rows.map(\.definition) == actions.map { config[keyPath: $0.keyPath] })
    #expect(ShortcutAction.allCases.contains(.readAloud))
    #expect(!ShortcutAction.readAloud.isInThisBuild)
    #expect(rows.map(\.action) == [
      "Dictate", "Dictate Prompt", "Screenshot", "Chat", "Settings",
    ])
  }

  @Test("A disabled Dictate binding stays in the list")
  func disabledBindingIsStillListed() {
    var config = ShortcutConfig.default
    config.startRecording = ShortcutDefinition(
      key: .one, modifiers: [.control, .option], isEnabled: false)
    #expect(config.assistantFacingRows.first?.action == "Dictate")
    #expect(config.assistantFacingRows.first?.definition.isEnabled == false)
  }
}

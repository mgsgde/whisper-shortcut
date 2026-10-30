import AppKit
import Foundation
import HotKey
import Testing

@testable import WhisperShortcut_AppStore

/// New installs must not get bare ⌘-digit shortcuts (they switch tabs in browsers, Slack, VS
/// Code), and the pinned legacy set for existing installs must be exactly what they had.
@Suite("Shortcut defaults")
struct ShortcutDefaultsTests {

  private func all(_ c: ShortcutConfig) -> [ShortcutDefinition] {
    [c.startRecording, c.startPrompting, c.openSettings, c.openChat, c.screenshotCapture,
     c.readAloud, c.addToGlossary]
  }

  @Test("New-install defaults avoid bare ⌘-digits and do not collide")
  func newDefaults() {
    let defs = all(ShortcutConfig.default)
    #expect(!defs.contains { $0.modifiers == [.command] })
    #expect(Set(defs.map { "\($0.key)-\($0.modifiers.rawValue)" }).count == defs.count)
    #expect(ShortcutConfig.default.startRecording.modifiers == [.control, .option])
  }

  @Test("Add Selection to Glossary ships without a default shortcut in both sets")
  func glossaryShortcutDisabledByDefault() {
    #expect(!ShortcutConfig.default.addToGlossary.isEnabled)
    #expect(!ShortcutConfig.legacyCommandDigit.addToGlossary.isEnabled)
    // The key and modifiers stay as the suggested binding the user can switch on.
    #expect(ShortcutConfig.default.addToGlossary.key == .seven)
  }

  @Test("App Store availability disables only the hidden Read Aloud and Glossary slots")
  func availableInThisBuildDropsHiddenSlots() {
    var input = ShortcutConfig.default
    input.readAloud = ShortcutDefinition(
      key: .four, modifiers: [.control, .option], isEnabled: true, displayCharacter: "4")
    input.addToGlossary = ShortcutDefinition(
      key: .seven, modifiers: [.control, .option], isEnabled: true, displayCharacter: "7")

    let hidden = ShortcutConfig.availableInThisBuild(input, isAppStore: true)
    #expect(hidden.readAloud == ShortcutDefinition(
      key: input.readAloud.key, modifiers: input.readAloud.modifiers,
      isEnabled: false, displayCharacter: input.readAloud.displayCharacter))
    #expect(hidden.addToGlossary == ShortcutDefinition(
      key: input.addToGlossary.key, modifiers: input.addToGlossary.modifiers,
      isEnabled: false, displayCharacter: input.addToGlossary.displayCharacter))
    #expect(hidden.startRecording == input.startRecording)
    #expect(hidden.startPrompting == input.startPrompting)
    #expect(hidden.openSettings == input.openSettings)
    #expect(hidden.openChat == input.openChat)
    #expect(hidden.screenshotCapture == input.screenshotCapture)

    #expect(ShortcutConfig.availableInThisBuild(input, isAppStore: false) == input)
  }

  @Test("A hidden App Store Read Aloud binding does not reserve ⌃⌥4")
  func hiddenReadAloudDoesNotConflict() {
    let appStore = ShortcutConfig.availableInThisBuild(ShortcutConfig.default, isAppStore: true)
    #expect(ShortcutValidation.conflictingSlot(
      key: .four, modifiers: [.control, .option], in: appStore, excluding: "Toggle Dictation") == nil)

    let direct = ShortcutConfig.availableInThisBuild(ShortcutConfig.default, isAppStore: false)
    #expect(ShortcutValidation.conflictingSlot(
      key: .four, modifiers: [.control, .option], in: direct, excluding: "Toggle Dictation") == "Read Aloud")
  }

  @Test("Legacy defaults are the ⌘-digit set existing installs were running on")
  func legacyDefaults() {
    let legacy = ShortcutConfig.legacyCommandDigit
    #expect(legacy.startRecording == ShortcutDefinition(key: .one, modifiers: [.command]))
    #expect(legacy.openSettings.key == .zero && legacy.openSettings.modifiers == [.command])
    #expect(legacy.openChat == ShortcutConfig.default.openChat)
  }
}

import AppKit
import HotKey
import Testing

@testable import WhisperShortcut_AppStore

/// Covers how a stored binding renders in the menu bar and Settings. The failure mode is silent
/// and cosmetic-looking but disorienting: a shortcut that shows up as "Key", as an empty box, or
/// as nothing at all leaves the user unable to tell what they bound.
@Suite("Shortcut display")
struct ShortcutDisplayTests {

  @Test("Bare function keys render as their name")
  func bareFunctionKey() {
    // F13–F20 are what programmable keyboards send for a dedicated key, and they are bindable
    // without a modifier. Before they had `displayString` cases they rendered as "Key".
    #expect(ShortcutDefinition(key: .f17, modifiers: []).displayString == "F17")
    #expect(ShortcutDefinition(key: .f13, modifiers: []).displayString == "F13")
    #expect(ShortcutDefinition(key: .f20, modifiers: []).displayString == "F20")
    #expect(ShortcutDefinition(key: .f1, modifiers: []).displayString == "F1")
  }

  @Test("A function key's private-use character is not used as the label")
  func functionKeyDisplayCharacterIsIgnored() {
    // The recorder stores `charactersIgnoringModifiers`, which for F17 is AppKit's
    // NSF17FunctionKey (U+F712) — rendering it shows an empty glyph box.
    let recorded = ShortcutDefinition(
      key: .f17, modifiers: [], isEnabled: true, displayCharacter: "\u{F712}")
    #expect(recorded.displayString == "F17")
  }

  @Test("Space renders as its name, not as a blank")
  func spaceIsNamed() {
    let recorded = ShortcutDefinition(
      key: .space, modifiers: [.option], isEnabled: true, displayCharacter: " ")
    #expect(recorded.displayString == "⌥Space")
  }

  @Test("Printable characters still win over the layout-independent name")
  func printableCharacterIsKept() {
    // German layout: the keycode that is "Y" on US-QWERTY prints "Z".
    let recorded = ShortcutDefinition(
      key: .y, modifiers: [.command], isEnabled: true, displayCharacter: "z")
    #expect(recorded.displayString == "⌘Z")
    #expect(ShortcutDefinition(key: .one, modifiers: [.command]).displayString == "⌘1")
  }

  @Test("A disabled binding reads as Disabled regardless of key")
  func disabledBinding() {
    #expect(ShortcutDefinition(key: .f17, modifiers: [], isEnabled: false).displayString == "Disabled")
  }
}

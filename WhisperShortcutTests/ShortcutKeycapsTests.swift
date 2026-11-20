import XCTest

@testable import WhisperShortcut_AppStore

/// Covers how a rendered shortcut string is split into keycaps in Settings: leading modifier
/// glyphs become one keycap each, the remaining key name becomes a single final keycap.
final class ShortcutKeycapsTests: XCTestCase {

  func testAllModifiersAndLetter() {
    XCTAssertEqual(
      ShortcutRecorderRow.keycaps("⌃⌥⇧⌘D"), ["⌃", "⌥", "⇧", "⌘", "D"])
  }

  func testModifierAndNamedKey() {
    XCTAssertEqual(ShortcutRecorderRow.keycaps("⌘Space"), ["⌘", "Space"])
  }

  func testKeyWithoutModifier() {
    XCTAssertEqual(ShortcutRecorderRow.keycaps("F5"), ["F5"])
  }

  func testEmptyString() {
    XCTAssertEqual(ShortcutRecorderRow.keycaps(""), [])
  }

  func testModifierOnly() {
    XCTAssertEqual(ShortcutRecorderRow.keycaps("⌥"), ["⌥"])
  }

  func testWhitespaceBeforeKeyIsTrimmed() {
    XCTAssertEqual(ShortcutRecorderRow.keycaps("⌘ ,"), ["⌘", ","])
  }
}

import AppKit
import XCTest
@testable import WhisperShortcut_AppStore

/// ⌘C/⌘V/⌘A/⌘Z in the Settings and Chat windows only work if the Edit submenu is attached to the
/// main menu. It was silently dropped on German Macs because the item was looked up by its
/// (localized) title. These tests never use titles.
final class EditMenuTests: XCTestCase {
  func testEditMenuItemHasSubmenu() {
    let item = FullAppDelegate.makeEditMenuItem()
    XCTAssertNotNil(item.submenu, "Edit menu item must carry its submenu regardless of its title")
  }

  func testEditSubmenuHasStandardKeyEquivalents() throws {
    let submenu = try XCTUnwrap(FullAppDelegate.makeEditMenuItem().submenu)
    let expected: [(String, String)] = [
      ("undo:", "z"), ("cut:", "x"), ("copy:", "c"), ("paste:", "v"), ("selectAll:", "a"),
    ]
    for (action, key) in expected {
      let found = submenu.items.contains {
        $0.action == NSSelectorFromString(action) && $0.keyEquivalent == key
      }
      XCTAssertTrue(found, "Edit submenu is missing \(action) with key equivalent \(key)")
    }
  }

  /// Menu titles are localized, so `item(withTitle:)` returns nil on non-English systems.
  func testNoMenuLookupByTitleInSources() throws {
    let sources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("WhisperShortcut")
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    var offenders: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let text = try String(contentsOf: url, encoding: .utf8)
      for (index, line) in text.components(separatedBy: "\n").enumerated()
      where line.contains("item(withTitle:") {
        offenders.append("\(url.lastPathComponent):\(index + 1)")
      }
    }
    XCTAssertTrue(
      offenders.isEmpty,
      "item(withTitle:) found at \(offenders). Menu titles are localized, so hold a reference to the NSMenuItem instead of looking it up by title.")
  }
}

import XCTest
@testable import WhisperShortcut_AppStore

final class UILabelGlossaryTests: XCTestCase {
  func testEnglishAppGetsNoAppendix() {
    XCTAssertEqual(UILabelGlossary.appendix(languageCode: "en"), "")
  }

  /// Every English label in the table must appear in the README, or the table maps names the
  /// Chat never reads.
  func testEveryEnglishLabelAppearsInReadme() throws {
    let readme = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("README.md")
    let text = try String(contentsOf: readme, encoding: .utf8)
    for entry in UILabelGlossary.entries {
      XCTAssertTrue(text.contains(entry.english), "README never mentions \"\(entry.english)\"")
    }
  }

  func testEnglishLabelsAreUnique() {
    let names = UILabelGlossary.entries.map(\.english)
    XCTAssertEqual(names.count, Set(names).count)
  }
}

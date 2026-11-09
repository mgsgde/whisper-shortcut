import XCTest
@testable import WhisperShortcut_AppStore

final class UILabelGlossaryTests: XCTestCase {
  func testEnglishAppGetsNoAppendix() {
    XCTAssertEqual(UILabelGlossary.appendix(languageCode: "en"), "")
  }

  /// Every English label in the table must appear in the README or docs/guide.md, or the table
  /// maps names the Chat never reads.
  func testEveryEnglishLabelAppearsInBundledDocs() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
    let readme = try String(
      contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
    let guide = try String(
      contentsOf: root.appendingPathComponent("docs/guide.md"), encoding: .utf8)
    let text = readme + "\n" + guide
    for entry in UILabelGlossary.entries {
      XCTAssertTrue(
        text.contains(entry.english),
        "README or docs/guide.md never mentions \"\(entry.english)\"")
    }
  }

  func testEnglishLabelsAreUnique() {
    let names = UILabelGlossary.entries.map(\.english)
    XCTAssertEqual(names.count, Set(names).count)
  }
}

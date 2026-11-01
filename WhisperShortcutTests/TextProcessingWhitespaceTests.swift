import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Shared whitespace + mojibake repair used by dictation and Dictate Prompt paste.
/// Collapsing indentation or "fixing" already-correct UTF-8 silently corrupts the paste.
@Suite("Text processing whitespace and mojibake")
struct TextProcessingWhitespaceTests {

  @Test("Leading and trailing whitespace is trimmed")
  func trimsOuterWhitespace() {
    #expect(TextProcessingUtility.normalizingWhitespace("  hello world  ") == "hello world")
    #expect(TextProcessingUtility.normalizingWhitespace("\n\nhello\n\n") == "hello")
  }

  @Test("Three or more consecutive newlines collapse to two")
  func collapsesExcessNewlines() {
    #expect(
      TextProcessingUtility.normalizingWhitespace("line1\n\n\n\nline2")
        == "line1\n\nline2")
  }

  @Test("Exactly two newlines are kept")
  func keepsParagraphBreak() {
    #expect(
      TextProcessingUtility.normalizingWhitespace("para one\n\npara two")
        == "para one\n\npara two")
  }

  @Test("Internal spaces and tabs collapse; later-line indentation is kept")
  func preservesIndentationAndCollapsesRest() {
    // Outer trim drops leading whitespace on the *first* line (current contract).
    // A later line's leading tab is preserved so nested bullets stay indented.
    let input = "- first   item\n\t- second\t\titem  "
    let output = TextProcessingUtility.normalizingWhitespace(input)
    #expect(output == "- first item\n\t- second item")
  }

  @Test("Leading spaces on the first line are stripped by the outer trim")
  func firstLineIndentIsTrimmed() {
    #expect(
      TextProcessingUtility.normalizingWhitespace("  - first item\n  - second item")
        == "- first item\n  - second item")
  }

  @Test("A line of only whitespace stays empty after trailing trim")
  func whitespaceOnlyLine() {
    #expect(TextProcessingUtility.normalizingWhitespace("hello\n   \nworld") == "hello\n\nworld")
  }

  @Test("Known UTF-8-as-Windows-1252 mojibake is repaired")
  func repairsClassicMojibake() throws {
    // UTF-8 bytes of "ä" / "—" read as Windows-1252 — the classic paste-from-terminal case.
    let aUmlaut = try #require(String(data: Data([0xC3, 0xA4]), encoding: .windowsCP1252))
    let emDash = try #require(String(data: Data([0xE2, 0x80, 0x94]), encoding: .windowsCP1252))
    #expect(TextProcessingUtility.repairMojibakeIfNeeded(aUmlaut) == "ä")
    #expect(TextProcessingUtility.repairMojibakeIfNeeded(emDash) == "—")
  }

  @Test("Correct UTF-8 without mojibake markers is left alone")
  func leavesCleanTextAlone() {
    #expect(TextProcessingUtility.repairMojibakeIfNeeded("Café — naïve") == "Café — naïve")
    #expect(TextProcessingUtility.repairMojibakeIfNeeded("plain ascii") == "plain ascii")
  }

  @Test("Markers that cannot be improved are left alone")
  func unrepairableMarkersStay() {
    // Isolated "Ã" with no following Latin-1 pair that round-trips to fewer markers.
    let leftover = "Ã"
    #expect(TextProcessingUtility.repairMojibakeIfNeeded(leftover) == leftover)
  }
}

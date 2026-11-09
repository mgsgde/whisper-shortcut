import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Shared whitespace + mojibake repair used by dictation and Dictate Prompt paste.
/// Collapsing indentation or "fixing" already-correct UTF-8 silently corrupts the paste.
@Suite("Text processing whitespace and mojibake")
struct TextProcessingWhitespaceTests {

  private struct WhitespaceCase: Sendable {
    let input: String
    let expected: String
    let label: String
  }

  @Test(
    "normalizingWhitespace trims, collapses excess, and keeps indentation and paragraph breaks",
    arguments: [
      WhitespaceCase(input: "  hello world  ", expected: "hello world", label: "trims outer spaces"),
      WhitespaceCase(input: "\n\nhello\n\n", expected: "hello", label: "trims outer newlines"),
      // Three or more consecutive newlines collapse to two.
      WhitespaceCase(input: "line1\n\n\n\nline2", expected: "line1\n\nline2", label: "collapses excess newlines"),
      WhitespaceCase(input: "para one\n\npara two", expected: "para one\n\npara two", label: "keeps paragraph break"),
      // Outer trim drops leading whitespace on the *first* line (current contract).
      // A later line's leading tab is preserved so nested bullets stay indented.
      WhitespaceCase(
        input: "- first   item\n\t- second\t\titem  ", expected: "- first item\n\t- second item",
        label: "internal runs collapse, later indentation kept"),
      WhitespaceCase(
        input: "  - first item\n  - second item", expected: "- first item\n  - second item",
        label: "first-line indent stripped by outer trim"),
      WhitespaceCase(
        input: "hello\n   \nworld", expected: "hello\n\nworld",
        label: "whitespace-only line stays empty"),
    ])
  private func normalizesWhitespace(_ c: WhitespaceCase) {
    #expect(TextProcessingUtility.normalizingWhitespace(c.input) == c.expected, "\(c.label)")
  }

  @Test("repairMojibakeIfNeeded repairs known mojibake and leaves everything else alone")
  func repairsMojibake() throws {
    // UTF-8 bytes of "ä" / "—" read as Windows-1252 — the classic paste-from-terminal case.
    let aUmlaut = try #require(String(data: Data([0xC3, 0xA4]), encoding: .windowsCP1252))
    let emDash = try #require(String(data: Data([0xE2, 0x80, 0x94]), encoding: .windowsCP1252))
    #expect(TextProcessingUtility.repairMojibakeIfNeeded(aUmlaut) == "ä")
    #expect(TextProcessingUtility.repairMojibakeIfNeeded(emDash) == "—")
    // Correct UTF-8 without mojibake markers is left alone.
    #expect(TextProcessingUtility.repairMojibakeIfNeeded("Café — naïve") == "Café — naïve")
    #expect(TextProcessingUtility.repairMojibakeIfNeeded("plain ascii") == "plain ascii")
    // Isolated "Ã" with no following Latin-1 pair that round-trips to fewer markers.
    let leftover = "Ã"
    #expect(TextProcessingUtility.repairMojibakeIfNeeded(leftover) == leftover)
  }
}

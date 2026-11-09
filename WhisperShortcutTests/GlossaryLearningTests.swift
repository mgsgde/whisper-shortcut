import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Automatic glossary edits (the chat tool, AI apps over MCP) may only append to the Whisper
/// Glossary. These lock that contract; a rewrite that "cleans up" the glossary fails them.
@Suite("Glossary learning")
struct GlossaryLearningTests {

  private static let fixture = """
  Christoph Michelbach (not "m1cm1")
  sabaki.dance (not "Bachi dance")
  Wianco (not "Vianco")
  Terms: GrokBot, Smikale, Cursor, EnBW, Fable, Sonnet
  """

  @Test("A suggestion adds only new terms and leaves every current line in place")
  func mergeNeverDropsAnEntry() {
    let result = GlossaryLearning.mergeAdditively(
      current: Self.fixture, suggestion: "Terms: Bachata, Cursor, Gemini")
    #expect(result.hasPrefix(Self.fixture))
    for line in Self.fixture.components(separatedBy: .newlines) where !line.isEmpty {
      #expect(result.contains(line))
    }
    #expect(result == Self.fixture + "\nBachata\nGemini")
  }

  @Test("A rejected spelling is not added back as its own term")
  func rejectedFormIsNotReadded() {
    let result = GlossaryLearning.mergeAdditively(current: Self.fixture, suggestion: "Terms: Vianco")
    #expect(result == Self.fixture)
  }

  @Test("Case and diacritics do not create a second copy of a term")
  func caseAndDiacriticsCollapse() {
    #expect(GlossaryLearning.mergeAdditively(current: Self.fixture, suggestion: "Terms: cursor, ENBW") == Self.fixture)
    #expect(GlossaryLearning.mergeAdditively(current: "Gödde", suggestion: "gödde") == "Gödde")
    // ö folds away, so the unaccented spelling is the same term the user already wrote.
    #expect(GlossaryLearning.mergeAdditively(current: "Gödde", suggestion: "Godde") == "Gödde")
  }

  @Test("An annotated line is appended, and a known term only gains new rejected spellings")
  func annotatedSuggestionsAppendOnlyWhatIsNew() {
    let added = GlossaryLearning.mergeAdditively(
      current: Self.fixture, suggestion: "Gemini (not \"Geminni\")")
    #expect(added == Self.fixture + "\nGemini (not \"Geminni\")")

    let extended = GlossaryLearning.mergeAdditively(
      current: Self.fixture, suggestion: "Wianco (not \"Vianco\", \"Viancko\")")
    #expect(extended == Self.fixture + "\nWianco (not \"Viancko\")")
  }

  @Test("An empty glossary is just the additions")
  func emptyCurrentIsJustAdditions() {
    #expect(GlossaryLearning.mergeAdditively(current: "", suggestion: "Terms: Gemini, Cursor") == "Gemini\nCursor")
    #expect(GlossaryLearning.mergeAdditively(current: "\n\n", suggestion: "Bachata") == "Bachata")
  }

  @Test("Majority casing rewrites new lines and leaves asserted lines and rejected spellings alone")
  func majorityCasingRespectsCurrentLinesAndAnnotations() {
    let few = ["Bachata", "Bachata"]
    #expect(GlossaryLearning.applyingMajorityCasing(to: "bachata", keepingLinesOf: "", transcripts: few) == "bachata")

    let transcripts = ["Bachata", "Bachata", "Bachata"]
    #expect(GlossaryLearning.applyingMajorityCasing(to: "bachata", keepingLinesOf: "", transcripts: transcripts) == "Bachata")
    #expect(GlossaryLearning.applyingMajorityCasing(to: "bachata", keepingLinesOf: "bachata", transcripts: transcripts) == "bachata")
    #expect(
      GlossaryLearning.applyingMajorityCasing(
        to: "bachata\nextra bachata",
        keepingLinesOf: "bachata",
        transcripts: transcripts) == "bachata\nextra Bachata")
    #expect(
      GlossaryLearning.applyingMajorityCasing(
        to: "bachata (not \"bachata\")",
        keepingLinesOf: "",
        transcripts: transcripts) == "Bachata (not \"bachata\")")
    #expect(
      GlossaryLearning.applyingMajorityCasing(
        to: "bachata (nicht \"bachata\")",
        keepingLinesOf: "",
        transcripts: transcripts) == "Bachata (nicht \"bachata\")")
  }

}

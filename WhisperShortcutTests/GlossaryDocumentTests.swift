import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The glossary used to be parsed in four places, and the copies disagreed on the `Terms:`
/// label, the word cap, and diacritics. These pin the one parser those readers now share.
@Suite("Glossary document")
struct GlossaryDocumentTests {

  private static let fiveWords = "Alpha Beta Gamma Delta Epsilon"
  private static let sixWords = "Alpha Beta Gamma Delta Epsilon Zeta"

  @Test("Terms label, both annotation languages, the word cap, and diacritics")
  func parseFixture() {
    let text = " Terms: \(Self.fiveWords), \(Self.sixWords)\n"
      + "Terms: Cursor\n"
      + "Godde (not \"Goedde, Gödde\")\n"
      + "Claude (nicht \"Cloud\")\n"
    let document = GlossaryDocument.parse(text)

    #expect(document.entries.map(\.term) == [
      Self.fiveWords, Self.sixWords, "Cursor", "Godde", "Claude",
    ])
    #expect(document.entries[0].term.split(separator: " ").count == GlossaryDocument.maxTermWords)
    #expect(GlossaryDocument.withinWordCap(document.entries[0].term))
    #expect(document.entries[1].term.split(separator: " ").count == GlossaryDocument.maxTermWords + 1)
    #expect(!GlossaryDocument.withinWordCap(document.entries[1].term))
    #expect(document.entries[3].rejectedSpellings == ["Goedde", "Gödde"])
    #expect(document.entries[4].rejectedSpellings == ["Cloud"])
    #expect(GlossaryDocument.fold("Gödde") == GlossaryDocument.fold("Godde"))
    #expect(GlossaryDocument.fold("Gödde") != GlossaryDocument.fold("Goedde"))
  }

  /// Deleting the `^\s*` from the shared prefix turns the indented label into a term.
  @Test("A leading space before Terms is not part of the term")
  func leadingSpaceBeforeTermsIsNotPartOfTheTerm() {
    #expect(GlossaryDocument.parse("  Terms: Pia").entries.map(\.term) == ["Pia"])
    #expect(GlossaryDocument.parse("Terms: Pia").entries.map(\.term) == ["Pia"])
    #expect(GlossaryDocument.termsLabel(on: "  Terms: Pia") == "  Terms: ")
  }

  @Test("Fold matches POSIX, including the Turkish I that a Turkish locale would split")
  func foldIsLocaleIndependent() {
    #expect(GlossaryDocument.fold("I") == "i")
    #expect(GlossaryDocument.fold("İ") == "i")
    let turkishI = "I".folding(
      options: [.diacriticInsensitive, .caseInsensitive],
      locale: Locale(identifier: "tr_TR"))
    #expect(turkishI != "i")
    #expect(GlossaryDocument.fold("I") != turkishI)
  }

  @Test("Duplicate detection folds diacritics and sees inside annotations")
  func glossaryContainsUsesTheSharedFold() {
    #expect(SystemPromptsStore.glossaryContains("Gödde", in: "Godde"))
    #expect(SystemPromptsStore.glossaryContains("Gödde", in: "Godde (not \"Goedde\")"))
    // The term "Goedde" does not fold to "Gödde" (oe is not ö). The rejected spelling does.
    #expect(SystemPromptsStore.glossaryContains("Gödde", in: "Goedde (not \"Gödde\")"))
    #expect(SystemPromptsStore.glossaryContains("Goedde", in: "Godde (not \"Goedde\")"))
    #expect(!SystemPromptsStore.glossaryContains("Gödde", in: "Goedde"))
    #expect(!SystemPromptsStore.glossaryContains("Fascia", in: "Fascia thoracolumbalis"))
  }
}

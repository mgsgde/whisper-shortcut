import Testing
@testable import WhisperShortcut_AppStore

/// Pins the CTC replacement filter against the 2026-10-26 glossary-casing benchmark:
/// de+glossar deleted "7,2" next to HbA1c and swapped Bisoprolol for Metoprolol.
@Suite("Parakeet vocabulary replacement guard")
struct ParakeetVocabularyGuardTests {

  private let glossary = [
    "HbA1c", "CRP", "TSH", "eGFR", "Metoprolol", "Bisoprolol", "Ramipril",
    "Apixaban", "Rivaroxaban", "Pantoprazol",
  ]

  @Test("Lab value next to a glossary term is kept")
  func rejectsDigitSpanFromClipC() {
    let original = "Laborwerte, HbA1c 7,2, CRP erhöht, TSH normal, eGFR bei 45."
    let applied = ParakeetVocabularyGuard.apply(
      to: original,
      replacements: [
        .init(originalSpan: "HbA1c 7,2", term: "HbA1c"),
        .init(originalSpan: "HBA1C7,2", term: "HbA1c"),
      ],
      glossaryTerms: glossary)
    #expect(applied.text.contains("7,2"))
    #expect(applied.text.contains("HbA1c"))
    #expect(applied.rejected == 2)
    #expect(applied.accepted == 0)
  }

  @Test("A correctly recognised glossary drug is not swapped for another")
  func rejectsDrugSwapFromClipD() {
    let original =
      "Bekannte COPD, Pantoprazol weiter, Bisoprolol unverändert."
    let applied = ParakeetVocabularyGuard.apply(
      to: original,
      replacements: [.init(originalSpan: "Bisoprolol", term: "Metoprolol")],
      glossaryTerms: glossary)
    #expect(applied.text.contains("Bisoprolol"))
    #expect(!applied.text.contains("Metoprolol"))
    #expect(applied.rejected == 1)
  }

  @Test("A misspelt term that is not itself a glossary entry is still corrected")
  func acceptsMisspelling() {
    let original = "aktuell unter Metoprollol und Apexaban"
    let applied = ParakeetVocabularyGuard.apply(
      to: original,
      replacements: [
        .init(originalSpan: "Metoprollol", term: "Metoprolol"),
        .init(originalSpan: "Apexaban", term: "Apixaban"),
      ],
      glossaryTerms: glossary)
    #expect(applied.text == "aktuell unter Metoprolol und Apixaban")
    #expect(applied.accepted == 2)
    #expect(applied.rejected == 0)
  }

  @Test("A span with more than one extra word is rejected")
  func rejectsWideSpan() {
    #expect(
      !ParakeetVocabularyGuard.accepts(
        .init(originalSpan: "weiter Bisoprolol unverändert", term: "Metoprolol"),
        glossaryTerms: glossary))
  }
}

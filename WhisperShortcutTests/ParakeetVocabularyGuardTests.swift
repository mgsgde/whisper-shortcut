import Testing
@testable import WhisperShortcut_AppStore

/// Pins the CTC replacement filter against the 2026-10-26 glossary-casing benchmark:
/// de+glossar deleted "7,2" next to HbA1c and swapped Bisoprolol for Metoprolol.
@Suite("Parakeet vocabulary replacement guard")
struct ParakeetVocabularyGuardTests {

  private let glossary = [
    "HbA1c", "CRP", "TSH", "eGFR", "Metoprolol", "Bisoprolol", "Ramipril",
    "Apixaban", "Rivaroxaban", "Pantoprazol", "B12", "COVID-19", "GPT-4o", "ACE",
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

  @Test("Digits that belong to the term are accepted")
  func acceptsDigitsOfTerm() {
    for (span, term) in [
      ("HBA1C", "HbA1c"), ("B 12", "B12"), ("COVID 19", "COVID-19"), ("GPT 4o", "GPT-4o"),
    ] {
      #expect(
        ParakeetVocabularyGuard.accepts(
          .init(originalSpan: span, term: term), glossaryTerms: glossary),
        "\(span) → \(term)")
    }
  }

  @Test("A neighbouring glossary drug in the span blocks the replacement")
  func rejectsNeighbourDrugSwap() {
    let replacement = ParakeetVocabularyGuard.Replacement(
      originalSpan: "weiter Bisoprolol", term: "Metoprolol")
    #expect(!ParakeetVocabularyGuard.accepts(replacement, glossaryTerms: glossary))
    let original = "Pantoprazol weiter Bisoprolol unverändert"
    let applied = ParakeetVocabularyGuard.apply(
      to: original, replacements: [replacement], glossaryTerms: glossary)
    #expect(applied.text == original)
    #expect(applied.rejected == 1)
  }

  @Test("Spans match on word boundaries only")
  func matchesOnWordBoundaries() {
    let inside = ParakeetVocabularyGuard.apply(
      to: "Place the Ace here",
      replacements: [.init(originalSpan: "Ace", term: "ACE")],
      glossaryTerms: glossary)
    #expect(inside.text == "Place the ACE here")
    #expect(inside.accepted == 1)

    let glued = ParakeetVocabularyGuard.apply(
      to: "Placement",
      replacements: [.init(originalSpan: "ace", term: "ACE")],
      glossaryTerms: glossary)
    #expect(glued.text == "Placement")
    #expect(glued.rejected == 1)
  }
}

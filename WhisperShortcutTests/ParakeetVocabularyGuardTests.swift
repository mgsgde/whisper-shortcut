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

  private let pilotGlossary = ["GdB", "VersMedV", "ADL", "Merkzeichen", "Kizomba"]

  @Test("Dissimilar spans are rejected (spelling similarity)")
  func rejectsDissimilarSpans() {
    for (span, term) in [
      ("erreicht", "Merkzeichen"), ("Ah", "ADL"), ("G", "GdB"), ("im ADL", "ADL"),
    ] {
      #expect(
        !ParakeetVocabularyGuard.accepts(
          .init(originalSpan: span, term: term), glossaryTerms: pilotGlossary),
        "\(span) -> \(term)")
    }
  }

  @Test("Genuine spelling corrections still pass")
  func acceptsSimilarSpans() {
    for (span, term) in [
      ("Metotrexat", "Methotrexat"), ("Vers Med V", "VersMedV"), ("G d B", "GdB"),
      ("A D L", "ADL"), ("GDB", "GdB"),
    ] {
      #expect(
        ParakeetVocabularyGuard.accepts(
          .init(originalSpan: span, term: term),
          glossaryTerms: pilotGlossary + ["Methotrexat"]),
        "\(span) -> \(term)")
    }
  }

  @Test("Spoken punctuation command words are never rewritten")
  func rejectsCommandWords() {
    #expect(
      !ParakeetVocabularyGuard.accepts(
        .init(originalSpan: "Komma", term: "Kizomba"), glossaryTerms: pilotGlossary))
    #expect(
      !ParakeetVocabularyGuard.accepts(
        .init(originalSpan: "Doppelpunkt", term: "Doppelpunkte"), glossaryTerms: pilotGlossary))
    let applied = ParakeetVocabularyGuard.apply(
      to: "Gangbild Komma geht weiter.",
      replacements: [.init(originalSpan: "Komma", term: "Kizomba")],
      glossaryTerms: pilotGlossary)
    #expect(applied.text == "Gangbild Komma geht weiter.")
  }

  @Test("Glossary casing is restored for whole words only")
  func restoresCasing() {
    let terms = ["GdB", "Merkzeichen", "ADL"]
    #expect(
      ParakeetVocabularyGuard.restoreGlossaryCasing(in: "Der GDB ist 50.", glossaryTerms: terms)
        == "Der GdB ist 50.")
    #expect(
      ParakeetVocabularyGuard.restoreGlossaryCasing(in: "GDB50 und gdb", glossaryTerms: terms)
        == "GdB 50 und GdB")
    #expect(
      ParakeetVocabularyGuard.restoreGlossaryCasing(in: "gdb50", glossaryTerms: terms) == "GdB 50")
    #expect(
      ParakeetVocabularyGuard.restoreGlossaryCasing(
        in: "merkzeichen und Adl", glossaryTerms: terms) == "merkzeichen und ADL")
  }

  @Test("A glued digit run is split off a casing term, unless the term ends in a digit")
  func splitsGluedDigits() {
    let terms = ["GdB", "HbA1c", "B12"]
    #expect(
      ParakeetVocabularyGuard.restoreGlossaryCasing(in: "Der GDB50 liegt vor", glossaryTerms: terms)
        == "Der GdB 50 liegt vor")
    // Already spaced, glued to a letter, or the term ends in a digit: nothing to split.
    #expect(
      ParakeetVocabularyGuard.restoreGlossaryCasing(in: "GdB 50 GdBx", glossaryTerms: terms)
        == "GdB 50 GdBx")
    #expect(
      ParakeetVocabularyGuard.restoreGlossaryCasing(in: "HbA1c 7,2", glossaryTerms: terms)
        == "HbA1c 7,2")
    #expect(
      ParakeetVocabularyGuard.restoreGlossaryCasing(in: "hba1c", glossaryTerms: terms) == "HbA1c")
    #expect(
      ParakeetVocabularyGuard.restoreGlossaryCasing(in: "B125", glossaryTerms: ["B12"]) == "B125")
  }

  private let everydayGlossary = [
    "Seiter", "TEP", "PNP", "Wirbelsäule", "Methotrexat", "GdB",
  ]

  @Test("An ordinary German word is never replaced by a glossary term")
  func rejectsOrdinaryGermanWord() {
    for (span, term) in [
      ("weiter", "Seiter"),
      ("Weiter", "Seiter"),
      ("weiter", "TEP"),
      ("Prinzip", "PNP"),
      ("im Prinzip", "PNP"),
      ("Seite", "Seiter"),
    ] {
      #expect(
        !ParakeetVocabularyGuard.accepts(
          .init(originalSpan: span, term: term), glossaryTerms: everydayGlossary),
        "\(span) -> \(term)")
    }
    let original = "Ich arbeite mal weiter damit."
    let applied = ParakeetVocabularyGuard.apply(
      to: original,
      replacements: [.init(originalSpan: "weiter", term: "Seiter")],
      glossaryTerms: everydayGlossary)
    #expect(applied.text == original)
    #expect(applied.accepted == 0)
    #expect(applied.rejected == 1)
  }

  @Test("A correction still passes when the span is not only ordinary words")
  func acceptsCorrectionThatIsNotOnlyOrdinaryWords() {
    for (span, term) in [
      ("Wir Belsäule", "Wirbelsäule"),
      ("Metotrexat", "Methotrexat"),
      ("GDB", "GdB"),
    ] {
      #expect(
        ParakeetVocabularyGuard.accepts(
          .init(originalSpan: span, term: term), glossaryTerms: everydayGlossary),
        "\(span) -> \(term)")
    }
  }
}

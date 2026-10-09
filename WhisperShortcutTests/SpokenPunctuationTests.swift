import Testing

@testable import WhisperShortcut_AppStore

/// Offline engines (Parakeet, local Whisper) write spoken layout commands out as words. The
/// conversion is deterministic and deliberately narrow, so both halves are pinned: what changes,
/// and the ordinary German words that must not.
@Suite("Spoken punctuation (offline dictation)")
struct SpokenPunctuationTests {

  @Test("\"Doppelpunkt\" becomes a colon attached to the previous word")
  func colonAttachesToPreviousWord() {
    #expect(
      SpokenPunctuation.apply(to: "Anamnese Doppelpunkt Patient berichtet über Schmerzen")
        == "Anamnese: Patient berichtet über Schmerzen")
  }

  @Test("Punctuation the ASR put around \"Doppelpunkt\" is removed")
  func colonEatsStrayPunctuation() {
    #expect(SpokenPunctuation.apply(to: "Befund, Doppelpunkt. Inspektion") == "Befund: Inspektion")
    #expect(SpokenPunctuation.apply(to: "Befund. Doppelpunkt, Inspektion") == "Befund: Inspektion")
    #expect(SpokenPunctuation.apply(to: "Therapie Doppelpunkt.") == "Therapie:")
  }

  @Test("Matching is case-insensitive")
  func caseInsensitive() {
    #expect(SpokenPunctuation.apply(to: "Befund doppelpunkt Inspektion") == "Befund: Inspektion")
    #expect(SpokenPunctuation.apply(to: "Befund DOPPELPUNKT Inspektion") == "Befund: Inspektion")
  }

  @Test("\"neuer Absatz\" becomes a blank line, without stray spaces or commas")
  func paragraphBreak() {
    #expect(
      SpokenPunctuation.apply(to: "Patient klagt über Schmerzen, neuer Absatz, Befund unauffällig")
        == "Patient klagt über Schmerzen\n\nBefund unauffällig")
    #expect(
      SpokenPunctuation.apply(to: "Patient klagt über Schmerzen. Neuer Absatz. Befund unauffällig")
        == "Patient klagt über Schmerzen.\n\nBefund unauffällig")
  }

  @Test("\"neue Zeile\" becomes a line break")
  func lineBreak() {
    #expect(
      SpokenPunctuation.apply(to: "Erste Zeile neue Zeile zweite Zeile")
        == "Erste Zeile\nzweite Zeile")
  }

  @Test("A full note: colons and paragraphs together")
  func fullNote() {
    let spoken =
      "Anamnese Doppelpunkt Schmerzen LWS seit drei Tagen. Neuer Absatz Befund, Doppelpunkt. "
      + "ISG links blockiert. Neuer Absatz. Therapie Doppelpunkt neue Zeile HVLA"
    #expect(
      SpokenPunctuation.apply(to: spoken)
        == "Anamnese: Schmerzen LWS seit drei Tagen.\n\nBefund: ISG links blockiert.\n\nTherapie:\nHVLA")
  }

  @Test("\"Punkt\", \"Komma\" and \"Fragezeichen\" are ordinary words and stay")
  func ordinaryWordsStay() {
    let text = "Der wichtigste Punkt ist das Komma und das Fragezeichen am Ende."
    #expect(SpokenPunctuation.apply(to: text) == text)
  }

  @Test("Only whole words match")
  func wholeWordsOnly() {
    let text = "Die Doppelpunkte und der Absatzmarke bleiben."
    #expect(SpokenPunctuation.apply(to: text) == text)
  }

  @Test("Text without commands comes back unchanged, whitespace included")
  func noCommandsUnchanged() {
    let text = "  Patient berichtet über Schmerzen im unteren Rücken.\n"
    #expect(SpokenPunctuation.apply(to: text) == text)
  }
}

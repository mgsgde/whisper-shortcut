import AppKit
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

  @Test("\"neuer Absatz\" becomes a blank line; a comma before it ends the sentence")
  func paragraphBreak() {
    #expect(
      SpokenPunctuation.apply(to: "Patient klagt über Schmerzen, neuer Absatz, Befund unauffällig")
        == "Patient klagt über Schmerzen.\n\nBefund unauffällig")
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

/// Cases carried over from the parallel implementation in PR #109.
@Suite("Spoken punctuation — additional cases")
struct SpokenPunctuationExtraTests {

  @Test("Hyphenated words and a trailing full stop survive the colon")
  func hyphenatedWords() {
    #expect(
      SpokenPunctuation.apply(to: "Anamnese Doppelpunkt LWS-Schmerzen seit drei Wochen.")
        == "Anamnese: LWS-Schmerzen seit drei Wochen.")
    #expect(SpokenPunctuation.apply(to: "Anamnese, Doppelpunkt. Patient berichtet") == "Anamnese: Patient berichtet")
  }

  @Test("Colon, paragraph and line commands in sequence")
  func sequence() {
    #expect(
      SpokenPunctuation.apply(to: "Anamnese Doppelpunkt Schmerzen. Neuer Absatz. Befund Doppelpunkt Tonus erhöht")
        == "Anamnese: Schmerzen.\n\nBefund: Tonus erhöht")
    #expect(SpokenPunctuation.apply(to: "Erstens neue Zeile zweitens") == "Erstens\nzweitens")
    #expect(SpokenPunctuation.apply(to: "Doppelpunkte zählen") == "Doppelpunkte zählen")
  }

  @Test("Parakeet glues \"Doppelpunkt\" onto the next word (live capture 2026-10-09)")
  func gluedColon() {
    let raw =
      "Anamnese Doppelpunkt Schmerzen im unteren Rücken seit drei Wochen, neuer Absatz, "
      + "Befund Doppelpunktdruckschmerz L4 bis S1, neuer Absatz, "
      + "Therapie Doppelpunkt Mobilisation der LWS, das ist der wichtigste Punkt."
    #expect(
      SpokenPunctuation.apply(to: raw)
        == "Anamnese: Schmerzen im unteren Rücken seit drei Wochen.\n\nBefund: Druckschmerz L4 bis S1.\n\n"
        + "Therapie: Mobilisation der LWS, das ist der wichtigste Punkt.")
    #expect(SpokenPunctuation.apply(to: "Die Doppelpunkten und des Doppelpunktes") == "Die Doppelpunkten und des Doppelpunktes")
  }
}

/// Live capture 2026-10-20 (`ParakeetOfflineTests.spokenLayoutCommands`, four German voices): Parakeet
/// glues "neue Zeile" onto the next word, which left the command in the text and the line break out.
@Suite("Spoken punctuation — glued line break")
struct SpokenPunctuationGluedLineTests {

  @Test("\"neue Zeile\" glued to the next word still breaks the line")
  func gluedLineBreak() {
    let raw =
      "Befund Doppelpunkt Neue Zeileinspektion unauffällig neue Zeilepalpation Doppelpunkt Triggerpunkte im Trapezius."
    #expect(
      SpokenPunctuation.apply(to: raw)
        == "Befund:\nInspektion unauffällig\nPalpation: Triggerpunkte im Trapezius.")
  }

  @Test("\"neue Zeilen\" and its compounds stay words")
  func pluralStays() {
    let text = "Bitte zwei neue Zeilen einfügen, neue Zeilenumbrüche vermeiden."
    #expect(SpokenPunctuation.apply(to: text) == text)
  }
}

/// Pilot report 2026-10-19: with Parakeet + local Qwen, ⌘2 notes still contained the word
/// "Doppelpunkt". The same pass now also runs over the local model's reply, which may already carry
/// its own colon after the heading.
@Suite("Spoken punctuation — Dictate Prompt reply")
struct SpokenPunctuationReplyTests {

  @Test("A word kept after the model's own colon is dropped, not doubled")
  func wordAfterExistingColon() {
    #expect(SpokenPunctuation.apply(to: "Befund: Doppelpunkt Druckschmerz L4") == "Befund: Druckschmerz L4")
    #expect(
      SpokenPunctuation.apply(to: "Anamnese:\nDoppelpunkt Patientin berichtet\n\nBefund:\nunauffällig")
        == "Anamnese:\nPatientin berichtet\n\nBefund:\nunauffällig")
    #expect(SpokenPunctuation.apply(to: "Therapie: Doppelpunkt\nMobilisation") == "Therapie:\nMobilisation")
  }

  @Test("A clean structured reply passes through byte for byte")
  func structuredReplyUnchanged() {
    let reply = "Anamnese:\nSchmerzen LWS.\n\nBefund:\n(nicht diktiert)\n\nTherapie:\nMobilisation C6/C7."
    #expect(SpokenPunctuation.apply(to: reply) == reply)
  }

  @Test("The reply pass runs only when the instruction was spoken to an offline engine")
  func replyPassIsGated() {
    let reply = "Befund Doppelpunkt Druckschmerz"
    #expect(SpeechService.applyingSpokenLayout(reply, when: true) == "Befund: Druckschmerz")
    #expect(SpeechService.applyingSpokenLayout(reply, when: false) == reply)
  }

  // MARK: - Schrägstrich

  @Test("\"Schrägstrich\" becomes a slash with no spaces, only in spoken-only mode")
  func slash() {
    let mode = PunctuationMode.spokenOnly
    #expect(SpokenPunctuation.apply(to: "ich Schrägstrich sage", mode: mode) == "ich/sage")
    #expect(SpokenPunctuation.apply(to: "ich, Schrägstrich. sage", mode: mode) == "ich/sage")
    #expect(SpokenPunctuation.apply(to: "Hals Schraegstrich Nacken", mode: mode) == "Hals/Nacken")
    // Automatic mode and Dictate Prompt instructions: an ordinary noun.
    let text = "ersetze jeden Schrägstrich durch ein Komma, getrennt mit einem Schrägstrich"
    #expect(SpokenPunctuation.apply(to: text) == text)
    #expect(SpokenPunctuation.apply(to: "ich Schrägstrich sage") == "ich Schrägstrich sage")
  }

  @Test("Glued \"Schrägstrich\" splits; the plural stays")
  func slashGluedAndPlural() {
    let mode = PunctuationMode.spokenOnly
    #expect(SpokenPunctuation.apply(to: "Hals Schrägstrichnacken", mode: mode) == "Hals/nacken")
    #expect(SpokenPunctuation.apply(to: "zwei Schrägstriche im Text", mode: mode) == "zwei Schrägstriche im Text")
  }

  @Test("\"Schreckstrich\" and a split \"Schräg Strich\" become a slash; the plural stays")
  func slashMishearings() {
    let mode = PunctuationMode.spokenOnly
    #expect(SpokenPunctuation.apply(to: "Arbeitsmarkt Schreckstrich im ADL", mode: mode) == "Arbeitsmarkt/im ADL")
    #expect(SpokenPunctuation.apply(to: "Hals Schräg Strich Nacken", mode: mode) == "Hals/Nacken")
    #expect(SpokenPunctuation.apply(to: "Hals Schräg-Strich Nacken", mode: mode) == "Hals/Nacken")
    #expect(SpokenPunctuation.apply(to: "zwei Schrägstriche im Text", mode: mode) == "zwei Schrägstriche im Text")
  }

  @Test("\"drei Pünktchen\" becomes an ellipsis; \"drei Punkte\" and automatic mode stay")
  func ellipsis() {
    let mode = PunctuationMode.spokenOnly
    #expect(SpokenPunctuation.apply(to: "Gesamt GdB drei Pünktchen und", mode: mode) == "Gesamt GdB… und")
    #expect(SpokenPunctuation.apply(to: "Gesamt GdB drei Puenktchen und", mode: mode) == "Gesamt GdB… und")
    #expect(SpokenPunctuation.apply(to: "Gesamt GdB Auslassungspunkte und", mode: mode) == "Gesamt GdB… und")
    #expect(SpokenPunctuation.apply(to: "drei Punkte erreicht", mode: mode) == "drei Punkte erreicht")
    #expect(SpokenPunctuation.apply(to: "Gesamt GdB drei Pünktchen und") == "Gesamt GdB drei Pünktchen und")
  }

  @Test("An abbreviation period before \"Schrägstrich\" is kept")
  func slashKeepsAbbreviationPeriod() {
    let mode = PunctuationMode.spokenOnly
    let stripped = SpokenPunctuation.stripModelPunctuation(from: "usw. Schrägstrich b")
    #expect(SpokenPunctuation.apply(to: stripped, mode: mode) == "usw./b")
  }

  @Test("A spoken decimal comma between digits has no spaces")
  func decimalComma() {
    let mode = PunctuationMode.spokenOnly
    #expect(SpokenPunctuation.apply(to: "3 Komma 5 cm", mode: mode) == "3,5 cm")
    #expect(SpokenPunctuation.apply(to: "Hallo Komma 5 Stück", mode: mode) == "Hallo, 5 Stück")
    // Number words are the same decimal, one pair: "drei Komma fünf" → "3,5".
    #expect(SpokenPunctuation.apply(to: "drei Komma fünf", mode: mode) == "3,5")
  }

  @Test("Capitalisation carries over a line break after Punkt and Fragezeichen")
  func capitalisationAfterBreak() {
    let mode = PunctuationMode.spokenOnly
    #expect(SpokenPunctuation.apply(to: "Ende Punkt neue Zeile weiter", mode: mode) == "Ende.\nWeiter")
    #expect(SpokenPunctuation.apply(to: "Gut Fragezeichen neuer Absatz ja", mode: mode) == "Gut?\n\nJa")
  }

  @Test("The effective mode is stored only for offline dictation outside meetings")
  func effectiveMode() {
    #expect(PunctuationMode.effective(stored: .spokenOnly, isOffline: true, duringMeeting: true) == .automatic)
    #expect(PunctuationMode.effective(stored: .spokenOnly, isOffline: false, duringMeeting: false) == .automatic)
    #expect(PunctuationMode.effective(stored: .spokenOnly, isOffline: true, duringMeeting: false) == .spokenOnly)
    #expect(PunctuationMode.effective(stored: .automatic, isOffline: true, duringMeeting: false) == .automatic)
  }

  // MARK: - Only when spoken

  @Test("Stripping removes the model's commas, semicolons, question and exclamation marks; keeps . and :")
  func stripsModelPunctuation() {
    // Parakeet writes a spoken "Punkt" as "." itself, so the sentence marks stay and so do capitals.
    #expect(
      SpokenPunctuation.stripModelPunctuation(from: "Hallo, Welt. Wie geht's? Gut!")
        == "Hallo Welt. Wie geht's Gut")
    #expect(SpokenPunctuation.stripModelPunctuation(from: "Ende...") == "Ende...")
    #expect(SpokenPunctuation.stripModelPunctuation(from: "Befund: a; b, c.") == "Befund: a b c.")
  }

  @Test("A guessed question or exclamation mark goes; spoken ones still work")
  func stripsGuessedQuestionAndExclamationMarks() {
    #expect(spokenOnly("Die Dosis stimmt? Und weiter") == "Die Dosis stimmt und weiter")
    #expect(spokenOnly("Stimmt die Dosis Fragezeichen") == "Stimmt die Dosis?")
    #expect(spokenOnly("Stimmt die Dosis? Fragezeichen") == "Stimmt die Dosis?")
    #expect(spokenOnly("Wirklich! Ausrufezeichen") == "Wirklich!")
    // Nouns and the formal "Sie" keep their capital.
    #expect(spokenOnly("Stimmt das? Dosis gleich") == "Stimmt das Dosis gleich")
    #expect(spokenOnly("Geht es? Sie kommen") == "Geht es Sie kommen")
    #expect(SpokenPunctuation.stripModelPunctuation(from: "a?b und 1!2") == "a?b und 1!2")
  }

  @Test("Stripping keeps marks inside numbers and words")
  func stripKeepsNumbers() {
    #expect(SpokenPunctuation.stripModelPunctuation(from: "Wert 3.5 und 1,2 mg, ok.") == "Wert 3.5 und 1,2 mg ok.")
    #expect(SpokenPunctuation.stripModelPunctuation(from: "a.b") == "a.b")
  }

  @Test("Stripping keeps ordinals, dates and abbreviations and the model's sentence period")
  func stripKeepsOrdinalsAndAbbreviations() {
    let spoken = "Am 3. November untersuchte Dr. Müller z. B. Nr. 5 Punkt"
    #expect(
      SpokenPunctuation.apply(
        to: SpokenPunctuation.stripModelPunctuation(from: spoken), mode: .spokenOnly)
        == "Am 3. November untersuchte Dr. Müller z. B. Nr. 5.")
    #expect(SpokenPunctuation.stripModelPunctuation(from: "Der Befund ist unauffällig. Weiter, ok.") == "Der Befund ist unauffällig. Weiter ok.")
    #expect(SpokenPunctuation.stripModelPunctuation(from: "bis 5.") == "bis 5.")
    #expect(SpokenPunctuation.stripModelPunctuation(from: "5. Lendenwirbel") == "5. Lendenwirbel")
  }

  @Test("Abbreviation periods survive stripping")
  func stripKeepsMoreAbbreviations() {
    for text in [
      "Dr. med. Müller", "d. h. die", "Az. 12 SB 345/24", "i. d. R. stabil", "Hauptstr. 5",
      "geb. 12. 3. 1961",
    ] {
      #expect(SpokenPunctuation.stripModelPunctuation(from: text) == text)
    }
    #expect(SpokenPunctuation.stripModelPunctuation(from: "Er ging nach Hause. Dann kam sie.") == "Er ging nach Hause. Dann kam sie.")
  }

  @Test("A kept period followed by the model's comma loses only the comma")
  func keptPeriodThenComma() {
    #expect(SpokenPunctuation.stripModelPunctuation(from: "z. B., Kopfschmerzen") == "z. B. Kopfschmerzen")
  }

  @Test("\"Punkt\" before a number or after a preposition is the noun")
  func punktNoun() {
    let mode = PunctuationMode.spokenOnly
    #expect(SpokenPunctuation.apply(to: "Zu Punkt 3 der Beweisfragen", mode: mode) == "Zu Punkt 3 der Beweisfragen")
    #expect(SpokenPunctuation.apply(to: "Siehe Punkt 2.1", mode: mode) == "Siehe Punkt 2.1")
    #expect(SpokenPunctuation.apply(to: "Er kam um 9 Uhr Punkt neue Zeile die", mode: mode) == "Er kam um 9 Uhr.\nDie")
  }

  @Test("A kept abbreviation period survives a spoken Komma")
  func abbreviationThenKomma() {
    let stripped = SpokenPunctuation.stripModelPunctuation(from: "usw. Komma die")
    #expect(SpokenPunctuation.apply(to: stripped, mode: .spokenOnly) == "usw., die")
  }

  @Test("Decimal Komma only for a single pair of numbers")
  func decimalOnlySinglePair() {
    let mode = PunctuationMode.spokenOnly
    #expect(SpokenPunctuation.apply(to: "3 Komma 5 cm", mode: mode) == "3,5 cm")
    #expect(SpokenPunctuation.apply(to: "3 Komma 5 Komma 4", mode: mode) == "3, 5, 4")
  }

  @Test("After a sentence end the word after a spoken break gets a capital, in both modes")
  func capitalAfterBreakWithModelPeriod() {
    for mode in [PunctuationMode.automatic, .spokenOnly] {
      #expect(
        SpokenPunctuation.apply(to: "Anamnese. Neuer Absatz, die Klägerin", mode: mode)
          == "Anamnese.\n\nDie Klägerin")
      #expect(
        SpokenPunctuation.apply(to: "Ist sie arbeitsfähig? Neue Zeile, nein.", mode: mode)
          == "Ist sie arbeitsfähig?\nNein.")
    }
  }

  @Test("Spoken marks attach to the previous word with one space after")
  func spokenOnlyMarks() {
    let mode = PunctuationMode.spokenOnly
    #expect(SpokenPunctuation.apply(to: "Hallo Komma wie geht es Fragezeichen", mode: mode) == "Hallo, wie geht es?")
    #expect(SpokenPunctuation.apply(to: "Gut Ausrufezeichen danke", mode: mode) == "Gut! Danke")
    #expect(SpokenPunctuation.apply(to: "Das ist alles Punkt Weiter", mode: mode) == "Das ist alles. Weiter")
    #expect(SpokenPunctuation.apply(to: "Ende Punkt", mode: mode) == "Ende.")
  }

  @Test("Doppelpunkt and layout commands still work in spoken-only mode")
  func spokenOnlyKeepsLayout() {
    let mode = PunctuationMode.spokenOnly
    #expect(SpokenPunctuation.apply(to: "Befund Doppelpunkt Druck Punkt neuer Absatz Therapie", mode: mode) == "Befund: Druck.\n\nTherapie")
  }

  @Test("Punkt, Komma and friends are ordinary words in automatic mode")
  func automaticLeavesWordsAlone() {
    let text = "der wichtigste Punkt und ein Komma im Text"
    #expect(SpokenPunctuation.apply(to: text) == text)
    #expect(SpokenPunctuation.apply(to: text, mode: .automatic) == text)
    #expect(SpokenPunctuation.apply(to: "Doppelpunkte und Kommas", mode: .spokenOnly) == "Doppelpunkte und Kommas")
  }

  @Test("keepsEdgeBreaks keeps a trailing paragraph/line break; the default still trims it")
  func keepsEdgeBreaksTrimsSpacesOnly() {
    #expect(SpokenPunctuation.apply(to: "Befund neuer Absatz", keepsEdgeBreaks: true) == "Befund\n\n")
    #expect(SpokenPunctuation.apply(to: "Befund neuer Absatz") == "Befund")
    #expect(SpokenPunctuation.apply(to: "Erste Zeile neue Zeile", keepsEdgeBreaks: true) == "Erste Zeile\n")
    #expect(SpokenPunctuation.apply(to: "  Befund neuer Absatz  ", keepsEdgeBreaks: true) == "Befund\n\n")
  }

  /// The order Dictate uses: drop the model's marks, then the spoken-only commands.
  private func spokenOnly(_ text: String) -> String {
    SpokenPunctuation.apply(
      to: SpokenPunctuation.stripModelPunctuation(from: text), mode: .spokenOnly)
  }

  @Test("Dates and clinical abbreviations keep their period")
  func stripKeepsDatesAndClinicalAbbreviations() {
    #expect(spokenOnly("Seit dem 12. März.") == "Seit dem 12. März.")
    #expect(spokenOnly("Pat. ist mobil.") == "Pat. ist mobil.")
  }

  @Test("\"Punkt\" before a digit or a number word is the noun")
  func punktBeforeNumberWordStays() {
    #expect(spokenOnly("unter Punkt 3 der Fragen") == "unter Punkt 3 der Fragen")
    #expect(spokenOnly("Unter Punkt drei steht") == "Unter Punkt drei steht")
  }

  @Test("A decimal comma between number words becomes digits, and only in spoken-only mode")
  func decimalCommaBetweenNumberWords() {
    #expect(spokenOnly("Messwert zwei Komma fünf") == "Messwert 2,5")
    let automatic = "zwei Komma fünf"
    #expect(SpokenPunctuation.apply(to: automatic, mode: .automatic) == automatic)
  }

  @Test("A repeated spoken mark collapses to one and still capitalises the next word")
  func repeatedSpokenMarksCollapse() {
    #expect(spokenOnly("Ende Punkt Punkt weiter") == "Ende. Weiter")
  }

  @Test("The model's sentence period and the capital after it are kept; its comma is dropped")
  func modelPeriodAndCapitalKept() {
    #expect(spokenOnly("Sie klagt. Über Schmerzen.") == "Sie klagt. Über Schmerzen.")
    #expect(spokenOnly("Befund. Seit gestern") == "Befund. Seit gestern")
    #expect(spokenOnly("Wir bitten, Sie um Antwort") == "Wir bitten Sie um Antwort")
    #expect(spokenOnly("klagt. Punkt Über") == "klagt. Über")
  }

  @Test("Spoken-only formatting keeps the capital but adds no trailing period")
  func formattingWithoutPeriod() {
    let manager = ClipboardManager(pasteboard: .withUniqueName())
    #expect(manager.formatTranscription("hallo welt", addTrailingPeriod: false) == "Hallo welt")
    #expect(manager.formatTranscription("hallo welt") == "Hallo welt.")
  }

  @Test("A spoken mark next to a kept model mark does not double")
  func spokenMarkNextToModelMark() {
    #expect(spokenOnly("Gangbild Komma geht weiter. Punkt.") == "Gangbild, geht weiter.")
    #expect(spokenOnly("Neue Befunde liegen nicht vor Punkt.") == "Neue Befunde liegen nicht vor.")
    #expect(spokenOnly("Neue Befunde liegen nicht vor. Punkt") == "Neue Befunde liegen nicht vor.")
    #expect(spokenOnly("Gehstrecke unter 500 m Punkt.") == "Gehstrecke unter 500 m.")
    #expect(spokenOnly("Gut. Fragezeichen") == "Gut?")
    #expect(spokenOnly("Gut! Ausrufezeichen danke") == "Gut! Danke")
  }

  @Test("Spoken-only: Schrägstrich glued to the neighbouring words")
  func gluedSlash() {
    #expect(spokenOnly("Arbeitsmarktschrägstrich im ADL") == "Arbeitsmarkt/im ADL")
    #expect(spokenOnly("Arbeitsmarktschrägstrichbewegung") == "Arbeitsmarkt/Bewegung")
    // Only glued on both sides is capitalised; the plural and the plain noun are untouched.
    #expect(spokenOnly("Die Schrägstriche fehlen") == "Die Schrägstriche fehlen")
    #expect(spokenOnly("Arbeitsmarkt Schrägstrichbewegung") == "Arbeitsmarkt/bewegung")
    #expect(
      SpokenPunctuation.apply(to: "Arbeitsmarktschrägstrich im ADL") == "Arbeitsmarktschrägstrich im ADL")
  }

  @Test("Spoken-only: the three dots in their glued and digit forms")
  func gluedEllipsis() {
    #expect(spokenOnly("Gesamt GDB3-Pünktchen und") == "Gesamt GDB… und")
    #expect(spokenOnly("Gesamt GDB 3 Pünktchen und") == "Gesamt GDB… und")
    #expect(spokenOnly("Gesamt GDB drei-Pünktchen und") == "Gesamt GDB… und")
    #expect(spokenOnly("Es gibt 13 Pünktchen") == "Es gibt 13 Pünktchen")
  }
}

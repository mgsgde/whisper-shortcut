import AppKit
import Testing

@testable import WhisperShortcut_AppStore

/// Offline engines (Parakeet, local Whisper) write spoken layout commands out as words. The
/// conversion is deterministic and deliberately narrow, so both halves are pinned: what changes,
/// and the ordinary German words that must not.
@Suite("Spoken punctuation (offline dictation)")
struct SpokenPunctuationTests {

  @Test("\"neuer Absatz\" becomes a blank line; a comma before it ends the sentence")
  func paragraphBreak() {
    #expect(
      SpokenPunctuation.apply(to: "Patient klagt über Schmerzen, neuer Absatz, Befund unauffällig")
        == "Patient klagt über Schmerzen.\n\nBefund unauffällig")
    #expect(
      SpokenPunctuation.apply(to: "Patient klagt über Schmerzen. Neuer Absatz. Befund unauffällig")
        == "Patient klagt über Schmerzen.\n\nBefund unauffällig")
  }

  @Test("\"neue Zeile\" becomes a line break and capitalises the next line")
  func lineBreak() {
    // A spoken break starts the next line even without ".!?" before it, so the next word
    // gains a capital. It used to stay lower-case ("zweite").
    #expect(
      SpokenPunctuation.apply(to: "Erste Zeile neue Zeile zweite Zeile")
        == "Erste Zeile\nZweite Zeile")
  }

  /// Parakeet with token timing keeps the comma it already wrote, then the spoken commands run.
  /// Without timings, stripping would delete that comma and the ", ma" leftover would never
  /// reach the rule.
  private func spokenOnly(_ text: String) -> String {
    SpokenPunctuation.apply(
      to: SpokenPunctuation.stripModelPunctuation(from: text, timedMarks: true),
      mode: .spokenOnly, timedMarks: true)
  }

  @Test("A spoken Komma before a pause comes back as \", ma\"; the leftover word goes")
  func splitKommaBeforePause() {
    #expect(spokenOnly("Heute ist ein schöner Tag, ma") == "Heute ist ein schöner Tag,")
    #expect(spokenOnly("Tag, ma und ich probiere") == "Tag, und ich probiere")
    let withPeriod = spokenOnly("Tag, ma.")
    #expect(!withPeriod.contains("ma"))
    #expect(withPeriod == "Tag.")
    // Another mark after the stray "ma": the later mark wins, the comma goes.
    #expect(spokenOnly("Heute ist ein schöner Tag, ma.") == "Heute ist ein schöner Tag.")
    #expect(spokenOnly("Tag, ma, und") == "Tag, und")
    #expect(spokenOnly("Tag, ma ?") == "Tag?")
    #expect(spokenOnly("Komm, Mama kommt") == "Komm, Mama kommt")
    #expect(spokenOnly("Er sagt, man kann") == "Er sagt, man kann")
    #expect(spokenOnly("Ich will, mal sehen") == "Ich will, mal sehen")
    #expect(spokenOnly("Tag, machen wir") == "Tag, machen wir")
    #expect(spokenOnly("Tag, Ma kommt") == "Tag, Ma kommt")
    #expect(
      SpokenPunctuation.apply(to: "Heute ist ein schöner Tag, ma")
        == "Heute ist ein schöner Tag, ma")
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

}

@Suite("Spoken colon, Parakeet Ultra mishearings (live capture 2026-11-10)")
struct SpokenColonMishearingTests {
  @Test("\"Doppelgun\" is the colon command, commas around it as Parakeet wrote them")
  func doppelgun() {
    let piece = LiveDictation.finishPiece("Symptome, Doppelgun, Kopfschmerzen.", mode: .spokenOnly)
    #expect(piece == "Symptome: Kopfschmerzen.")
  }

  @Test("A lone spoken colon with Parakeet's leading \"Oh,\" is just the colon")
  func leadingOh() {
    #expect(LiveDictation.finishPiece("Oh, Doppelpunkt.", mode: .spokenOnly).trimmingCharacters(in: .whitespaces) == ":")
  }

  @Test("Real words stay: \"Oh\" elsewhere, Doppelgänger, Doppelpunkte")
  func realWordsStay() {
    #expect(LiveDictation.finishPiece("Oh, das ist gut.", mode: .spokenOnly) == "Oh das ist gut.")
    #expect(SpokenPunctuation.apply(to: "Der Doppelgänger kam") == "Der Doppelgänger kam")
    #expect(SpokenPunctuation.apply(to: "Die Doppelpunkte fehlen") == "Die Doppelpunkte fehlen")
  }
}

@Suite("Spoken colon, hyphen glued before the command")
struct SpokenColonHyphenTests {
  @Test("Parakeet writes \"Anamnese-Doppelpunkt\"; the hyphen goes with the command")
  func hyphenBeforeColon() {
    #expect(LiveDictation.finishPiece("An amnese-Doppelpunkt", mode: .spokenOnly) == "An amnese:")
    #expect(SpokenPunctuation.apply(to: "Anamnese-Doppelpunkt seit drei Tagen") == "Anamnese: seit drei Tagen")
    #expect(SpokenPunctuation.apply(to: "Befund-Doppelpunktdruckschmerz") == "Befund: Druckschmerz")
  }

  @Test("A real hyphen not followed by the command stays")
  func realHyphenStays() {
    #expect(SpokenPunctuation.apply(to: "Röntgen-Thorax") == "Röntgen-Thorax")
  }
}

/// Cases carried over from the parallel implementation in PR #109.
@Suite("Spoken punctuation — additional cases")
struct SpokenPunctuationExtraTests {

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

  @Test("The reply pass runs only when the instruction was spoken to an offline engine")
  func replyPassIsGated() {
    let reply = "Befund Doppelpunkt Druckschmerz"
    #expect(SpeechService.applyingSpokenLayout(reply, when: true) == "Befund: Druckschmerz")
    #expect(SpeechService.applyingSpokenLayout(reply, when: false) == reply)
  }

  // MARK: - Schrägstrich

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

}

/// Which pipeline a table row runs: plain `apply`, `apply` with a mode, or Dictate's order of
/// stripping the model's marks first and then applying the spoken-only commands.
enum SPPipe: Sendable { case plain, automatic, spoken, stripThenSpoken, strip }

private func spRun(_ pipe: SPPipe, _ input: String) -> String {
  switch pipe {
  case .plain: return SpokenPunctuation.apply(to: input)
  case .automatic: return SpokenPunctuation.apply(to: input, mode: .automatic)
  case .spoken: return SpokenPunctuation.apply(to: input, mode: .spokenOnly)
  case .stripThenSpoken:
    return SpokenPunctuation.apply(to: SpokenPunctuation.stripModelPunctuation(from: input), mode: .spokenOnly)
  case .strip: return SpokenPunctuation.stripModelPunctuation(from: input)
  }
}

private func expectRow(_ pipe: SPPipe, _ input: String, _ expected: String) {
  #expect(spRun(pipe, input) == expected, "\(pipe): \(input)")
}

@Suite("Spoken punctuation — tables")
struct SpokenPunctuationTableTests {

  @Test("Colon command: attaches, eats stray punctuation, ignores case, keeps hyphenated words", arguments: [
    (SPPipe.plain, "Anamnese Doppelpunkt Patient berichtet über Schmerzen", "Anamnese: Patient berichtet über Schmerzen"),
    (.plain, "Befund, Doppelpunkt. Inspektion", "Befund: Inspektion"),
    (.plain, "Befund. Doppelpunkt, Inspektion", "Befund: Inspektion"),
    (.plain, "Therapie Doppelpunkt.", "Therapie:"),
    (.plain, "Befund doppelpunkt Inspektion", "Befund: Inspektion"),
    (.plain, "Befund DOPPELPUNKT Inspektion", "Befund: Inspektion"),
    (.plain, "Anamnese Doppelpunkt LWS-Schmerzen seit drei Wochen.", "Anamnese: LWS-Schmerzen seit drei Wochen."),
    (.plain, "Anamnese, Doppelpunkt. Patient berichtet", "Anamnese: Patient berichtet"),
  ])
  func colon(pipe: SPPipe, input: String, expected: String) { expectRow(pipe, input, expected) }

  @Test("Ordinary words, whole-word matching, plurals and clean replies pass through unchanged", arguments: [
    (SPPipe.plain, "Der wichtigste Punkt ist das Komma und das Fragezeichen am Ende."),
    (.plain, "Die Doppelpunkte und der Absatzmarke bleiben."),
    (.plain, "  Patient berichtet über Schmerzen im unteren Rücken.\n"),
    (.plain, "der wichtigste Punkt und ein Komma im Text"),
    (.automatic, "der wichtigste Punkt und ein Komma im Text"),
    (.spoken, "Doppelpunkte und Kommas"),
    (.plain, "Bitte zwei neue Zeilen einfügen, neue Zeilenumbrüche vermeiden."),
    // "Neuzeilen" is the plural glued into one word, not the command. "Neue Teile" is a real phrase.
    (.plain, "Neuzeilen bleiben."),
    (.plain, "Neue Teile bestellen."),
    (.plain, "Anamnese:\nSchmerzen LWS.\n\nBefund:\n(nicht diktiert)\n\nTherapie:\nMobilisation C6/C7."),
  ])
  func unchanged(pipe: SPPipe, text: String) { expectRow(pipe, text, text) }

  @Test("Schrägstrich becomes a slash in spoken-only mode only; glued, misheard and split forms too", arguments: [
    (SPPipe.spoken, "ich Schrägstrich sage", "ich/sage"),
    (.spoken, "ich, Schrägstrich. sage", "ich/sage"),
    (.spoken, "Hals Schraegstrich Nacken", "Hals/Nacken"),
    // Automatic mode and Dictate Prompt instructions: an ordinary noun.
    (.plain, "ersetze jeden Schrägstrich durch ein Komma, getrennt mit einem Schrägstrich",
     "ersetze jeden Schrägstrich durch ein Komma, getrennt mit einem Schrägstrich"),
    (.plain, "ich Schrägstrich sage", "ich Schrägstrich sage"),
    (.spoken, "Hals Schrägstrichnacken", "Hals/nacken"),
    (.spoken, "zwei Schrägstriche im Text", "zwei Schrägstriche im Text"),
    (.spoken, "Arbeitsmarkt Schreckstrich im ADL", "Arbeitsmarkt/im ADL"),
    (.spoken, "Hals Schräg Strich Nacken", "Hals/Nacken"),
    (.spoken, "Hals Schräg-Strich Nacken", "Hals/Nacken"),
    (.stripThenSpoken, "Arbeitsmarktschrägstrich im ADL", "Arbeitsmarkt/im ADL"),
    (.stripThenSpoken, "Arbeitsmarktschrägstrichbewegung", "Arbeitsmarkt/Bewegung"),
    // Only glued on both sides is capitalised; the plural and the plain noun are untouched.
    (.stripThenSpoken, "Die Schrägstriche fehlen", "Die Schrägstriche fehlen"),
    (.stripThenSpoken, "Arbeitsmarkt Schrägstrichbewegung", "Arbeitsmarkt/bewegung"),
    (.plain, "Arbeitsmarktschrägstrich im ADL", "Arbeitsmarktschrägstrich im ADL"),
    // An abbreviation period before "Schrägstrich" is kept.
    (.stripThenSpoken, "usw. Schrägstrich b", "usw./b"),
  ])
  func slash(pipe: SPPipe, input: String, expected: String) { expectRow(pipe, input, expected) }

  @Test("Three dots: spoken and glued forms become an ellipsis; \"drei Punkte\" and automatic mode stay", arguments: [
    (SPPipe.spoken, "Gesamt GdB drei Pünktchen und", "Gesamt GdB… und"),
    (.spoken, "Gesamt GdB drei Puenktchen und", "Gesamt GdB… und"),
    (.spoken, "Gesamt GdB Auslassungspunkte und", "Gesamt GdB… und"),
    (.spoken, "drei Punkte erreicht", "drei Punkte erreicht"),
    (.plain, "Gesamt GdB drei Pünktchen und", "Gesamt GdB drei Pünktchen und"),
    (.stripThenSpoken, "Gesamt GDB3-Pünktchen und", "Gesamt GDB… und"),
    (.stripThenSpoken, "Gesamt GDB 3 Pünktchen und", "Gesamt GDB… und"),
    (.stripThenSpoken, "Gesamt GDB drei-Pünktchen und", "Gesamt GDB… und"),
    (.stripThenSpoken, "Es gibt 13 Pünktchen", "Es gibt 13 Pünktchen"),
  ])
  func ellipsis(pipe: SPPipe, input: String, expected: String) { expectRow(pipe, input, expected) }

  @Test("Decimal Komma: digits and number words, a single pair only, spoken-only mode only", arguments: [
    (SPPipe.spoken, "3 Komma 5 cm", "3,5 cm"),
    (.spoken, "Hallo Komma 5 Stück", "Hallo, 5 Stück"),
    // Number words are the same decimal, one pair: "drei Komma fünf" -> "3,5".
    (.spoken, "drei Komma fünf", "3,5"),
    (.spoken, "3 Komma 5 Komma 4", "3, 5, 4"),
    (.stripThenSpoken, "Messwert zwei Komma fünf", "Messwert 2,5"),
    (.automatic, "zwei Komma fünf", "zwei Komma fünf"),
  ])
  func decimal(pipe: SPPipe, input: String, expected: String) { expectRow(pipe, input, expected) }

  @Test("Stripping keeps marks in numbers, ordinals, dates and abbreviations; only the model's commas go", arguments: [
    (SPPipe.strip, "Wert 3.5 und 1,2 mg, ok.", "Wert 3.5 und 1,2 mg ok."),
    (.strip, "a.b", "a.b"),
    (.stripThenSpoken, "Am 3. November untersuchte Dr. Müller z. B. Nr. 5 Punkt",
     "Am 3. November untersuchte Dr. Müller z. B. Nr. 5."),
    (.strip, "Der Befund ist unauffällig. Weiter, ok.", "Der Befund ist unauffällig. Weiter ok."),
    (.strip, "bis 5.", "bis 5."),
    (.strip, "5. Lendenwirbel", "5. Lendenwirbel"),
    (.strip, "Dr. med. Müller", "Dr. med. Müller"),
    (.strip, "d. h. die", "d. h. die"),
    (.strip, "Az. 12 SB 345/24", "Az. 12 SB 345/24"),
    (.strip, "i. d. R. stabil", "i. d. R. stabil"),
    (.strip, "Hauptstr. 5", "Hauptstr. 5"),
    (.strip, "geb. 12. 3. 1961", "geb. 12. 3. 1961"),
    (.strip, "Er ging nach Hause. Dann kam sie.", "Er ging nach Hause. Dann kam sie."),
    (.strip, "z. B., Kopfschmerzen", "z. B. Kopfschmerzen"),
    (.stripThenSpoken, "Seit dem 12. März.", "Seit dem 12. März."),
    (.stripThenSpoken, "Pat. ist mobil.", "Pat. ist mobil."),
  ])
  func strip(pipe: SPPipe, input: String, expected: String) { expectRow(pipe, input, expected) }

  @Test("\"Punkt\" before a number or after a preposition is the noun", arguments: [
    (SPPipe.spoken, "Zu Punkt 3 der Beweisfragen", "Zu Punkt 3 der Beweisfragen"),
    (.spoken, "Siehe Punkt 2.1", "Siehe Punkt 2.1"),
    (.spoken, "Er kam um 9 Uhr Punkt neue Zeile die", "Er kam um 9 Uhr.\nDie"),
    (.stripThenSpoken, "unter Punkt 3 der Fragen", "unter Punkt 3 der Fragen"),
    (.stripThenSpoken, "Unter Punkt drei steht", "Unter Punkt drei steht"),
  ])
  func punktNoun(pipe: SPPipe, input: String, expected: String) { expectRow(pipe, input, expected) }

  @Test("The word after a spoken break gets a capital, also after the model's period, in both modes", arguments: [
    (SPPipe.spoken, "Ende Punkt neue Zeile weiter", "Ende.\nWeiter"),
    // The next line starts a sentence even without ".!?" before the break.
    (.plain, "Erstens neue Zeile zweitens", "Erstens\nZweitens"),
    (.spoken, "Gut Fragezeichen neuer Absatz ja", "Gut?\n\nJa"),
    (.automatic, "Anamnese. Neuer Absatz, die Klägerin", "Anamnese.\n\nDie Klägerin"),
    (.spoken, "Anamnese. Neuer Absatz, die Klägerin", "Anamnese.\n\nDie Klägerin"),
    (.automatic, "Ist sie arbeitsfähig? Neue Zeile, nein.", "Ist sie arbeitsfähig?\nNein."),
    (.spoken, "Ist sie arbeitsfähig? Neue Zeile, nein.", "Ist sie arbeitsfähig?\nNein."),
  ])
  func capitalAfterBreak(pipe: SPPipe, input: String, expected: String) { expectRow(pipe, input, expected) }

  @Test("Spoken-only marks attach to the previous word, collapse, and never double a kept model mark", arguments: [
    (SPPipe.spoken, "Hallo Komma wie geht es Fragezeichen", "Hallo, wie geht es?"),
    (.spoken, "Gut Ausrufezeichen danke", "Gut! Danke"),
    (.spoken, "Das ist alles Punkt Weiter", "Das ist alles. Weiter"),
    (.spoken, "Ende Punkt", "Ende."),
    // Doppelpunkt and layout commands still work in spoken-only mode.
    (.spoken, "Befund Doppelpunkt Druck Punkt neuer Absatz Therapie", "Befund: Druck.\n\nTherapie"),
    // A repeated spoken mark collapses to one and still capitalises the next word.
    (.stripThenSpoken, "Ende Punkt Punkt weiter", "Ende. Weiter"),
    (.stripThenSpoken, "Gangbild Komma geht weiter. Punkt.", "Gangbild, geht weiter."),
    (.stripThenSpoken, "Neue Befunde liegen nicht vor Punkt.", "Neue Befunde liegen nicht vor."),
    (.stripThenSpoken, "Neue Befunde liegen nicht vor. Punkt", "Neue Befunde liegen nicht vor."),
    (.stripThenSpoken, "Gehstrecke unter 500 m Punkt.", "Gehstrecke unter 500 m."),
    (.stripThenSpoken, "Gut. Fragezeichen", "Gut?"),
    (.stripThenSpoken, "Gut! Ausrufezeichen danke", "Gut! Danke"),
    // A kept abbreviation period survives a spoken Komma.
    (.stripThenSpoken, "usw. Komma die", "usw., die"),
  ])
  func spokenMarks(pipe: SPPipe, input: String, expected: String) { expectRow(pipe, input, expected) }
}

/// Brackets, Parakeet's glued "Neuzeile" / "Neuerabsatz", and a capital after a break that has no
/// sentence mark in front of it.
@Suite("Spoken punctuation — brackets and glued breaks")
struct SpokenPunctuationBracketTests {

  @Test("\"Klammer auf\" / \"Klammer zu\" become parentheses, in both modes")
  func brackets() {
    let cases = [
      (
        "Durch die Updates ist es Klammer auf soweit ich das beurteilen kann Klammer zu deutlich besser geworden.",
        "Durch die Updates ist es (soweit ich das beurteilen kann) deutlich besser geworden."
      ),
      (
        "Sobald ich Klammer auf wahrscheinlich morgen Klammer zu mehr arbeite.",
        "Sobald ich (wahrscheinlich morgen) mehr arbeite."
      ),
      ("Siehe unten Klammer auf Anlage Klammer zu.", "Siehe unten (Anlage)."),
      ("Klammer auf siehe Anlage Klammer zu", "(siehe Anlage)"),
      ("es, Klammer auf, soweit, Klammer zu, deutlich", "es (soweit) deutlich"),
    ]
    for mode in [PunctuationMode.automatic, .spokenOnly] {
      for (spoken, written) in cases {
        #expect(SpokenPunctuation.apply(to: spoken, mode: mode) == written)
      }
    }
  }

  @Test("Glued and hyphenated \"Klammerauf\" / \"Klammer-zu\" are the same command")
  func bracketsGlued() {
    #expect(
      SpokenPunctuation.apply(to: "Siehe Klammerauf Anlage Klammer-zu.")
        == "Siehe (Anlage).")
    #expect(SpokenPunctuation.apply(to: "es Klammer-auf soweit Klammerzu deutlich") == "es (soweit) deutlich")
  }

  @Test("\"Klammer\" as a noun, and \"Klammer auf\" plus an article, stay words")
  func bracketsStayNouns() {
    for text in [
      "Die Hautklammer wurde entfernt.",
      "Zwei Klammern auf der Wunde.",
      "Eine Klammer auf die Wunde gesetzt.",
    ] {
      #expect(SpokenPunctuation.apply(to: text) == text)
      #expect(SpokenPunctuation.apply(to: text, mode: .spokenOnly) == text)
    }
  }

  @Test("A trailing \"Klammer auf\" keeps its parenthesis when edge breaks are kept")
  func openingParenSurvivesEdgeTrim() {
    #expect(
      SpokenPunctuation.apply(to: "ist es Klammer auf", mode: .spokenOnly, keepsEdgeBreaks: true)
        == "ist es (")
  }

  @Test("Glued \"Neuzeile\" / \"Neuerabsatz\" break the line like the spaced command")
  func gluedBreaks() {
    #expect(
      SpokenPunctuation.apply(to: "Update. Neuzeile die Fehler habe ich bewusst gelassen.")
        == "Update.\nDie Fehler habe ich bewusst gelassen.")
    // The command is the whole trailing word, so only the line break is left and then trimmed.
    #expect(SpokenPunctuation.apply(to: "einen schönen Sonntag Neuezeile") == "einen schönen Sonntag")
    #expect(SpokenPunctuation.apply(to: "Befund Neuerabsatz Therapie") == "Befund\n\nTherapie")
    #expect(SpokenPunctuation.apply(to: "Befund Neuenabsatz Therapie") == "Befund\n\nTherapie")
  }

  @Test("A plain break capitalises the next line; a pause comma before neue Zeile is eaten")
  func capitalAfterPlainBreak() {
    #expect(
      SpokenPunctuation.apply(to: "Liebe Grüße und einen schönen Sonntag neue Zeile wie gesagt")
        == "Liebe Grüße und einen schönen Sonntag\nWie gesagt")
    // The model's pause comma is eaten; the next word keeps the case it was spoken with.
    let comma = "Hallo Herr Müller, neue Zeile vielen Dank"
    let eaten = "Hallo Herr Müller\nvielen Dank"
    #expect(SpokenPunctuation.apply(to: comma) == eaten)
    #expect(SpokenPunctuation.apply(to: comma, mode: .spokenOnly) == eaten)
    #expect(SpokenPunctuation.apply(to: "Befund, neue Zeile Inspektion") == "Befund\nInspektion")
    // Spoken "Komma" becomes the comma only in spoken-only mode, after the break was inserted,
    // so the comma stays and "vielen" stays lower-case.
    #expect(
      SpokenPunctuation.apply(
        to: "Hallo Herr Müller Komma neue Zeile vielen Dank", mode: .spokenOnly)
        == "Hallo Herr Müller,\nvielen Dank")
    // ", neuer Absatz" still ends the sentence with a period and does not add its own capital.
    #expect(
      SpokenPunctuation.apply(to: "Schmerzen, neuer Absatz befund")
        == "Schmerzen.\n\nbefund")
  }

  @Test("\"Doppel Punkt\" is a colon in both modes, not a period after \"Doppel\"")
  func splitDoppelPunkt() {
    let spoken = "Befund Doppel Punkt Druckschmerz"
    let written = "Befund: Druckschmerz"
    #expect(SpokenPunctuation.apply(to: spoken) == written)
    #expect(SpokenPunctuation.apply(to: spoken, mode: .spokenOnly) == written)
    #expect(SpokenPunctuation.apply(to: "Befund Doppel-Punkt Druckschmerz", mode: .spokenOnly) == written)
  }

  // MARK: Round 19 false positives (R194)

  @Test("Automatic mode: \"Klammer zu\" needs an open parenthesis before it")
  func closingParenNeedsOpenParen() {
    #expect(SpokenPunctuation.apply(to: "um die Klammer zu entfernen") == "um die Klammer zu entfernen")
    #expect(SpokenPunctuation.apply(to: "Die Klammer zu lösen war schwer") == "Die Klammer zu lösen war schwer")
    #expect(SpokenPunctuation.apply(to: "Klammer auf Test Klammer zu") == "(Test)")
    // Spoken-only decodes piece by piece: a lone closing half still converts there.
    #expect(SpokenPunctuation.apply(to: "Ramipril Klammer zu", mode: .spokenOnly) == "Ramipril)")
  }

  @Test("\"neue Zeile\" after an article is the noun phrase")
  func newLineAfterArticleIsNoun() {
    let text = "Füge eine neue Zeile in der Tabelle ein"
    #expect(SpokenPunctuation.apply(to: text) == text)
    #expect(SpokenPunctuation.apply(to: text, mode: .spokenOnly) == text)
    #expect(SpokenPunctuation.apply(to: "Befund neue Zeile Inspektion") == "Befund\nInspektion")
  }

  @Test("\"Doppelpunktsetzung\" is a compound noun, not a colon")
  func doppelpunktCompound() {
    #expect(SpokenPunctuation.apply(to: "Befund Doppelpunktsetzung") == "Befund Doppelpunktsetzung")
  }

  @Test("Spoken-only: \"um Punkt acht Uhr\" is a time")
  func punktAfterUmIsNoun() {
    #expect(
      SpokenPunctuation.apply(to: "Er kam um Punkt acht Uhr", mode: .spokenOnly)
        == "Er kam um Punkt acht Uhr")
  }

  @Test("A written ellipsis survives; duplicate marks still collapse")
  func ellipsisKept() {
    #expect(SpokenPunctuation.apply(to: "usw... und so Punkt", mode: .spokenOnly).hasPrefix("usw..."))
    #expect(SpokenPunctuation.apply(to: "usw\u{2026} und so Punkt", mode: .spokenOnly).hasPrefix("usw\u{2026}"))
    #expect(SpokenPunctuation.apply(to: "vor. Punkt Ende", mode: .spokenOnly) == "vor. Ende")
  }
}

import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Regression tests for the pilot doctor's path: Parakeet, Dictate Live, "Only when spoken".
/// Pure logic: the text Parakeet hands over (after token timing) →
/// `LiveDictation.finishPiece` (`timedMarks: true`) → `LiveChunkJoiner` (holdsPeriods = false).
/// Found by an independent bug hunt on v8.85; each test pins the fixed behaviour.
@Suite("Spoken-only pilot path")
struct SpokenPunctuationPilotTests {

  /// No glossary-echo strip: Parakeet has no prompt, so `SpeechService.canEchoGlossary` is false
  /// for it and a dictated glossary term at the end must reach the text.
  static func pipeline(_ pieces: [String]) -> String {
    var joiner = LiveChunkJoiner()
    joiner.holdsPeriods = false
    var out = ""
    for piece in pieces {
      out += joiner.next(LiveDictation.finishPiece(piece, mode: .spokenOnly, timedMarks: true))
    }
    out += joiner.finish()
    return out
  }

  static func show(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: "⏎")
  }

  static func check(_ pieces: [String], _ expected: String, label: String) {
    let actual = pipeline(pieces)
    #expect(actual == expected, "\(label): got «\(show(actual))»")
  }

  // MARK: Salutation / comma before a break

  @Test func commaBeforeNewLineWrittenAsMark() {
    Self.check(
      ["Sehr geehrte Frau Müller, neue Zeile vielen Dank für Ihre Nachricht."],
      "Sehr geehrte Frau Müller,\nvielen Dank für Ihre Nachricht.", label: "A1 ', neue Zeile'")
  }

  @Test func commaBeforeNewParagraphWrittenAsMark() {
    Self.check(
      ["Sehr geehrte Damen und Herren, neuer Absatz wir haben Ihre Patientin gesehen."],
      "Sehr geehrte Damen und Herren,\n\nwir haben Ihre Patientin gesehen.", label: "A2 ', neuer Absatz'")
  }

  @Test func commaWordBeforeNewParagraph() {
    Self.check(
      ["Sehr geehrte Damen und Herren Komma neuer Absatz wir haben Ihre Patientin gesehen Punkt"],
      "Sehr geehrte Damen und Herren,\n\nwir haben Ihre Patientin gesehen.", label: "A2b 'Komma neuer Absatz' as words")
  }

  @Test func salutationAcrossPiecesNewLineInSecond() {
    Self.check(
      ["Sehr geehrte Frau Müller Komma", "Neue Zeile vielen Dank"],
      "Sehr geehrte Frau Müller,\nvielen Dank", label: "A3 'Komma' | 'neue Zeile vielen'")
  }

  @Test func salutationAcrossPiecesNewLineInFirst() {
    Self.check(
      ["Sehr geehrte Frau Müller Komma neue Zeile", "Vielen Dank"],
      "Sehr geehrte Frau Müller,\nvielen Dank", label: "A4 'Komma neue Zeile' | 'Vielen'")
  }

  @Test func salutationAcrossPiecesFunctionWord() {
    Self.check(
      ["Sehr geehrte Frau Müller Komma neue Zeile", "Wir freuen uns"],
      "Sehr geehrte Frau Müller,\nwir freuen uns", label: "A5 'Komma neue Zeile' | 'Wir'")
  }

  @Test func salutationSinglePieceWords() {
    Self.check(
      ["Sehr geehrte Frau Müller Komma neue Zeile vielen Dank"],
      "Sehr geehrte Frau Müller,\nvielen Dank", label: "A6 one piece, words")
  }

  // MARK: Brackets

  @Test func bracketOpeningWithArticle() {
    Self.check(
      ["Der Befund Klammer auf die Laborwerte liegen bei Klammer zu ist unauffällig Punkt"],
      "Der Befund (die Laborwerte liegen bei) ist unauffällig.", label: "B1 'Klammer auf die …'")
  }

  @Test func bracketOpeningWithArticleEine() {
    Self.check(
      ["Wir empfehlen Klammer auf eine Kontrolle in drei Monaten Klammer zu Punkt"],
      "Wir empfehlen (eine Kontrolle in drei Monaten).", label: "B1b 'Klammer auf eine …'")
  }

  @Test func bracketClosingThenPeriod() {
    Self.check(
      ["Zustand nach Hüft-TEP Klammer auf links Klammer zu Punkt"],
      "Zustand nach Hüft-TEP (links).", label: "B3 'Klammer zu Punkt'")
  }

  @Test func bracketWithCommas() {
    Self.check(
      ["Medikation Klammer auf Ramipril Komma Metformin Klammer zu Komma weiterhin unverändert"],
      "Medikation (Ramipril, Metformin), weiterhin unverändert", label: "B4 Klammer + Komma")
  }

  @Test func bracketAcrossPieces() {
    Self.check(
      ["Medikation Klammer auf", "Ramipril Klammer zu", "Punkt"],
      "Medikation (Ramipril).", label: "B5 Klammer über Stückgrenzen")
  }

  @Test func bracketModelPunctuation() {
    Self.check(
      ["Medikation, Klammer auf. Ramipril, Klammer zu."],
      "Medikation (Ramipril).", label: "B6 Klammer mit Modell-Satzzeichen")
  }

  // MARK: "Punkt" after particles

  @Test func periodAfterSeparablePrefixEin() {
    Self.check(
      ["Bitte nehmen Sie die Tablette morgens ein Punkt"],
      "Bitte nehmen Sie die Tablette morgens ein.", label: "C1 '… ein Punkt'")
  }

  @Test func periodAfterSeparablePrefixZu() {
    Self.check(
      ["Bitte senden Sie uns den Befund zu Punkt"],
      "Bitte senden Sie uns den Befund zu.", label: "C2 '… zu Punkt'")
  }

  @Test func periodAfterIn() {
    Self.check(
      ["Die Patientin stellt sich in drei Monaten wieder vor Punkt Die Werte sind in Punkt"],
      "Die Patientin stellt sich in drei Monaten wieder vor. Die Werte sind in.",
      label: "C3 'in Punkt' (Kontrollfall)")
  }

  @Test func periodAfterParticleAcrossPieces() {
    Self.check(
      ["Bitte nehmen Sie die Tablette morgens ein", "Punkt"],
      "Bitte nehmen Sie die Tablette morgens ein.", label: "C4 'ein' | 'Punkt'")
  }

  // MARK: Two commands, capitals

  @Test func periodNewParagraph() {
    Self.check(
      ["Die Patientin kam heute Punkt neuer Absatz die Beschwerden bestehen seit Wochen Punkt"],
      "Die Patientin kam heute.\n\nDie Beschwerden bestehen seit Wochen.", label: "D1 'Punkt neuer Absatz'")
  }

  @Test func periodThenNewLineAcrossPieces() {
    Self.check(
      ["Die Patientin kam heute Punkt", "Neue Zeile die Beschwerden"],
      "Die Patientin kam heute.\nDie Beschwerden", label: "D2 'Punkt' | 'neue Zeile die'")
  }

  @Test func capitalAfterQuestionAndExclamation() {
    Self.check(
      ["Haben Sie Schmerzen Fragezeichen wie lange schon Fragezeichen bitte kommen Sie nüchtern Ausrufezeichen danke"],
      "Haben Sie Schmerzen? Wie lange schon? Bitte kommen Sie nüchtern! Danke", label: "D3 ? und !")
  }

  @Test func capitalAfterQuestionAcrossPieces() {
    Self.check(
      ["Haben Sie Schmerzen Fragezeichen", "Und wie lange schon"],
      "Haben Sie Schmerzen? Und wie lange schon", label: "D4 '?' | 'Und'")
  }

  @Test func functionWordMidSentenceAcrossPieces() {
    Self.check(
      ["Die Patientin klagt", "Über Schmerzen", "Diese Woche schlimmer"],
      "Die Patientin klagt über Schmerzen diese Woche schlimmer", label: "D5 Funktionswort nach Pause")
  }

  @Test func colonThenWord() {
    Self.check(
      ["Diagnose Doppelpunkt Polyneuropathie Punkt"], "Diagnose: Polyneuropathie.", label: "D7 Doppelpunkt")
  }

  @Test func colonAtPieceEnd() {
    Self.check(
      ["Diagnose Doppelpunkt", "Polyneuropathie Punkt"], "Diagnose: Polyneuropathie.", label: "D8 Doppelpunkt | Wort")
  }

  // MARK: Words that contain commands

  @Test func wordsContainingCommands() {
    let text = "Die Punktion ergab eine Kommazahl, Klammern und Zeilenabstand sowie Absatzmarke und Punkte"
    Self.check([text], text, label: "E1 Wörter mit Befehl im Wort")
  }

  @Test func newLineVariants() {
    Self.check(["Befund Neuzeile Inspektion"], "Befund\nInspektion", label: "E2a 'Neuzeile'")
  }

  @Test func commandsWithModelCaseAndMarks() {
    Self.check(["Befund, Komma, unauffällig. Punkt."], "Befund, unauffällig.", label: "E3a Komma/Punkt mit Modellzeichen")
    Self.check(["Befund KOMMA unauffällig PUNKT"], "Befund, unauffällig.", label: "E3b Großbuchstaben")
    Self.check(["Befund? Fragezeichen"], "Befund?", label: "E3c '? Fragezeichen'")
  }

  // MARK: Spaces at boundaries

  @Test func boundarySpacing() {
    Self.check(["Befund", ", unauffällig"], "Befund, unauffällig", label: "F1 führendes Komma")
    Self.check(["Befund.", ". Weiter"], "Befund. Weiter", label: "F2 doppelter Punkt")
    Self.check(["Befund Komma", "Komma unauffällig"], "Befund, unauffällig", label: "F3 Komma doppelt über Grenze")
    Self.check(["  Befund  ", "  unauffällig  "], "Befund unauffällig", label: "F4 Leerzeichen")
    Self.check(["A neuer Absatz", "neue Zeile B"], "A\n\nB", label: "F5 Absatz | Zeile")
    Self.check(["Befund", "Fragezeichen"], "Befund?", label: "F6 '?' allein")
    Self.check(["Befund Punkt", "Komma"], "Befund.,", label: "F7 Punkt | Komma (nur Beobachtung)")
  }

  // MARK: Umlauts, fillers, empty, long

  @Test func umlauts() {
    Self.check(
      ["Überweisung an Dr. Müller Komma Ärztin für Innere Medizin Punkt übrigens gut Punkt"],
      "Überweisung an Dr. Müller, Ärztin für Innere Medizin. Übrigens gut.", label: "G1 Umlaute")
  }

  @Test func fillersAndEmpty() {
    Self.check(["", "äh", "Ähm, hm."], "", label: "H1 nur Füllwörter")
    Self.check(["Befund", "äh", "unauffällig"], "Befund unauffällig", label: "H2 Füllwort-Stück")
    Self.check(["Befund unauffällig", "Ähm Punkt"], "Befund unauffällig.", label: "H3 'Ähm Punkt'")
  }

  @Test func longPiece() {
    let words = (0..<300).map { "Wort\($0 % 10 == 0 ? "" : "x") Komma" }.joined(separator: " ") + " Ende Punkt"
    let out = Self.pipeline([words])
    let commas = out.filter { $0 == "," }.count
    #expect(commas == 300)
    #expect(!out.lowercased().contains("komma"))
  }

  // MARK: Vocabulary guard

  @Test func vocabularyGuardShortTerms() {
    let glossary = ["PNP", "TEP", "Polyneuropathie", "Hüft-TEP", "Ramipril"]
    let cases: [(String, String, Bool)] = [
      ("weiter", "TEP", false), ("im Prinzip", "PNP", false), ("Typ", "TEP", false),
      ("Tee", "TEP", false), ("Top", "TEP", false), ("Tipp", "TEP", false), ("Team", "TEP", false),
      ("Pep", "PNP", false), ("PMP", "PNP", true), ("Tep", "TEP", true),
      ("Step", "TEP", false), ("Depp", "TEP", false), ("Tempo", "TEP", false),
      // An everyday word, or the first part of a compound, is not the glossary term.
      ("Hüfte", "Hüft-TEP", false), ("Hüfte", "TEP", false), ("Knie", "Knie-TEP", false),
      ("Schulter", "Schulter-TEP", false), ("Rücken", "PNP", false),
      // Real corrections still work.
      ("Ipril", "Ramipril", true), 
    ]
    for (span, term, expected) in cases {
      let accepted = ParakeetVocabularyGuard.accepts(
        .init(originalSpan: span, term: term), glossaryTerms: glossary)
      #expect(accepted == expected, "\(span) → \(term)")
    }
  }

  @Test func vocabularyApplyKeepsMarkAfterReplacedSpan() {
    // The span FluidAudio reports can carry the comma behind the word; the term replaces the word
    // only, so the mark count still matches the token timings.
    let glossary = ["PNP", "TEP"]
    let applied = ParakeetVocabularyGuard.apply(
      to: "auf PMP, Zustand", replacements: [.init(originalSpan: "PMP,", term: "PNP")],
      glossaryTerms: glossary)
    #expect(applied.text == "auf PNP, Zustand")
    #expect(applied.accepted == 1)
    let question = ParakeetVocabularyGuard.apply(
      to: "ist das PMP? Ja", replacements: [.init(originalSpan: "PMP?", term: "PNP")],
      glossaryTerms: glossary)
    #expect(question.text == "ist das PNP? Ja")
    // No mark in the span, none added.
    let plain = ParakeetVocabularyGuard.apply(
      to: "auf PMP Zustand", replacements: [.init(originalSpan: "PMP", term: "PNP")],
      glossaryTerms: glossary)
    #expect(plain.text == "auf PNP Zustand")
  }

  @Test func replacedSpanKeepsTimingMarkCount() {
    // "auf PMP, Zustand": the comma was spoken (80 ms gap kept = 0.12 s needed; here 0.3 s).
    let tokens: [ParakeetPunctuationTiming.Token] = [
      .init(text: "▁auf", start: 0.1, end: 0.3), .init(text: "▁TMP", start: 0.35, end: 0.8),
      .init(text: ",", start: 0.8, end: 0.9), .init(text: "▁Zustand", start: 1.3, end: 1.8),
    ]
    let text = ParakeetVocabularyGuard.apply(
      to: "auf PMP, Zustand", replacements: [.init(originalSpan: "PMP,", term: "PNP")],
      glossaryTerms: ["PNP"]).text
    let filtered = ParakeetPunctuationTiming.filter(text: text, tokens: tokens, audioDuration: 2.5)
    #expect(filtered?.text == "auf PNP, Zustand")
  }

  // MARK: Spoken comma before a break, brackets with articles, "Punkt" after particles

  @Test func commaStaysBeforeBreakWithTiming() {
    #expect(
      LiveDictation.finishPiece(
        "Sehr geehrte Damen und Herren, neuer Absatz.", mode: .spokenOnly, timedMarks: true)
        == "Sehr geehrte Damen und Herren,\n\n")
    #expect(
      LiveDictation.finishPiece(
        "Müller, neue Zeile vielen Dank", mode: .spokenOnly, timedMarks: true)
        == "Müller,\nvielen Dank")
  }

  @Test func commaBeforeBreakWithoutTimingKeepsOldBehaviour() {
    // No timings, or another mode: the comma is the model's pause guess and goes.
    #expect(
      LiveDictation.finishPiece("Müller, neue Zeile vielen Dank", mode: .spokenOnly)
        == "Müller\nVielen Dank")
    #expect(
      LiveDictation.finishPiece("Herren, neuer Absatz wir", mode: .spokenOnly) == "Herren\n\nWir")
    #expect(
      LiveDictation.finishPiece("Herren, neuer Absatz wir", mode: .automatic, timedMarks: true)
        == "Herren.\n\nwir")
  }

  @Test func bracketWithArticleNeedsClosingBracket() {
    Self.check(
      ["Der Befund Klammer auf die Laborwerte liegen bei Klammer zu ist unauffällig Punkt"],
      "Der Befund (die Laborwerte liegen bei) ist unauffällig.", label: "article + closing")
    // No "Klammer zu" in the text: the noun.
    #expect(
      SpokenPunctuation.apply(to: "Eine Klammer auf die Wunde gesetzt.", mode: .spokenOnly)
        == "Eine Klammer auf die Wunde gesetzt.")
    // Piece-local: an article-led opening in one piece without its closing stays a noun.
    Self.check(["Klammer auf die Wunde"], "Klammer auf die Wunde", label: "noun, no closing")
  }

  @Test func punktAfterParticleIsMarkUnlessNumberOrNounFollows() {
    for (text, expected) in [
      ("morgens ein Punkt", "morgens ein."),
      ("den Befund zu Punkt", "den Befund zu."),
      ("wieder in Punkt Die Werte", "wieder in. Die Werte"),
      // Number or noun after "Punkt": the noun.
      ("das ist ein Punkt mehr", "das ist ein Punkt mehr"),
      ("siehe in Punkt 3", "siehe in Punkt 3"),
      ("wir kommen zu Punkt drei", "wir kommen zu Punkt drei"),
      ("das ist ein Punkt Frage", "das ist ein Punkt Frage"),
    ] {
      #expect(SpokenPunctuation.apply(to: text, mode: .spokenOnly) == expected, "\(text)")
    }
  }

  // MARK: Case after a salutation break, break limit across pieces

  @Test func salutationFollowersAfterBreakAreLowercase() {
    Self.check(
      ["Sehr geehrte Frau Müller,", "neue Zeile vielen Dank"],
      "Sehr geehrte Frau Müller,\nvielen Dank", label: "5a break in piece 2")
    Self.check(
      ["Sehr geehrte Frau Müller, neue Zeile", "Vielen Dank"],
      "Sehr geehrte Frau Müller,\nvielen Dank", label: "5b pause after break")
    for word in ["Wir", "Ich", "Mit", "Anbei", "Bitte", "Danke"] {
      Self.check(
        ["Guten Tag Herr Schmidt,", "neue Zeile \(word) melden uns"],
        "Guten Tag Herr Schmidt,\n\(word.lowercased()) melden uns", label: "5c \(word)")
    }
  }

  @Test func capitalStaysAfterBreakWithoutComma() {
    Self.check(
      ["Die Patientin kam heute.", "neue Zeile vielen Dank"],
      "Die Patientin kam heute.\nVielen Dank", label: "5d after period")
    Self.check(
      ["Haben Sie Schmerzen?", "neue Zeile wir sehen uns"],
      "Haben Sie Schmerzen?\nWir sehen uns", label: "5e after question mark")
    Self.check(["Befund", "neue Zeile vielen Dank"], "Befund\nVielen Dank", label: "5f no mark")
  }

  @Test func nounAfterSalutationBreakKeepsCapital() {
    Self.check(
      ["Guten Tag,", "neue Zeile Herr Schmidt kommt"], "Guten Tag,\nHerr Schmidt kommt",
      label: "5h noun")
  }

  @Test func breaksAcrossPiecesCapAtTwo() {
    Self.check(["A neuer Absatz", "neue Zeile B"], "A\n\nB", label: "10a")
    Self.check(["A neuer Absatz", "neuer Absatz B"], "A\n\nB", label: "10b")
    Self.check(["A neue Zeile", "neue Zeile B"], "A\n\nB", label: "10c: two lines stay two")
    Self.check(["A neue Zeile", "neuer Absatz B"], "A\n\nB", label: "10d")
    Self.check(["A neue Zeile", "B"], "A\nB", label: "10e one break stays")
  }
}

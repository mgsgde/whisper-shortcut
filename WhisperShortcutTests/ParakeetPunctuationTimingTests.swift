import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// The spoken-vs-guessed rule for Parakeet's commas and periods, on hand-built token arrays.
/// Measurement behind the thresholds: `LiveDictationPilotTests.punctuationTiming`.
@Suite("Parakeet punctuation timing")
struct ParakeetPunctuationTimingTests {
  private typealias Token = ParakeetPunctuationTiming.Token

  private func word(_ text: String, _ start: Double, _ end: Double) -> Token {
    Token(text: "\u{2581}" + text, start: start, end: end)
  }

  private func mark(_ text: String, _ start: Double, _ end: Double) -> Token {
    Token(text: text, start: start, end: end)
  }

  // "Gangbild , geht weiter" with a configurable pause after the comma.
  private func commaTokens(gap: Double) -> [Token] {
    [
      word("Gangbild", 0.0, 0.6), mark(",", 0.6, 0.64),
      word("geht", 0.64 + gap, 0.9 + gap), word("weiter", 0.9 + gap, 1.3 + gap),
    ]
  }

  @Test("comma without a pause is guessed, with 200 ms is spoken")
  func commaGap() {
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: commaTokens(gap: 0), audioDuration: 2) == [false])
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: commaTokens(gap: 0.2), audioDuration: 2) == [true])
  }

  private func periodTokens() -> [Token] {
    [word("Gangbild", 0.0, 0.6), word("unauffällig", 0.6, 1.2), mark(".", 1.2, 1.24)]
  }

  @Test("final period needs 240 ms of audio behind it")
  func finalPeriodTail() {
    let tokens = periodTokens()
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: tokens, audioDuration: 1.24 + 0.1) == [false])
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: tokens, audioDuration: 1.24 + 0.5) == [true])
  }

  @Test("question and exclamation marks are always guessed")
  func questionAndExclamation() {
    let tokens = [word("Stimmt", 0, 0.5), mark("?", 0.5, 0.54), word("Ja", 1.5, 1.8), mark("!", 1.8, 1.84)]
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: tokens, audioDuration: 5) == [false, false])
  }

  @Test("a decimal point inside a number is not a mark")
  func decimalPoint() {
    let tokens = [word("Wert", 0, 0.4), word("3", 0.4, 0.6), mark(".", 0.6, 0.62), Token(text: "5", start: 0.62, end: 0.8)]
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: tokens, audioDuration: 1).isEmpty)
  }

  @Test("filter drops the guessed comma and keeps the spoken one")
  func filterComma() {
    let guessed = ParakeetPunctuationTiming.filter(
      text: "Gangbild, geht weiter", tokens: commaTokens(gap: 0), audioDuration: 2)
    #expect(guessed == .init(text: "Gangbild geht weiter", kept: 0, dropped: 1))
    let spoken = ParakeetPunctuationTiming.filter(
      text: "Gangbild, geht weiter", tokens: commaTokens(gap: 0.2), audioDuration: 2)
    #expect(spoken == .init(text: "Gangbild, geht weiter", kept: 1, dropped: 0))
  }

  @Test("filter handles a final period by audio tail")
  func filterFinalPeriod() {
    let tokens = periodTokens()
    #expect(
      ParakeetPunctuationTiming.filter(text: "Gangbild unauffällig.", tokens: tokens, audioDuration: 1.34)?.text
        == "Gangbild unauffällig")
    #expect(
      ParakeetPunctuationTiming.filter(text: "Gangbild unauffällig.", tokens: tokens, audioDuration: 1.8)?.text
        == "Gangbild unauffällig.")
  }

  @Test("a dropped mid-text period lowers a following function word, not a noun")
  func lowersFunctionWord() {
    let tokens = [
      word("Wir", 0, 0.3), word("gehen", 0.3, 0.6), mark(".", 0.6, 0.62), word("Und", 0.62, 0.8),
      word("Befund", 0.8, 1.2), mark(".", 1.2, 1.22), word("Knie", 1.22, 1.5),
    ]
    let result = ParakeetPunctuationTiming.filter(
      text: "Wir gehen. Und Befund. Knie", tokens: tokens, audioDuration: 3)
    #expect(result?.text == "Wir gehen und Befund Knie")
    #expect(result?.dropped == 2)
  }

  @Test("a dropped period lowers a following adverb, a noun keeps its capital")
  func lowersAdverb() {
    let tokens = [
      word("Ich", 0, 0.2), word("arbeite", 0.2, 0.5), word("mal", 0.5, 0.7), mark(".", 0.7, 0.72),
      word("Weiter", 0.72, 1.0), word("damit", 1.0, 1.3),
    ]
    let result = ParakeetPunctuationTiming.filter(
      text: "Ich arbeite mal. Weiter damit", tokens: tokens, audioDuration: 3)
    #expect(result?.text == "Ich arbeite mal weiter damit")
    let noun = [
      word("Befund", 0, 0.4), mark(".", 0.4, 0.42), word("Patientin", 0.42, 0.9),
      word("kam", 0.9, 1.1),
    ]
    let nounResult = ParakeetPunctuationTiming.filter(
      text: "Befund. Patientin kam", tokens: noun, audioDuration: 3)
    #expect(nounResult?.text == "Befund Patientin kam")
  }

  @Test("an ordinal or abbreviation period mid-text stays")
  func keepsOrdinal() {
    let tokens = [word("5", 0, 0.3), mark(".", 0.3, 0.32), word("Lendenwirbel", 0.32, 1.0)]
    #expect(
      ParakeetPunctuationTiming.filter(text: "5. Lendenwirbel", tokens: tokens, audioDuration: 2)?.text
        == "5. Lendenwirbel")
  }

  @Test("a count mismatch returns nil so the caller falls back")
  func mismatch() {
    #expect(
      ParakeetPunctuationTiming.filter(
        text: "Gangbild, geht, weiter", tokens: commaTokens(gap: 0), audioDuration: 2) == nil)
  }

  @Test("question marks are removed by the filter too")
  func removesQuestionMark() {
    let tokens = [word("Stimmt", 0, 0.5), mark("?", 0.5, 0.54)]
    #expect(
      ParakeetPunctuationTiming.filter(text: "Stimmt?", tokens: tokens, audioDuration: 3)?.text == "Stimmt")
  }

  @Test("timed marks: strip leaves commas and periods, removes semicolons and ?/!")
  func stripTimedMarks() {
    #expect(
      SpokenPunctuation.stripModelPunctuation(from: "Hallo, Welt; ok? Gut.", timedMarks: true)
        == "Hallo, Welt ok Gut.")
  }

  @Test("a live piece with timed marks keeps its spoken comma; without, the old rule strips it")
  func finishPieceTimedMarks() {
    #expect(
      LiveDictation.finishPiece("Gangbild, geht weiter.", mode: .spokenOnly, timedMarks: true)
        == "Gangbild, geht weiter.")
    #expect(
      LiveDictation.finishPiece("Gangbild, geht weiter.", mode: .spokenOnly) == "Gangbild geht weiter.")
  }

  // "Gesamt GdB 50,Merkzeichen G." with Parakeet's comma glued to the next word.
  private func gluedTokens(gap: Double) -> [Token] {
    [
      word("Gesamt", 0, 0.4), word("GdB", 0.4, 0.8), word("50", 0.8, 1.2), mark(",", 1.2, 1.24),
      mark("Merk", 1.24 + gap, 1.5 + gap), mark("zeichen", 1.5 + gap, 1.8 + gap),
      word("G", 1.8 + gap, 2.0 + gap), mark(".", 2.0 + gap, 2.04 + gap),
    ]
  }

  @Test("a spoken comma glued to the next word is kept and gets its space")
  func gluedCommaKept() {
    let tokens = gluedTokens(gap: 0.2)
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: tokens, audioDuration: 4) == [true, true])
    let result = ParakeetPunctuationTiming.filter(
      text: "Gesamt GdB 50,Merkzeichen G.", tokens: tokens, audioDuration: 4)
    #expect(result == .init(text: "Gesamt GdB 50, Merkzeichen G.", kept: 2, dropped: 0))
  }

  @Test("a guessed glued comma is replaced by a space, never gluing the words")
  func gluedCommaDropped() {
    let result = ParakeetPunctuationTiming.filter(
      text: "Gesamt GdB 50,Merkzeichen G.", tokens: gluedTokens(gap: 0), audioDuration: 4)
    #expect(result?.text == "Gesamt GdB 50 Merkzeichen G.")
    #expect(result?.dropped == 1)
  }

  @Test("a decimal comma stays untouched")
  func decimalComma() {
    let tokens = [word("Wert", 0, 0.4), word("3", 0.4, 0.6), mark(",", 0.6, 0.62),
      Token(text: "5", start: 0.62, end: 0.8), word("mg", 0.8, 1.0), mark(".", 1.0, 1.04)]
    let result = ParakeetPunctuationTiming.filter(text: "Wert 3,5 mg.", tokens: tokens, audioDuration: 3)
    #expect(result?.text == "Wert 3,5 mg.")
  }

  @Test("spacingGluedCommas adds the space before a letter only")
  func spacingGluedCommas() {
    #expect(ParakeetPunctuationTiming.spacingGluedCommas("50,Merkzeichen und 3,5") == "50, Merkzeichen und 3,5")
  }
}

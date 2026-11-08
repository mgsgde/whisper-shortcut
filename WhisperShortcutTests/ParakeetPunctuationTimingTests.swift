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

  @Test("final period needs 400 ms of audio behind it")
  func finalPeriodTail() {
    let tokens = periodTokens()
    // 100 ms is under both the old 240 ms line and the current 400 ms line.
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: tokens, audioDuration: 1.24 + 0.1) == [false])
    // 500 ms clears 400 ms. A tail of 300 ms, which the old 240 ms line kept, is now dropped.
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: tokens, audioDuration: 1.24 + 0.30) == [false])
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: tokens, audioDuration: 1.24 + 0.5) == [true])
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: tokens, audioDuration: 1.24 + 0.70) == [true])
  }

  @Test("question and exclamation marks follow the same gap and tail rule")
  func questionAndExclamation() {
    // Gap after "?" is 0.96 s, tail after "!" is 3.16 s: both spoken.
    let tokens = [word("Stimmt", 0, 0.5), mark("?", 0.5, 0.54), word("Ja", 1.5, 1.8), mark("!", 1.8, 1.84)]
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: tokens, audioDuration: 5) == [true, true])
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

  @Test("a final question mark with a short tail is dropped, a long tail is kept")
  func questionMarkTail() {
    let tokens = [word("Stimmt", 0, 0.5), mark("?", 0.5, 0.54)]
    #expect(
      ParakeetPunctuationTiming.filter(text: "Stimmt?", tokens: tokens, audioDuration: 0.54 + 0.10)?.text
        == "Stimmt")
    #expect(
      ParakeetPunctuationTiming.filter(text: "Stimmt?", tokens: tokens, audioDuration: 0.54 + 0.70)?.text
        == "Stimmt?")
  }

  @Test("timed marks: strip leaves commas, periods and ?/!, removes semicolons")
  func stripTimedMarks() {
    #expect(
      SpokenPunctuation.stripModelPunctuation(from: "Hallo, Welt; ok? Gut.", timedMarks: true)
        == "Hallo, Welt ok? Gut.")
    // No timings: the model's "!" is still dropped, so a period written beside it is what remains.
    // With timings the "!" the filter kept is left alone.
    #expect(SpokenPunctuation.stripModelPunctuation(from: "Wirklich.!") == "Wirklich.")
    #expect(
      SpokenPunctuation.stripModelPunctuation(from: "Wirklich.!", timedMarks: true) == "Wirklich.!")
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

  // "Stimmt ? Ja" with a configurable pause after the question mark.
  private func questionTokens(gap: Double) -> [Token] {
    [
      word("Stimmt", 0.0, 0.5), mark("?", 0.5, 0.54),
      word("Ja", 0.54 + gap, 0.8 + gap),
    ]
  }

  @Test("a mid-text question mark needs the same gap as a comma")
  func questionGap() {
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: questionTokens(gap: 0), audioDuration: 2) == [false])
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: questionTokens(gap: 0.20), audioDuration: 2) == [true])
    #expect(
      ParakeetPunctuationTiming.filter(
        text: "Stimmt? Ja", tokens: questionTokens(gap: 0), audioDuration: 2)?.text == "Stimmt Ja")
    #expect(
      ParakeetPunctuationTiming.filter(
        text: "Stimmt? Ja", tokens: questionTokens(gap: 0.20), audioDuration: 2)?.text == "Stimmt? Ja")
  }

  @Test("a final exclamation mark is kept at 700 ms of tail and dropped at 100 ms")
  func exclamationTail() {
    let tokens = [word("Wirklich", 0.0, 0.6), mark("!", 0.6, 0.64)]
    #expect(
      ParakeetPunctuationTiming.spokenMarks(tokens: tokens, audioDuration: 0.64 + 0.10) == [false])
    #expect(
      ParakeetPunctuationTiming.spokenMarks(tokens: tokens, audioDuration: 0.64 + 0.70) == [true])
    #expect(
      ParakeetPunctuationTiming.filter(text: "Wirklich!", tokens: tokens, audioDuration: 0.64 + 0.10)?.text
        == "Wirklich")
    #expect(
      ParakeetPunctuationTiming.filter(text: "Wirklich!", tokens: tokens, audioDuration: 0.64 + 0.70)?.text
        == "Wirklich!")
  }

  @Test("a spoken exclamation mark stays an exclamation mark through filter and finishPiece")
  func spokenExclamationSurvives() {
    let tokens = [word("Wirklich", 0.0, 0.6), mark("!", 0.6, 0.64)]
    let filtered = ParakeetPunctuationTiming.filter(
      text: "Wirklich!", tokens: tokens, audioDuration: 0.64 + 0.70)
    #expect(filtered?.text == "Wirklich!")
    #expect(
      LiveDictation.finishPiece(filtered?.text ?? "", mode: .spokenOnly, timedMarks: true) == "Wirklich!")
    // A period glued in front of the spoken "!". Timing keeps the "!" (it is the final mark, with
    // a tail); finishPiece must not strip it back off. Without timings the old rule still drops
    // the "!" and the "." is what remains — that is the "!" → "." bug.
    let both = [word("Wirklich", 0.0, 0.6), mark(".", 0.6, 0.64), mark("!", 0.64, 0.68)]
    let kept = ParakeetPunctuationTiming.filter(
      text: "Wirklich.!", tokens: both, audioDuration: 0.68 + 0.70)
    #expect(kept?.text == "Wirklich.!")
    #expect(
      LiveDictation.finishPiece(kept?.text ?? "", mode: .spokenOnly, timedMarks: true) == "Wirklich.!")
    #expect(LiveDictation.finishPiece("Wirklich.!", mode: .spokenOnly) == "Wirklich.")
    // The word itself, with the periods Parakeet put around it, becomes "!" and not ".".
    #expect(
      LiveDictation.finishPiece("Bitte Befund nachreichen. Ausrufezeichen.", mode: .spokenOnly)
        == "Bitte Befund nachreichen!")
    #expect(
      LiveDictation.finishPiece(
        "Bitte Befund nachreichen. Ausrufezeichen.", mode: .spokenOnly, timedMarks: true)
        == "Bitte Befund nachreichen!")
  }

  @Test("spoken Semikolon and Strichpunkt become a semicolon, with and without timings")
  func spokenSemicolon() {
    let sentence = "Hüfte frei beweglich Semikolon Knie mit Erguss"
    #expect(LiveDictation.finishPiece(sentence, mode: .spokenOnly) == "Hüfte frei beweglich; Knie mit Erguss")
    #expect(
      LiveDictation.finishPiece(sentence, mode: .spokenOnly, timedMarks: true)
        == "Hüfte frei beweglich; Knie mit Erguss")
    let strichpunkt = "Hüfte frei beweglich Strichpunkt Knie mit Erguss"
    #expect(
      LiveDictation.finishPiece(strichpunkt, mode: .spokenOnly) == "Hüfte frei beweglich; Knie mit Erguss")
    #expect(
      LiveDictation.finishPiece(strichpunkt, mode: .spokenOnly, timedMarks: true)
        == "Hüfte frei beweglich; Knie mit Erguss")
  }

  // "Leukozyten 11,8 , Natrium": the comma token is glued to the digit token.
  private func commaAfterDigitTokens(gap: Double) -> [Token] {
    [
      word("11,8", 0.0, 0.6), mark(",", 0.6, 0.62),
      word("Natrium", 0.62 + gap, 1.1 + gap),
    ]
  }

  @Test("a spoken comma right after a number survives a short gap, a comma after a word does not")
  func commaAfterDigit() {
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: commaAfterDigitTokens(gap: 0.07), audioDuration: 3) == [true])
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: commaAfterDigitTokens(gap: 0.02), audioDuration: 3) == [false])
    #expect(ParakeetPunctuationTiming.spokenMarks(tokens: commaTokens(gap: 0.07), audioDuration: 2) == [false])
  }
}

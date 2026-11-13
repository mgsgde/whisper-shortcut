import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("German number words")
struct GermanNumberWordsTests {

  private func digits(_ text: String) -> String {
    GermanNumberWords.digitizingQuantities(in: text)
  }

  @Test("Cardinal words 0–999 parse, other words do not")
  func values() {
    let cases: [(String, Int?)] = [
      ("null", 0), ("eins", 1), ("zwei", 2), ("Zehn", 10), ("elf", 11), ("zwölf", 12),
      ("sechzehn", 16), ("siebzehn", 17), ("zwanzig", 20), ("dreißig", 30), ("dreissig", 30),
      ("fünfzig", 50), ("fuenfzig", 50), ("neunzig", 90), ("einundzwanzig", 21),
      ("neunundneunzig", 99), ("hundert", 100), ("einhundert", 100), ("hundertvierzig", 140),
      ("fünfhundert", 500), ("hundertundzehn", 110), ("hunderteins", 101),
      ("zweihundertdreiundvierzig", 243),
      ("ein", nil), ("eine", nil), ("einer", nil), ("dreiß", nil), ("Hunderte", nil),
      ("hundertund", nil), ("Dreier", nil), ("Punkte", nil), ("undzwanzig", nil),
    ]
    for (word, expected) in cases {
      #expect(GermanNumberWords.value(of: word) == expected, "\(word)")
    }
  }

  @Test("A unit of measure after the word makes it digits")
  func measureUnits() {
    #expect(digits("Gehstrecke unter fünfhundert Meter.") == "Gehstrecke unter 500 Meter.")
    #expect(digits("Ramipril fünf mg") == "Ramipril 5 mg")
    #expect(digits("Rotation sechzig Grad") == "Rotation 60 Grad")
    #expect(digits("zu neunzig Prozent") == "zu 90 Prozent")
    #expect(digits("zwanzig % weniger") == "20 % weniger")
    #expect(digits("vierzig° Beugung") == "40° Beugung")
  }

  @Test("Time units: digits above twelve only, so prose numbers stay words")
  func timeUnits() {
    #expect(digits("Um zehn Uhr kam die Patientin") == "Um zehn Uhr kam die Patientin")
    #expect(digits("seit drei Tagen") == "seit drei Tagen")
    #expect(digits("in drei Monaten") == "in drei Monaten")
    #expect(digits("um dreizehn Uhr") == "um 13 Uhr")
    #expect(digits("seit zwanzig Jahren") == "seit 20 Jahren")
  }

  @Test("GdB values are digits: after GdB, GdB von, GdB and one capitalised word")
  func gdbValues() {
    #expect(digits("Gesamt GdB fünfzig, Merkzeichen G") == "Gesamt GdB 50, Merkzeichen G")
    #expect(digits("ist ein GdB von dreißig angemessen.") == "ist ein GdB von 30 angemessen.")
    #expect(digits("Einzel GdB Psyche zwanzig.") == "Einzel GdB Psyche 20.")
    #expect(digits("Einzel-GdB zehn") == "Einzel-GdB 10")
    #expect(digits("GDB vierzig") == "GDB 40")
    // Not a value: a lower-case word between, or no GdB.
    #expect(digits("GdB für drei Funktionssysteme") == "GdB für drei Funktionssysteme")
    #expect(digits("Psyche zwanzig") == "Psyche zwanzig")
  }

  @Test("Either side of zu: digits on the other side, or both words with one above nine")
  func ratio() {
    #expect(digits("Blutdruck 140 zu neunzig") == "Blutdruck 140 zu 90")
    #expect(digits("Blutdruck hundertvierzig zu 90") == "Blutdruck 140 zu 90")
    #expect(digits("Blutdruck hundertvierzig zu neunzig") == "Blutdruck 140 zu 90")
    #expect(digits("eins zu eins umsetzen") == "eins zu eins umsetzen")
    #expect(digits("zehn zu spät") == "zehn zu spät")
  }

  @Test("Digits right next to it, by space or slash")
  func nextToDigits() {
    #expect(digits("Lendenwirbel 4/fünf") == "Lendenwirbel 4/5")
    #expect(digits("Werte 140 neunzig") == "Werte 140 90")
    #expect(digits("Lendenwirbel vier/fünf") == "Lendenwirbel vier/fünf")
    // A mark in between ends the context.
    #expect(digits("Punkte: 3. Drei weitere folgen") == "Punkte: 3. Drei weitere folgen")
  }

  @Test("Prose stays: articles, scores, ellipsis, plain numbers")
  func proseStays() {
    for text in [
      "Sie hat drei Punkte erreicht.",
      "ein Meter Abstand",
      "Eine Woche später",
      "eins nach dem anderen",
      "Gesamt GdB drei Pünktchen und dann weiter",
      "Die zwei Kinder kommen",
      "Ich arbeite mal weiter damit.",
      "",
    ] {
      #expect(digits(text) == text, "\(text)")
    }
  }
}

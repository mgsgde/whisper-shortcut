import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Dictate field hint")
struct DictationFieldHintTests {

  private static let examples: [(String, [String])] = [
    ("Hi Thomas, kurze Frage zum Wibutler-Gateway: läuft das bei euch schon stabil?",
     ["Thomas", "Wibutler-Gateway", "Wibutler"]),
    ("Maik: Kommst du heute Abend mit zum Training?", ["Maik", "Abend", "Training"]),
    ("Moin Jörn, Frau Szczepanski aus der Buchhaltung hat sich gemeldet.",
     ["Jörn", "Szczepanski", "Buchhaltung"]),
    ("Diagnose: Morbus Dupuytren rechte Hand, Stadium II.", ["Dupuytren", "Hand", "Stadium"]),
    ("Angebot der Kreuzberger Haustechnik GmbH vom 3. November",
     ["Kreuzberger", "Haustechnik", "GmbH"]),
    ("Wir haben das Angebot intern geprüft und", []),
    ("Hast du den Wibutler schon angeschlossen?", ["Wibutler"]),
  ]

  @Test("extract_terms port matches the benchmark's verified outputs",
        arguments: examples)
  func extractorMatchesBenchmark(text: String, expected: [String]) {
    #expect(DictationFieldHint.terms(fromTextBeforeCaret: text) == expected)
  }

  @Test("Only the last 1000 characters are considered")
  func clipping() {
    let filler = String(repeating: "x", count: 2990)
    #expect(DictationFieldHint.terms(fromTextBeforeCaret: "Wibutler " + filler + " ende") == [])
    let late = String(repeating: "x ", count: 1000) + "kurz Wibutler ist da"
    #expect(DictationFieldHint.terms(fromTextBeforeCaret: late) == ["Wibutler"])
  }

  @Test("More than 20 names: exactly 20, the last ones")
  func capKeepsLast() {
    let names = (0..<30).map { "Name" + String(UnicodeScalar(UInt8(97 + $0 % 26))) + "\($0)" }
    let text = "so " + names.joined(separator: " und ")
    let terms = DictationFieldHint.terms(fromTextBeforeCaret: text)
    #expect(terms.count == DictationFieldHint.maxTerms)
    #expect(terms == Array(names.suffix(20)))
  }

  @Test("Merged keywords: glossary first, fold dedupe, nil field terms unchanged")
  func merge() {
    #expect(SpeechService.mergedKeywords(glossary: ["Gödde", "Acme"], fieldTerms: ["Godde", "Wibutler"])
      == ["Gödde", "Acme", "Wibutler"])
    #expect(SpeechService.mergedKeywords(glossary: ["Gödde", "Acme"], fieldTerms: nil)
      == ["Gödde", "Acme"])
    #expect(SpeechService.mergedKeywords(glossary: [], fieldTerms: ["Maik"]) == ["Maik"])
  }

  @Test("Setting is off by default")
  func defaultOff() {
    #expect(SettingsDefaults.dictateFieldHintEnabled == false)
    #expect(SettingsData().dictateFieldHintEnabled == false)
  }
}

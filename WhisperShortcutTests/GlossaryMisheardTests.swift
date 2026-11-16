import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Glossary misheard form")
struct GlossaryMisheardTests {
  private let now = Date()

  /// "Lasse" is a first name the spell checker knows; "Lasègue" it does not.
  private let known: (String) -> Bool = { $0.lowercased() == "lasse" }

  @Test("Lasse is learned as the misheard form of Lasègue")
  func lasse() {
    let text = "On examination, the Lasse sign was positive on the right."
    #expect(GlossaryMisheard.misheardForm(correct: "Lasègue", dictation: text, dictationDate: now, now: now, isKnownWord: known) == "Lasse")
  }

  @Test("A multi-word selection is stored bare")
  func multiWord() {
    #expect(GlossaryMisheard.misheardForm(correct: "Vers Med V", dictation: "the vers med v rules", dictationDate: now, now: now, isKnownWord: { _ in false }) == nil)
  }

  @Test("No similar word, term already in text, stale dictation, two known words, other first letter give nil")
  func nilCases() {
    func m(_ c: String, _ d: String, date: Date? = nil, known: @escaping (String) -> Bool = { _ in false }) -> String? {
      GlossaryMisheard.misheardForm(correct: c, dictation: d, dictationDate: date ?? now, now: now, isKnownWord: known)
    }
    #expect(m("Supraspinatus", "hello world") == nil)
    #expect(m("lasègue", "the Lasègue sign") == nil)
    #expect(m("Lasègue", "the Lasse sign", date: now.addingTimeInterval(-11 * 60), known: known) == nil)
    #expect(m("Lasègue", "the Lasse sign", known: { _ in true }) == nil)
    #expect(m("Lasègue", "the Hasse sign") == nil)
  }

  @Test("A misheard form is added to an existing bare term, or into its annotation")
  func addToExisting() {
    #expect(GlossaryMisheard.addingMisheard("Lasse", for: "Lasègue", to: "HVLA\nLasègue")
      == "HVLA\nLasègue (not \"Lasse\")")
    let r = GlossaryMisheard.addingMisheard("Lasse", for: "Lasègue", to: "Lasègue (not \"Lasek\")")
    #expect(r == "Lasègue (not \"Lasek\", \"Lasse\")")
    #expect(GlossaryDocument.parse(r!).entries[0].rejectedSpellings == ["Lasek", "Lasse"])
    #expect(GlossaryMisheard.addingMisheard("Lasek", for: "Lasègue", to: "Lasègue (not \"Lasek\")") == nil)
    // A term inside a comma list has no line of its own.
    #expect(GlossaryMisheard.addingMisheard("Lasse", for: "Lasègue", to: "HVLA, Lasègue") == nil)
  }
}

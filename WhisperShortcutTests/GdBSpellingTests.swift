import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("GdB spelling")
struct GdBSpellingTests {

  @Test("Parakeet's five spellings become Einzel-GdB, Gesamt-GdB or GdB", arguments: [
    ("EinzelgdB30", "Einzel-GdB 30"),
    ("Einzel GDB 20", "Einzel-GdB 20"),
    ("GDB10", "GdB 10"),
    ("GesamtgdB", "Gesamt-GdB"),
    ("eine Einzelgdb", "eine Einzel-GdB"),
    ("Einzel-GdB30", "Einzel-GdB 30"),
    ("GdB10", "GdB 10"),
  ])
  func parakeetSpellings(input: String, expected: String) {
    #expect(GdBSpelling.normalize(input) == expected)
  }

  @Test("A finished piece digitizes the number after the normalised token")
  func finishPieceDigits() {
    for mode in [PunctuationMode.spokenOnly, .automatic] {
      #expect(LiveDictation.finishPiece("Einzel GdB zwanzig", mode: mode) == "Einzel-GdB 20")
    }
  }

  @Test("An already correct token, a bare GdB, and other words stay")
  func unchanged() {
    for text in ["ein GdB von 50", "GdB", "AbGdB", "Hausgdbau", "einzeln reicht"] {
      #expect(GdBSpelling.normalize(text) == text, "\(text)")
      #expect(LiveDictation.finishPiece(text, mode: .spokenOnly) == text, "\(text)")
    }
  }
}

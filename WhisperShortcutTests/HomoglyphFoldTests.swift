import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Cyrillic look-alikes inside a Latin word are folded. A word with no ASCII letter is not.
@Suite("Cyrillic homoglyph fold")
struct HomoglyphFoldTests {

  @Test("Cyrillic е inside a German word becomes e")
  func foldsLookAlikeInsideLatinWord() {
    // "lege" with the last letter U+0435 CYRILLIC SMALL LETTER IE.
    let input = "Ich leg\u{0435} die Briefe"
    let result = TextProcessingUtility.foldingCyrillicHomoglyphs(input)
    #expect(result.text == "Ich lege die Briefe")
    #expect(result.folded == 1)
  }

  @Test("A sentence written only in Cyrillic is unchanged")
  func leavesPureCyrillicUntouched() {
    // "Привет мир", including look-alikes р and е. No ASCII letter, so nothing folds.
    let input = "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}"
    let result = TextProcessingUtility.foldingCyrillicHomoglyphs(input)
    #expect(result.text == input)
    #expect(result.folded == 0)
  }

  @Test("A Cyrillic word beside Latin words stays Cyrillic")
  func leavesCyrillicWordBesideLatinUntouched() {
    let privet = "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"
    let input = "Ich sagte \(privet)"
    let result = TextProcessingUtility.foldingCyrillicHomoglyphs(input)
    #expect(result.text == input)
    #expect(result.folded == 0)
  }

  @Test("Cyrillic capitals inside a Latin word fold to their Latin look-alikes")
  func foldsMixedCapitals() {
    // В (U+0412) and е (U+0435) plus ASCII "rlin".
    let input = "\u{0412}\u{0435}rlin"
    let result = TextProcessingUtility.foldingCyrillicHomoglyphs(input)
    #expect(result.text == "Berlin")
    #expect(result.folded == 2)
  }

  @Test("A German sentence with umlauts and ß is unchanged")
  func leavesUmlautsUntouched() {
    let input = "Für die größeren Briefe braucht Müller heißes Wasser."
    let result = TextProcessingUtility.foldingCyrillicHomoglyphs(input)
    #expect(result.text == input)
    #expect(result.folded == 0)
  }

  @Test("An empty string stays empty")
  func leavesEmptyStringUntouched() {
    let result = TextProcessingUtility.foldingCyrillicHomoglyphs("")
    #expect(result.text == "")
    #expect(result.folded == 0)
  }
}

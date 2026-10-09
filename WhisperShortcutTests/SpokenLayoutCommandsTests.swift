import Testing
@testable import WhisperShortcut_AppStore

@Suite("Spoken layout commands (offline dictation)")
struct SpokenLayoutCommandsTests {

  @Test("Doppelpunkt becomes a colon, with the model's stray punctuation removed")
  func colon() {
    #expect(TextProcessingUtility.applyingSpokenLayoutCommands(
      "Anamnese Doppelpunkt LWS-Schmerzen seit drei Wochen.")
      == "Anamnese: LWS-Schmerzen seit drei Wochen.")
    #expect(TextProcessingUtility.applyingSpokenLayoutCommands(
      "Anamnese, Doppelpunkt. Patient berichtet")
      == "Anamnese: Patient berichtet")
  }

  @Test("neuer Absatz and neue Zeile become line breaks")
  func paragraphs() {
    #expect(TextProcessingUtility.applyingSpokenLayoutCommands(
      "Anamnese Doppelpunkt Schmerzen. Neuer Absatz. Befund Doppelpunkt Tonus erhöht")
      == "Anamnese: Schmerzen.\n\nBefund: Tonus erhöht")
    #expect(TextProcessingUtility.applyingSpokenLayoutCommands("Erstens neue Zeile zweitens")
      == "Erstens\nzweitens")
  }

  @Test("Ordinary words and text without commands stay unchanged")
  func untouched() {
    let text = "Das ist der wichtigste Punkt, Komma hin oder her."
    #expect(TextProcessingUtility.applyingSpokenLayoutCommands(text) == text)
    #expect(TextProcessingUtility.applyingSpokenLayoutCommands("Doppelpunkte zählen") == "Doppelpunkte zählen")
  }

  @Test("A trailing command leaves a bare colon")
  func trailing() {
    #expect(TextProcessingUtility.applyingSpokenLayoutCommands("Befund Doppelpunkt.") == "Befund:")
  }
}

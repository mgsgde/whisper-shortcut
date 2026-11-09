import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Pilot-path fixes that need APIs added with the fix: the timing fallback and the Parakeet
/// glossary-echo skip. Companion to `SpokenPunctuationPilotTests`.
@Suite("Spoken-only pilot path: fallback and echo")
struct SpokenPunctuationPilotFallbackTests {

  @Test func timingFallbackKeepsSpokenMarks() {
    // Count mismatch (`filter` returned nil): commas, "?" and "!" stay, only semicolons go.
    let out = ParakeetPunctuationTiming.fallbackWithoutTiming(
      "Sehr geehrte Frau Müller, vielen Dank. Stimmt das? Ja!; ok")
    #expect(out == "Sehr geehrte Frau Müller, vielen Dank. Stimmt das? Ja! ok")
  }

  @Test func timingFallbackSpacesGluedComma() {
    #expect(ParakeetPunctuationTiming.fallbackWithoutTiming("50,Merkzeichen") == "50, Merkzeichen")
  }

  @Test func ellipsisMismatchStillFallsBackWithMarks() {
    let tokens: [ParakeetPunctuationTiming.Token] = [
      .init(text: "▁Also", start: 0.1, end: 0.4), .init(text: "...", start: 0.4, end: 0.5),
      .init(text: "▁gut", start: 0.9, end: 1.1), .init(text: ",", start: 1.1, end: 1.4),
      .init(text: "▁weiter", start: 1.6, end: 2.0),
    ]
    let text = "Also... gut, weiter"
    #expect(ParakeetPunctuationTiming.filter(text: text, tokens: tokens, audioDuration: 2.6) == nil)
    #expect(ParakeetPunctuationTiming.fallbackWithoutTiming(text) == text)
  }

  @Test func parakeetCannotEchoTheGlossary() {
    #expect(!SpeechService.canEchoGlossary(.parakeetUltra))
    #expect(SpeechService.canEchoGlossary(.whisperLargeTurbo))
    #expect(SpeechService.canEchoGlossary(.openAIGPT4oTranscribe))
    #expect(SpeechService.canEchoGlossary(.gemini31FlashLite))
  }

  @Test func echoStripStillWorksForPromptedModels() {
    // The strip itself is unchanged: it is just no longer called for Parakeet.
    let stripped = TextProcessingUtility.strippingTrailingGlossaryEcho(
      "Diagnosen: Diabetes mellitus Typ 2. PNP TEP.", glossaryTerms: ["PNP", "TEP"], mode: "TEST")
    #expect(stripped != "Diagnosen: Diabetes mellitus Typ 2. PNP TEP.")
  }
}

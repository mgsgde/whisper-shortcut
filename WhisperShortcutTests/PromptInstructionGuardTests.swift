import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Dictate Prompt instruction guard")
struct PromptInstructionGuardTests {

  @Test(
    "Mis-transcriptions are not instructions",
    arguments: [
      "0", "Oh.", "", "  ", "ja", "12.",
      "00:00:01.077 - 00:00:03.277\nI'm looking for a good book.",
      "00:00:01,077 --> 00:00:03,277",
    ])
  func rejected(_ text: String) {
    #expect(PromptInstructionGuard.isNotUnderstood(text))
  }

  @Test(
    "Legitimate short instructions pass",
    arguments: [
      "korrigiere", "kürzer", "fix", "Übersetze auf Englisch.", "corrigir",
      "Korrigiere Formular 0.", "Korriger formulere noe.", "Make it 10:30 sharp",
      "缩短", "短く", "요약",
    ])
  func accepted(_ text: String) {
    #expect(!PromptInstructionGuard.isNotUnderstood(text))
  }

  private let saved = ["Korrigiere, formuliere neu.", "Fasse in drei Sätzen zusammen", "Übersetze auf Englisch"]

  @Test("A near-miss of a saved prompt snaps to it")
  func snapsNearMiss() {
    #expect(PromptInstructionGuard.snapped("Korriger formulere noe.", savedPrompts: saved) == "Korrigiere, formuliere neu.")
    #expect(PromptInstructionGuard.snapped("korrigiere formuliere neu", savedPrompts: saved) == "Korrigiere, formuliere neu.")
    #expect(PromptInstructionGuard.snapped("Übersetze auf Englisch.", savedPrompts: saved) == "Übersetze auf Englisch")
  }

  @Test("The near-miss with a stray digit is just below the bar, so nothing snaps")
  func digitNearMissDoesNotSnap() {
    let key = PromptInstructionGuard.normalizedKey("Korrigiere Formular 0.")
    let target = PromptInstructionGuard.normalizedKey("Korrigiere, formuliere neu.")
    #expect(PromptInstructionGuard.similarity(key, target) < 0.8)
    #expect(PromptInstructionGuard.snapped("Korrigiere Formular 0.", savedPrompts: saved) == nil)
  }

  @Test("Unrelated, long, or empty input changes nothing")
  func noSnap() {
    #expect(PromptInstructionGuard.snapped("kürzer", savedPrompts: saved) == nil)
    #expect(PromptInstructionGuard.snapped("fix", savedPrompts: saved) == nil)
    #expect(PromptInstructionGuard.snapped("Korrigiere formuliere neu und mach es freundlicher bitte", savedPrompts: saved) == nil)
    #expect(PromptInstructionGuard.snapped("Korriger formulere noe", savedPrompts: []) == nil)
    #expect(PromptInstructionGuard.snapped("...", savedPrompts: saved) == nil)
  }

  @Test("Two saved prompts within reach means no snap")
  func ambiguous() {
    let twins = ["Mach es kürzer", "Mach es kurz"]
    #expect(PromptInstructionGuard.snapped("Mach es kurzer", savedPrompts: twins) == nil)
    // Duplicates by key are one prompt, not two.
    #expect(PromptInstructionGuard.snapped("Mach es kurzer", savedPrompts: ["Mach es kürzer", "mach es kürzer."]) != nil)
  }

  @Test("Similarity is case- and punctuation-insensitive, symmetric and bounded")
  func similarityBasics() {
    #expect(PromptInstructionGuard.normalizedKey("  Korrigiere,   FORMULIERE neu! ") == "korrigiere formuliere neu")
    #expect(PromptInstructionGuard.similarity("abc", "abc") == 1)
    #expect(PromptInstructionGuard.similarity("abc", "xyz") == 0)
    #expect(PromptInstructionGuard.similarity("kitten", "sitting") == PromptInstructionGuard.similarity("sitting", "kitten"))
  }

  @Test("The rejection is a non-retryable error with a popup message")
  func errorSurface() {
    #expect(!TranscriptionError.instructionNotUnderstood.isRetryable)
    let popup = SpeechErrorFormatter.titleAndBodyForPopup(.instructionNotUnderstood)
    #expect(!popup.body.isEmpty)
    #expect(!popup.shortTitle.isEmpty)
  }
}

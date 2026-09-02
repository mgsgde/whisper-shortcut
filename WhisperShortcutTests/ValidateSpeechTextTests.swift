import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("validateSpeechText")
struct ValidateSpeechTextTests {

  @Test("A normal transcript is accepted")
  func normalTranscriptAccepted() throws {
    try TextProcessingUtility.validateSpeechText(
      "Please transcribe this meeting for Sara tomorrow at three.",
      mode: "TRANSCRIPTION-MODE")
  }

  @Test("A short assistant refusal is rejected as no speech")
  func shortRefusalIsNoSpeech() {
    #expect(throws: TranscriptionError.noSpeechDetected) {
      try TextProcessingUtility.validateSpeechText(
        "I can transcribe that for you.",
        mode: "TRANSCRIPTION-MODE")
    }
  }

  @Test("A long transcript that merely contains a refusal phrase is kept")
  func longTranscriptWithRefusalSubstringKept() throws {
    let text = String(repeating: "We discussed the budget and next steps. ", count: 8)
      + "I can transcribe those notes later if needed."
    #expect(text.count >= 160)
    try TextProcessingUtility.validateSpeechText(text, mode: "TRANSCRIPTION-MODE")
  }

  @Test("A system pattern only matches as a prefix or the whole string")
  func systemPatternRequiresPrefix() throws {
    try TextProcessingUtility.validateSpeechText(
      "The meeting notes mention transcription: we should keep a written record.",
      mode: "TRANSCRIPTION-MODE")
    #expect(throws: TranscriptionError.promptLeakDetected) {
      try TextProcessingUtility.validateSpeechText(
        "transcription: hello there",
        mode: "TRANSCRIPTION-MODE")
    }
  }

  @Test("Empty result is no speech")
  func emptyIsNoSpeech() {
    #expect(throws: TranscriptionError.noSpeechDetected) {
      try TextProcessingUtility.validateSpeechText("   ", mode: "TRANSCRIPTION-MODE")
    }
  }
}

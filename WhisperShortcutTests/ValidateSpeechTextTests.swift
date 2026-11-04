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

  @Test("A context leak is rejected regardless of capitalization")
  func contextPrefixIsPromptLeak() {
    #expect(throws: TranscriptionError.promptLeakDetected) {
      try TextProcessingUtility.validateSpeechText("Context: foo", mode: "TRANSCRIPTION-MODE")
    }
  }

  @Test("A prompt suffix is stripped only at a word boundary")
  func suffixStripsOnlyAtWordBoundary() {
    #expect(
      TextProcessingUtility.normalizeTranscriptionText("helps you unremove filler words")
        == "helps you unremove filler words")
    #expect(
      TextProcessingUtility.normalizeTranscriptionText("Please remove filler words")
        == "Please")
  }

  @Test("A short German assistant refusal is no speech")
  func germanRefusalIsNoSpeech() {
    #expect(throws: TranscriptionError.noSpeechDetected) {
      try TextProcessingUtility.validateSpeechText(
        "Bitte geben Sie mir die Audiodatei, den ich transkribieren soll.",
        mode: "TRANSCRIPTION-MODE")
    }
    #expect(throws: TranscriptionError.noSpeechDetected) {
      try TextProcessingUtility.validateSpeechText(
        "Gib mir die Audiodatei zum Transkribieren.",
        mode: "TRANSCRIPTION-MODE")
    }
  }

  @Test("A German refusal is only treated as no-speech in transcription modes")
  func germanRefusalSkippedOutsideTranscription() throws {
    try TextProcessingUtility.validateSpeechText(
      "Bitte geben Sie mir die Audiodatei, den ich transkribieren soll.",
      mode: "PROMPT-MODE")
  }

  @Test("Three or more prompt keywords are a leak")
  func threePromptKeywordsAreALeak() {
    #expect(throws: TranscriptionError.promptLeakDetected) {
      try TextProcessingUtility.validateSpeechText(
        "Please convert speech to text and clean text with proper punctuation afterwards.",
        mode: "TRANSCRIPTION-MODE")
    }
  }

  @Test("Two prompt keywords are not enough to count as a leak")
  func twoPromptKeywordsAreKept() throws {
    try TextProcessingUtility.validateSpeechText(
      "Please convert speech to text and use proper punctuation when you can.",
      mode: "TRANSCRIPTION-MODE")
  }

  // MARK: - Whisper silence hallucinations

  /// The filter is a whole-transcript match against a closed set. These are the phrases measured
  /// on non-speech clips; each one must be dropped, in every casing/punctuation form Whisper
  /// actually emits.
  @Test("A transcript that is only a known hallucination is no speech", arguments: [
    "Thank you.",
    "thank you",
    "Thank you!",
    "Thanks for watching!",
    "thanks for watching",
    "You",
    "Bye.",
    "bye",
    "Vielen Dank.",
    "Untertitel der amara.org-Community",
    "Subtitles by the Amara.org Community",
    "Please subscribe",
    "Bitte abonnieren.",
    "  Thank you.  ",
  ])
  func phantomPhraseIsNoSpeech(text: String) {
    #expect(throws: TranscriptionError.noSpeechDetected) {
      try TextProcessingUtility.validateSpeechText(text, mode: "TRANSCRIPTION-MODE")
    }
  }

  /// The same phrases on the offline path, whose mode string is `"LOCAL-SPEECH"` and does not
  /// contain `"TRANSCRIPTION"` — the filter must still apply there, or it misses the one path it
  /// was written for.
  @Test("The filter also applies to the offline LOCAL-SPEECH mode")
  func phantomPhraseAppliesToOfflineMode() {
    #expect(throws: TranscriptionError.noSpeechDetected) {
      try TextProcessingUtility.validateSpeechText("Thank you.", mode: "LOCAL-SPEECH")
    }
  }

  /// A real sentence that merely *contains* a phantom phrase must survive: the filter is never a
  /// substring match.
  @Test("A real sentence containing a phantom phrase is kept", arguments: [
    "Thank you for the update on the lab results.",
    "I said thank you and left.",
    "Bye, see you tomorrow at nine.",
    "Please subscribe to the practice newsletter before Friday.",
  ])
  func realSentenceWithPhantomSubstringKept(text: String) throws {
    try TextProcessingUtility.validateSpeechText(text, mode: "TRANSCRIPTION-MODE")
  }

  @Test("Empty is still no speech, not a hallucination")
  func emptyStillNoSpeech() {
    #expect(throws: TranscriptionError.noSpeechDetected) {
      try TextProcessingUtility.validateSpeechText("   ", mode: "TRANSCRIPTION-MODE")
    }
  }

  /// With the toggle off the phrase passes through untouched — the user asked for it, e.g. because
  /// they dictate "You" as a standalone answer.
  @Test("Turning the filter off lets a phantom phrase through")
  func filterOffLetsPhantomThrough() throws {
    let key = UserDefaultsKeys.filterKnownWhisperHallucinations
    let original = UserDefaults.standard.object(forKey: key)
    defer {
      if let original { UserDefaults.standard.set(original, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }

    UserDefaults.standard.set(false, forKey: key)
    try TextProcessingUtility.validateSpeechText("Thank you.", mode: "TRANSCRIPTION-MODE")

    UserDefaults.standard.set(true, forKey: key)
    #expect(throws: TranscriptionError.noSpeechDetected) {
      try TextProcessingUtility.validateSpeechText("Thank you.", mode: "TRANSCRIPTION-MODE")
    }
  }

  @Test("The comparison form strips case, whitespace and trailing punctuation")
  func comparisonFormNormalizes() {
    #expect(TextProcessingUtility.phantomComparisonForm("  Thank YOU.  ") == "thank you")
    #expect(TextProcessingUtility.phantomComparisonForm("Bye!") == "bye")
    #expect(TextProcessingUtility.phantomComparisonForm("Thank you, Dr. Meyer.") == "thank you, dr. meyer")
  }
}

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("validateSpeechText", .serialized)
struct ValidateSpeechTextTests {

  private struct AcceptedCase: Sendable {
    let text: String
    let mode: String
    let label: String
  }

  private enum Expected: Sendable { case noSpeech, promptLeak }

  private struct RejectedCase: Sendable {
    let text: String
    let expected: Expected
    let label: String
  }

  private static let longTranscript =
    String(repeating: "We discussed the budget and next steps. ", count: 8)
    + "I can transcribe those notes later if needed."

  @Test(
    "Real speech is accepted",
    arguments: [
      AcceptedCase(
        text: "Please transcribe this meeting for Sara tomorrow at three.",
        mode: "TRANSCRIPTION-MODE", label: "normal transcript"),
      // >= 160 chars, so a refusal phrase inside it does not make it a refusal.
      AcceptedCase(
        text: longTranscript, mode: "TRANSCRIPTION-MODE",
        label: "long transcript that merely contains a refusal phrase"),
      AcceptedCase(
        text: "Bitte geben Sie mir die Audiodatei, den ich transkribieren soll.",
        mode: "PROMPT-MODE", label: "German refusal only counts as no-speech in transcription modes"),
      AcceptedCase(
        text: "Please convert speech to text and use proper punctuation when you can.",
        mode: "TRANSCRIPTION-MODE", label: "two prompt keywords are not enough for a leak"),
    ])
  private func accepts(_ c: AcceptedCase) throws {
    if c.label.hasPrefix("long") { #expect(c.text.count >= 160) }
    try TextProcessingUtility.validateSpeechText(c.text, mode: c.mode)
  }

  @Test(
    "Refusals, empties and prompt leaks are rejected with the matching error",
    arguments: [
      RejectedCase(
        text: "I can transcribe that for you.", expected: .noSpeech,
        label: "short assistant refusal"),
      RejectedCase(text: "   ", expected: .noSpeech, label: "empty result"),
      RejectedCase(text: "Context: foo", expected: .promptLeak, label: "context leak"),
      RejectedCase(
        text: "Bitte geben Sie mir die Audiodatei, den ich transkribieren soll.",
        expected: .noSpeech, label: "short German refusal"),
      RejectedCase(
        text: "Gib mir die Audiodatei zum Transkribieren.", expected: .noSpeech,
        label: "short German refusal, informal"),
      RejectedCase(
        text: "Please convert speech to text and clean text with proper punctuation afterwards.",
        expected: .promptLeak, label: "three or more prompt keywords"),
    ])
  private func rejects(_ c: RejectedCase) {
    switch c.expected {
    case .noSpeech:
      #expect(throws: TranscriptionError.noSpeechDetected, "\(c.label)") {
        try TextProcessingUtility.validateSpeechText(c.text, mode: "TRANSCRIPTION-MODE")
      }
    case .promptLeak:
      #expect(throws: TranscriptionError.promptLeakDetected, "\(c.label)") {
        try TextProcessingUtility.validateSpeechText(c.text, mode: "TRANSCRIPTION-MODE")
      }
    }
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

  @Test("A prompt suffix is stripped only at a word boundary")
  func suffixStripsOnlyAtWordBoundary() {
    #expect(
      TextProcessingUtility.normalizeTranscriptionText("helps you unremove filler words")
        == "helps you unremove filler words")
    #expect(
      TextProcessingUtility.normalizeTranscriptionText("Please remove filler words")
        == "Please")
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
      try TextProcessingUtility.validateSpeechText(
        text, mode: "LOCAL-SPEECH", audioSeconds: 1.0)
    }
  }

  /// Offline Whisper passes `"LOCAL-SPEECH"`. The filter runs on that mode only.
  @Test("The filter applies to the offline LOCAL-SPEECH mode")
  func phantomPhraseAppliesToOfflineMode() {
    #expect(throws: TranscriptionError.noSpeechDetected) {
      try TextProcessingUtility.validateSpeechText(
        "Thank you.", mode: "LOCAL-SPEECH", audioSeconds: 1.0)
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
    try TextProcessingUtility.validateSpeechText(
      text, mode: "LOCAL-SPEECH", audioSeconds: 1.0)
  }

  /// A clip of 2 s or more, or of unknown length, that transcribes to a single phrase is real
  /// dictation ("Vielen Dank" said on purpose), not silence filler.
  @Test("A long or unknown-length clip keeps a single-phrase transcript", arguments: [2.0, 5.0, Double?.none])
  func longClipKeepsPhrase(seconds: Double?) throws {
    try TextProcessingUtility.validateSpeechText(
      "Vielen Dank.", mode: "LOCAL-SPEECH", audioSeconds: seconds)
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
    try TextProcessingUtility.validateSpeechText(
      "Thank you.", mode: "LOCAL-SPEECH", audioSeconds: 1.0)

    UserDefaults.standard.set(true, forKey: key)
    #expect(throws: TranscriptionError.noSpeechDetected) {
      try TextProcessingUtility.validateSpeechText(
        "Thank you.", mode: "LOCAL-SPEECH", audioSeconds: 1.0)
    }
  }

  /// Cloud transcription uses `"TRANSCRIPTION-MODE"`. A real short "Vielen Dank." must survive;
  /// the phrase list is an offline-Whisper property.
  @Test("A short cloud transcript that is only a known phrase is kept")
  func cloudModeKeepsShortPhrase() throws {
    try TextProcessingUtility.validateSpeechText(
      "Vielen Dank.", mode: "TRANSCRIPTION-MODE", audioSeconds: 1.0)
  }

  @Test("The comparison form strips case, whitespace and trailing punctuation")
  func comparisonFormNormalizes() {
    #expect(TextProcessingUtility.phantomComparisonForm("  Thank YOU.  ") == "thank you")
    #expect(TextProcessingUtility.phantomComparisonForm("Bye!") == "bye")
    #expect(TextProcessingUtility.phantomComparisonForm("Thank you, Dr. Meyer.") == "thank you, dr. meyer")
  }
}

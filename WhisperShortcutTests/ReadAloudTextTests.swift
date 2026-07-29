import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Covers the two pure text gates on the Read Aloud / transcription paths. Both are regex-heavy
/// and silent when wrong: a bad pattern either leaves Markdown in the spoken text or throws away
/// a real transcript, and neither shows up as an error anywhere.
@Suite("Read Aloud text sanitizing")
struct SpeechTextSanitizerTests {

  @Test("Citation links are removed entirely, prose is kept")
  func stripsCitationLinks() {
    let markdown = "…long-term civilizational strategy.[[1]](https://samoburja.com/)"
    let spoken = SpeechTextSanitizer.plainSpeech(from: markdown)
    #expect(spoken == "…long-term civilizational strategy.")
  }

  @Test("Link labels survive, targets do not")
  func keepsLinkLabels() {
    let spoken = SpeechTextSanitizer.plainSpeech(from: "See [the report](https://example.com/a/b) now")
    #expect(spoken == "See the report now")
  }

  @Test("Emphasis and inline code markers are dropped, content stays")
  func stripsEmphasis() {
    let spoken = SpeechTextSanitizer.plainSpeech(
      from: "**Samo Burja** chairs *Palladium Magazine* and runs `bismarck --analyze`")
    #expect(spoken == "Samo Burja chairs Palladium Magazine and runs bismarck --analyze")
  }

  @Test("Headings, bullets and numbered list markers are dropped")
  func stripsBlockMarkers() {
    let spoken = SpeechTextSanitizer.plainSpeech(from: """
      ## Recent hot takes
      - First point
      * Second point
      1. Third point
      """)
    #expect(spoken == "Recent hot takes\nFirst point\nSecond point\nThird point")
  }

  @Test("Bare URLs are removed")
  func stripsBareURLs() {
    let spoken = SpeechTextSanitizer.plainSpeech(from: "Read it at https://brief.bismarckanalysis.com today")
    #expect(!spoken.contains("http"))
    #expect(spoken.contains("Read it at"))
    #expect(spoken.contains("today"))
  }

  @Test("Fenced code blocks are dropped rather than voiced")
  func dropsCodeBlocks() {
    let spoken = SpeechTextSanitizer.plainSpeech(from: """
      Here is the fix:

      ```swift
      let x = 1
      ```

      That is all.
      """)
    #expect(!spoken.contains("let x"))
    #expect(spoken.contains("Here is the fix:"))
    #expect(spoken.contains("That is all."))
  }

  @Test("A source list of nothing but links collapses away")
  func dropsSourceList() {
    let spoken = SpeechTextSanitizer.plainSpeech(
      from: "Body text.\n\n[1] samoburja.com   [2] x.com   [3] brief.bismarckanalysis.com")
    #expect(spoken.hasPrefix("Body text."))
    #expect(!spoken.contains("[1]"))
  }

  @Test("Plain prose passes through untouched")
  func leavesProseAlone() {
    let prose = "He is consistently optimistic about bold tech-driven human advancement."
    #expect(SpeechTextSanitizer.plainSpeech(from: prose) == prose)
  }
}

@Suite("Transcript plausibility gates")
struct TranscriptPlausibilityTests {

  private static let glossary = ["Sabaki", "Dance", "Magnus Gödde", "EnBW"]

  @Test("Glossary echo on a long near-silent chunk is discarded")
  func discardsGlossaryEcho() {
    // The real failure: 6.3 s of tail audio came back as exactly this.
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "sabaki.dance", audioDurationSeconds: 6.3, glossaryTerms: Self.glossary, mode: "TEST")
    #expect(result == "")
  }

  @Test("The same words survive when the audio is short enough to be them")
  func keepsPlausibleGlossaryUtterance() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "Sabaki Dance", audioDurationSeconds: 1.5, glossaryTerms: Self.glossary, mode: "TEST")
    #expect(result == "Sabaki Dance")
  }

  @Test("Short non-glossary speech is never discarded")
  func keepsShortRealSpeech() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "Ja, genau.", audioDurationSeconds: 8.0, glossaryTerms: Self.glossary, mode: "TEST")
    #expect(result == "Ja, genau.")
  }

  @Test("A glossary term inside a real sentence is never discarded")
  func keepsGlossaryTermInSentence() {
    let text = "Ich möchte das Sabaki Dance Feature verbessern und dann noch einmal testen."
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      text, audioDurationSeconds: 6.0, glossaryTerms: Self.glossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("Diacritics and case don't matter for the echo match")
  func foldsDiacritics() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "magnus goedde", audioDurationSeconds: 20.0,
      glossaryTerms: ["Magnus Gödde"], mode: "TEST")
    // "goedde" is not a diacritic fold of "Gödde", so this must survive rather than vanish.
    #expect(result == "magnus goedde")
  }

  @Test("An empty glossary disables the gate")
  func noGlossaryNoGate() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "sabaki.dance", audioDurationSeconds: 6.3, glossaryTerms: [], mode: "TEST")
    #expect(result == "sabaki.dance")
  }

  @Test("The upper bound still discards confabulated paragraphs")
  func discardsImplausiblyLongTranscript() {
    // The failure this gate exists for: 0.9 s of audio, 538 invented characters.
    let invented = String(repeating: "erfundener Text ", count: 40)  // 640 chars
    let result = TextProcessingUtility.discardingImplausibleTranscript(
      invented, audioDurationSeconds: 0.9, mode: "TEST")
    #expect(result == "")
  }

  @Test("Speech recorded at 2× playback speed is not mistaken for a hallucination")
  func keepsFastSpeech() {
    // Real case: a WhatsApp voice message played back at 2× produced 1017 correct characters
    // from 31.0 s of audio and the old 30 chars/s ceiling deleted all of it.
    let fast = String(repeating: "a", count: 1017)
    let result = TextProcessingUtility.discardingImplausibleTranscript(
      fast, audioDurationSeconds: 31.0, mode: "TEST")
    #expect(result == fast)
  }

  @Test("Even 3× playback survives the ceiling")
  func keepsVeryFastSpeech() {
    // ~50 chars/s — still under the 60 chars/s ceiling.
    let veryFast = String(repeating: "a", count: 1500)
    let result = TextProcessingUtility.discardingImplausibleTranscript(
      veryFast, audioDurationSeconds: 30.0, mode: "TEST")
    #expect(result == veryFast)
  }
}

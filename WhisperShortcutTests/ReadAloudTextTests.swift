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

  private static let openAIGlossary = [
    "Claude Code", "MCP", "Bachata", "sabaki.dance", "Datev", "Regulon", "Parakeet", "Codex",
  ]

  @Test("OpenAI-compatible path: a glossary echo from 11 s of audio is discarded")
  func discardsGlossaryEchoOnOpenAIPath() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "Claude Code.", audioDurationSeconds: 11.0,
      glossaryTerms: Self.openAIGlossary, mode: "OPENAI-TRANSCRIPTION")
    #expect(result == "")
  }

  @Test("OpenAI-compatible path: a real sentence with glossary terms stays")
  func keepsRealSentenceOnOpenAIPath() {
    let text = "Wir besprechen morgen die Datev-Anbindung mit Claude Code."
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      text, audioDurationSeconds: 4.0,
      glossaryTerms: Self.openAIGlossary, mode: "OPENAI-TRANSCRIPTION")
    #expect(result == text)
  }

  private static let meetingGlossary = [
    "Claude Code", "MCP", "Bachata", "sabaki.dance", "Wianco", "Datev", "Regulon", "Lemniskus",
    "Parakeet", "Vibe-Coding", "KMU", "Odoo", "Johanna", "Pia", "Codex", "Wellensteyn", "Goedde",
    "Claude", "Christoph", "Michelbach", "Cursor", "EnBW", "Grok", "GrokBot", "Opus", "Sonnet",
    "Gemini", "Implementer Queue", "Karlsruhe", "Kizomba", "Salsa", "AutoMagic", "Onepager",
    "Whisper Shortcut", "Schönstein",
  ]

  private static let meetingEchoList =
    "Claude Code, MCP und Bachata. sabaki.dance, Wianco und Datev. Regulon, Lemniskus und Parakeet. Vibe-Coding, KMU und Odoo. Johanna, Pia und Codex. Wellensteyn, Goedde und Claude. Christoph, Michelbach und Cursor. EnBW, Grok und GrokBot. Opus, Sonnet und Gemini. Implementer Queue, Karlsruhe und Kizomba. Salsa, AutoMagic und Onepager. Whisper Shortcut und Schönstein."

  @Test("A short glossary echo with 'und' between terms is discarded")
  func discardsShortEchoWithConnector() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "Claude Code, MCP und Bachata.", audioDurationSeconds: 12.0,
      glossaryTerms: Self.meetingGlossary, mode: "TEST")
    #expect(result == "")
  }

  @Test("A full glossary echo with 'und' between terms is discarded")
  func discardsLongEchoWithConnectors() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      Self.meetingEchoList, audioDurationSeconds: 29.0,
      glossaryTerms: Self.meetingGlossary, mode: "TEST")
    #expect(result == "")
  }

  @Test("A speaker-labelled full echo with connectors is discarded")
  func discardsSpeakerLabelledEchoWithConnectors() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "Speaker A: " + Self.meetingEchoList, audioDurationSeconds: 29.0,
      glossaryTerms: Self.meetingGlossary, mode: "TEST")
    #expect(result == "")
  }

  @Test("A real sentence with glossary names and 'und' stays")
  func keepsRealSentenceWithConnectors() {
    let text = "Ich spreche mit Johanna und Pia über Odoo und die KMU-Kunden."
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      text, audioDurationSeconds: 5.0,
      glossaryTerms: Self.meetingGlossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("A transcript of only connectors is not an echo")
  func keepsConnectorOnlyTranscript() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "und.", audioDurationSeconds: 6.0,
      glossaryTerms: Self.meetingGlossary, mode: "TEST")
    #expect(result == "und.")
  }

  @Test("Known limit: a fabricated sentence around glossary terms is not caught")
  func keepsFabricatedSentenceKnownLimit() {
    let text = "Claude Code hilft beim Vibe-Coding."
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      text, audioDurationSeconds: 12.0,
      glossaryTerms: Self.meetingGlossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("Only live-meeting chunks drop the glossary keywords")
  func keywordsOffForMeetingChunksOnly() {
    #expect(!SpeechService.shouldSendGlossaryKeywords(origin: .liveMeetingChunk))
    #expect(SpeechService.shouldSendGlossaryKeywords(origin: .dictation))
    #expect(SpeechService.shouldSendGlossaryKeywords(origin: nil))
  }

  @Test("A speaker-labelled glossary echo on a long near-silent chunk is discarded")
  func discardsSpeakerLabelledGlossaryEcho() {
    // 2026-10-28: 11.4 s of near-silent meeting audio came back as exactly this.
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "Speaker A: Claude Code.", audioDurationSeconds: 11.4,
      glossaryTerms: ["Claude", "Claude Code", "MCP"], mode: "TEST")
    #expect(result == "")
  }

  @Test("A speaker-labelled glossary list in glossary order is discarded")
  func discardsSpeakerLabelledOrderedGlossary() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "Speaker A: Claude, MCP, Bachata, Odoo.", audioDurationSeconds: 25.0,
      glossaryTerms: ["Claude", "Christoph", "MCP", "Bachata", "Odoo"], mode: "TEST")
    #expect(result == "")
  }

  @Test("A long speaker-labelled glossary list clears the length floor and is still discarded")
  func discardsLongSpeakerLabelledOrderedGlossary() {
    // Above the 3 chars/s floor, so only the ordered-list rule can catch it.
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "Speaker A: Claude, Christoph, Michelbach, Cursor, EnBW, Grok, Opus, Sonnet, Gemini.",
      audioDurationSeconds: 10.0,
      glossaryTerms: [
        "Claude", "Christoph", "Michelbach", "Cursor", "EnBW", "Grok", "Opus", "Sonnet", "Gemini",
      ],
      mode: "TEST")
    #expect(result == "")
  }

  @Test("Real speech with speaker labels is kept")
  func keepsRealSpeechWithSpeakerLabels() {
    let text = "Speaker A: Ja, genau.\nSpeaker B: Claude Code ist gut."
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      text, audioDurationSeconds: 8.0, glossaryTerms: ["Claude Code"], mode: "TEST")
    #expect(result == text)
  }

  @Test("A short real glossary utterance with a speaker label is kept")
  func keepsShortSpeakerLabelledGlossaryUtterance() {
    let text = "Speaker A: Claude Code."
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      text, audioDurationSeconds: 1.5, glossaryTerms: ["Claude Code"], mode: "TEST")
    #expect(result == text)
  }

  @Test("A speaker label with nothing after it is discarded")
  func discardsBareSpeakerLabel() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "Speaker A:", audioDurationSeconds: 10.0, glossaryTerms: ["Claude Code"], mode: "TEST")
    #expect(result == "")
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

  private static let longEchoList = "Claude, Christoph, Michelbach, Cursor, EnBW, Grok, GrokBot, Opus, Sonnet, Gemini, Implementer Queue, Karlsruhe, Kizomba, Salsa, AutoMagic, Onepager, Whisper Shortcut, Schönstein, BlockInfinity, Claude Code, MCP, Bachata, sabaki.dance, Wianco, Datev, Regulon, Lemniskus, Parakeet, Vibe-Coding, KMU, Odoo, Johanna, Pia, Codex, Wellensteyn, Goedde"
  private static var longEchoGlossary: [String] { longEchoList.components(separatedBy: ", ") }

  @Test("The whole glossary read out in order is discarded whatever its length")
  func discardsFullGlossaryList() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      Self.longEchoList + ".", audioDurationSeconds: 25, glossaryTerms: Self.longEchoGlossary, mode: "TEST")
    #expect(result == "")
  }

  // Audio is 5 s here, not 25 s: at 25 s these ~25 chars sit under the 3 chars/s floor and the
  // pre-existing short-text rule would fire, so the new ordered-list rule would go untested.
  @Test("Four glossary terms in glossary order are discarded")
  func discardsFourOrderedTerms() {
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      "Claude, Cursor, Grok, Opus", audioDurationSeconds: 5, glossaryTerms: Self.longEchoGlossary, mode: "TEST")
    #expect(result == "")
  }

  @Test("Glossary terms in reverse order stay")
  func keepsReversedTerms() {
    let text = "Opus, Grok, Cursor, Claude"
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      text, audioDurationSeconds: 5, glossaryTerms: Self.longEchoGlossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("Three ordered terms stay")
  func keepsThreeOrderedTerms() {
    let text = "Claude Cursor Grok"
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      text, audioDurationSeconds: 5, glossaryTerms: Self.longEchoGlossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("A real sentence with glossary names and other words stays")
  func keepsSentenceWithGlossaryNames() {
    let text = "Wir haben Claude, Cursor, Grok, Opus und Sonnet heute verglichen und dann entschieden."
    let result = TextProcessingUtility.discardingGlossaryEchoTranscript(
      text, audioDurationSeconds: 25, glossaryTerms: Self.longEchoGlossary, mode: "TEST")
    #expect(result == text)
  }

  private static let trailingEchoGlossary = ["Joschka", "SumUp", "lemniscus", "WhisperShortcut"]

  @Test("Report A drops the glossary tacked on after the sentence")
  func stripsTrailingGlossaryEchoReportA() {
    let text = "Wir kriegen von der Personalabteilung immer Ein- und Austrittslisten, damit ausgetretene Mitarbeiter im System gesperrt werden. Joschka SumUp lemniscus"
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: Self.trailingEchoGlossary, mode: "TEST")
    #expect(result == "Wir kriegen von der Personalabteilung immer Ein- und Austrittslisten, damit ausgetretene Mitarbeiter im System gesperrt werden.")
  }

  @Test("Report B drops the glossary tacked on after the sentence")
  func stripsTrailingGlossaryEchoReportB() {
    let text = "Ein Kunde Medizintechnik Bartsch hat eine Anfrage an mich geschickt. Hintergrund, ich habe Im Flyer den Flyer für unsere Spracherkennung WhisperShortcut zugeschickt. Joschka, SumUp, lemniscus, WhisperShortcut."
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: Self.trailingEchoGlossary, mode: "TEST")
    #expect(result == "Ein Kunde Medizintechnik Bartsch hat eine Anfrage an mich geschickt. Hintergrund, ich habe Im Flyer den Flyer für unsere Spracherkennung WhisperShortcut zugeschickt.")
  }

  @Test("A single glossary term after the sentence stays")
  func keepsSingleTrailingGlossaryTerm() {
    let text = "Das war's. SumUp."
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: Self.trailingEchoGlossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("A lone term after a full-length sentence is stripped")
  func stripsSingleTermAfterLongHead() {
    let text = "Das MacBook Air hat ein 16 zu 10 Display, das heißt, du hast in der Höhe noch mal mehr Display. Also gefühlt wie ein 14 Zoll Notebook. Joschka."
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: Self.trailingEchoGlossary, mode: "TEST")
    #expect(result == "Das MacBook Air hat ein 16 zu 10 Display, das heißt, du hast in der Höhe noch mal mehr Display. Also gefühlt wie ein 14 Zoll Notebook.")
  }

  @Test("A sign-off name stays")
  func keepsSignOffName() {
    let text = "Viele Grüße. Joschka."
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: Self.trailingEchoGlossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("Out-of-order terms after a long head stay")
  func keepsOutOfOrderAfterLongHead() {
    let text = "Ich habe das heute mit dem neuen Tool gebaut. SumUp lemniscus Joschka."
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: Self.trailingEchoGlossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("The same single term twice stays")
  func keepsRepeatedSingleTerm() {
    let text = "Ich habe das heute mit dem neuen Tool gebaut. Joschka Joschka."
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: Self.trailingEchoGlossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("A multi-word term counts as one term")
  func stripsMultiWordSingleTerm() {
    let text = "Ich habe das heute mit dem neuen Tool gebaut. Claude Code."
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: ["Claude Code"], mode: "TEST")
    #expect(result == "Ich habe das heute mit dem neuen Tool gebaut.")
  }

  @Test("Glossary words out of order stay")
  func keepsOutOfOrderGlossaryTail() {
    let text = "Das war's. WhisperShortcut Joschka."
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: Self.trailingEchoGlossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("A real sentence that mentions glossary terms stays")
  func keepsTailWithNonGlossaryWords() {
    let text = "Das war's. Wir nutzen SumUp und lemniscus."
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: Self.trailingEchoGlossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("A dictated list after a colon stays")
  func keepsListAfterColon() {
    let text = "Teilnehmer: Joschka, SumUp"
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: Self.trailingEchoGlossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("Glossary words with no sentence boundary stay")
  func keepsGlossaryWithoutBoundary() {
    let text = "Joschka SumUp"
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: Self.trailingEchoGlossary, mode: "TEST")
    #expect(result == text)
  }

  @Test("A dot inside a token is not a sentence boundary")
  func keepsDottedToken() {
    let text = "sabaki.dance"
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: ["Sabaki", "Dance"], mode: "TEST")
    #expect(result == text)
  }

  @Test("An empty glossary disables the trailing-echo strip")
  func keepsTrailingEchoWhenGlossaryEmpty() {
    let text = "Hallo. Joschka SumUp"
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: [], mode: "TEST")
    #expect(result == text)
  }

  @Test("A newline is a sentence boundary for a trailing glossary echo")
  func stripsGlossaryEchoAfterNewline() {
    let text = "Erster Absatz.\nJoschka, SumUp"
    let result = TextProcessingUtility.strippingTrailingGlossaryEcho(
      text, glossaryTerms: Self.trailingEchoGlossary, mode: "TEST")
    #expect(result == "Erster Absatz.")
  }
}

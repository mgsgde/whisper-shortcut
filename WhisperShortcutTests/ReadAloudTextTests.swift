import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Covers the two pure text gates on the Read Aloud / transcription paths. Both are regex-heavy
/// and silent when wrong: a bad pattern either leaves Markdown in the spoken text or throws away
/// a real transcript, and neither shows up as an error anywhere.
@Suite("Read Aloud text sanitizing")
struct SpeechTextSanitizerTests {

  @Test("Markdown is reduced to plain speech: citations, link labels, emphasis, block markers", arguments: [
    // Citation links are removed entirely, prose is kept.
    ("…long-term civilizational strategy.[[1]](https://samoburja.com/)", "…long-term civilizational strategy."),
    // Link labels survive, targets do not.
    ("See [the report](https://example.com/a/b) now", "See the report now"),
    // Emphasis and inline code markers are dropped, content stays.
    ("**Samo Burja** chairs *Palladium Magazine* and runs `bismarck --analyze`",
     "Samo Burja chairs Palladium Magazine and runs bismarck --analyze"),
    // Headings, bullets and numbered list markers are dropped.
    ("## Recent hot takes\n- First point\n* Second point\n1. Third point",
     "Recent hot takes\nFirst point\nSecond point\nThird point"),
    // Plain prose passes through untouched.
    ("He is consistently optimistic about bold tech-driven human advancement.",
     "He is consistently optimistic about bold tech-driven human advancement."),
  ])
  func plainSpeech(markdown: String, expected: String) {
    #expect(SpeechTextSanitizer.plainSpeech(from: markdown) == expected)
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

  @Test("An unterminated final fence is dropped rather than voiced")
  func dropsUnterminatedFence() {
    let spoken = SpeechTextSanitizer.plainSpeech(from: """
      Here is the sketch:

      ```swift
      let x = 1
      let y = 2
      """)
    #expect(!spoken.contains("let x"))
    #expect(spoken.contains("Here is the sketch:"))
  }

  @Test("Grok leaked search tokens are stripped")
  func stripsGrokSearchTokens() {
    let spoken = SpeechTextSanitizer.plainSpeech(
      from: "The paper argues otherwise [web:9] and the thread agrees [x:3].")
    #expect(!spoken.contains("[web:"))
    #expect(!spoken.contains("[x:"))
    #expect(spoken.contains("The paper argues otherwise"))
    #expect(spoken.contains("and the thread agrees"))
  }

  @Test("Table rows become comma-separated speech")
  func tableRowsBecomePauses() {
    let spoken = SpeechTextSanitizer.plainSpeech(from: """
      | Name | Role |
      | --- | --- |
      | Ada | Engineer |
      """)
    #expect(!spoken.contains("|"))
    #expect(spoken.contains("Name, Role"))
    #expect(spoken.contains("Ada, Engineer"))
  }
}

private let echoGlossary = ["Sabaki", "Dance", "Magnus Gödde", "EnBW"]

private let meetingGlossary = [
  "Claude Code", "MCP", "Bachata", "sabaki.dance", "Wianco", "Datev", "Regulon", "Lemniskus",
  "Parakeet", "Vibe-Coding", "KMU", "Odoo", "Johanna", "Pia", "Codex", "Wellensteyn", "Goedde",
  "Claude", "Christoph", "Michelbach", "Cursor", "EnBW", "Grok", "GrokBot", "Opus", "Sonnet",
  "Gemini", "Implementer Queue", "Karlsruhe", "Kizomba", "Salsa", "AutoMagic", "Onepager",
  "Whisper Shortcut", "Schönstein",
]

private let meetingEchoList =
  "Claude Code, MCP und Bachata. sabaki.dance, Wianco und Datev. Regulon, Lemniskus und Parakeet. Vibe-Coding, KMU und Odoo. Johanna, Pia und Codex. Wellensteyn, Goedde und Claude. Christoph, Michelbach und Cursor. EnBW, Grok und GrokBot. Opus, Sonnet und Gemini. Implementer Queue, Karlsruhe und Kizomba. Salsa, AutoMagic und Onepager. Whisper Shortcut und Schönstein."

private let longEchoList = "Claude, Christoph, Michelbach, Cursor, EnBW, Grok, GrokBot, Opus, Sonnet, Gemini, Implementer Queue, Karlsruhe, Kizomba, Salsa, AutoMagic, Onepager, Whisper Shortcut, Schönstein, BlockInfinity, Claude Code, MCP, Bachata, sabaki.dance, Wianco, Datev, Regulon, Lemniskus, Parakeet, Vibe-Coding, KMU, Odoo, Johanna, Pia, Codex, Wellensteyn, Goedde"
private let longEchoGlossary = longEchoList.components(separatedBy: ", ")

private let trailingEchoGlossary = ["Joschka", "SumUp", "lemniscus", "WhisperShortcut"]

private let realGlossaryTerms = ["Claude", "Christoph", "Michelbach", "Cursor", "EnBW", "Grok",
  "GrokBot", "Opus", "Sonnet", "Gemini", "Implementer Queue", "Karlsruhe", "Kizomba", "Salsa",
  "AutoMagic", "Onepager", "Whisper Shortcut", "Schönstein", "BlockInfinity", "Claude Code", "MCP",
  "Bachata", "sabaki.dance", "Wianco", "Datev", "Regulon", "Lemniskus", "Parakeet", "Vibe-Coding",
  "KMU", "Odoo", "Johanna", "Pia", "Codex", "Wellensteyn", "Gödde", "Seiter", "Anthropic",
  "Azure DevOps", "Läuffer", "cloud session", "Frau Dr. Läuffer", "Dr. Läuffer", "Frau Läuffer",
  "Dependabot", "Joschka", "Ramin", "Baileys", "Vattenfall"]
private let keywordOrderEcho = "Claude Code MCP Bachata sabaki.dance Wianco Datev Regulon Lemniskus Parakeet Vibe-Coding KMU Odoo Johanna Pia Codex Wellensteyn Gödde Läuffer Frau Dr. Läuffer Dr. Läuffer Frau Läuffer Dependabot Joschka Ramin Baileys Vattenfall Claude Christoph Michelbach Cursor EnBW Grok GrokBot Opus Sonnet Gemini Implementer Queue Karlsruhe Kizomba Salsa AutoMagic Onepager Whisper Shortcut Schönstein BlockInfinity Seiter Anthropic Azure DevOps cloud session"

@Suite("Transcript plausibility gates")
struct TranscriptPlausibilityTests {

  @Test("A glossary echo is discarded to an empty transcript", arguments: [
    // The real failure: 6.3 s of tail audio came back as exactly this.
    ("sabaki.dance", 6.3, echoGlossary, "echo on a long near-silent chunk"),
    ("Claude Code, MCP und Bachata.", 12.0, meetingGlossary, "short echo with 'und' between terms"),
    (meetingEchoList, 29.0, meetingGlossary, "full echo with 'und' between terms"),
    ("Speaker A: " + meetingEchoList, 29.0, meetingGlossary, "speaker-labelled full echo with connectors"),
    // 2026-10-28: 11.4 s of near-silent meeting audio came back as exactly this.
    ("Speaker A: Claude Code.", 11.4, ["Claude", "Claude Code", "MCP"], "speaker-labelled echo on near-silent chunk"),
    ("Speaker A: Claude, MCP, Bachata, Odoo.", 25.0, ["Claude", "Christoph", "MCP", "Bachata", "Odoo"],
     "speaker-labelled list in glossary order"),
    // Above the 3 chars/s floor, so only the ordered-list rule can catch it.
    ("Speaker A: Claude, Christoph, Michelbach, Cursor, EnBW, Grok, Opus, Sonnet, Gemini.", 10.0,
     ["Claude", "Christoph", "Michelbach", "Cursor", "EnBW", "Grok", "Opus", "Sonnet", "Gemini"],
     "long speaker-labelled ordered list clears the length floor"),
    ("Speaker A:", 10.0, ["Claude Code"], "speaker label with nothing after it"),
    (longEchoList + ".", 25.0, longEchoGlossary, "whole glossary read out in order, whatever its length"),
    // Audio is 5 s, not 25 s: at 25 s these ~25 chars sit under the 3 chars/s floor and the
    // pre-existing short-text rule would fire, so the ordered-list rule would go untested.
    ("Claude, Cursor, Grok, Opus", 5.0, longEchoGlossary, "four glossary terms in glossary order"),
    (keywordOrderEcho + ".", 11.0, realGlossaryTerms, "pure echo in keywords order (one wrap-around)"),
  ])
  func discardsGlossaryEcho(text: String, duration: Double, glossary: [String], label: String) {
    #expect(
      TextProcessingUtility.discardingGlossaryEchoTranscript(
        text, audioDurationSeconds: duration, glossaryTerms: glossary, mode: "TEST") == "", "\(label)")
  }

  @Test("Real speech that merely contains glossary terms is kept unchanged", arguments: [
    ("Sabaki Dance", 1.5, echoGlossary, "same words survive when the audio is short enough to be them"),
    ("Ja, genau.", 8.0, echoGlossary, "short non-glossary speech"),
    ("Ich möchte das Sabaki Dance Feature verbessern und dann noch einmal testen.", 6.0, echoGlossary,
     "glossary term inside a real sentence"),
    ("sabaki.dance", 6.3, [String](), "empty glossary disables the gate"),
    ("Ich spreche mit Johanna und Pia über Odoo und die KMU-Kunden.", 5.0, meetingGlossary,
     "real sentence with glossary names and 'und'"),
    ("und.", 6.0, meetingGlossary, "transcript of only connectors is not an echo"),
    ("Speaker A: Ja, genau.\nSpeaker B: Claude Code ist gut.", 8.0, ["Claude Code"], "real speech with speaker labels"),
    ("Speaker A: Claude Code.", 1.5, ["Claude Code"], "short real glossary utterance with a speaker label"),
    ("Opus, Grok, Cursor, Claude", 5.0, longEchoGlossary, "glossary terms in reverse order"),
    ("Claude Cursor Grok", 5.0, longEchoGlossary, "three ordered terms"),
    ("Wir haben Claude, Cursor, Grok, Opus und Sonnet heute verglichen und dann entschieden.", 25.0,
     longEchoGlossary, "real sentence with glossary names and other words"),
    ("Claude, Grok, Cursor, Opus", 5.0, longEchoGlossary, "four terms with one order break stay"),
  ])
  func keepsRealSpeech(text: String, duration: Double, glossary: [String], label: String) {
    #expect(
      TextProcessingUtility.discardingGlossaryEchoTranscript(
        text, audioDurationSeconds: duration, glossaryTerms: glossary, mode: "TEST") == text, "\(label)")
  }

  @Test("Only live-meeting chunks drop the glossary keywords")
  func keywordsOffForMeetingChunksOnly() {
    #expect(!SpeechService.shouldSendGlossaryKeywords(origin: .liveMeetingChunk))
    #expect(SpeechService.shouldSendGlossaryKeywords(origin: .dictation))
    #expect(SpeechService.shouldSendGlossaryKeywords(origin: nil))
  }

  @Test("Implausible length ceiling: confabulated paragraphs go, 2x playback speech stays", arguments: [
    // The failure this gate exists for: 0.9 s of audio, 538 invented characters (640 here).
    (String(repeating: "erfundener Text ", count: 40), 0.9, false, "confabulated paragraph"),
    // Real case: a WhatsApp voice message at 2x produced 1017 correct characters from 31.0 s and
    // the old 30 chars/s ceiling deleted all of it.
    (String(repeating: "a", count: 1017), 31.0, true, "2x playback speed"),
  ])
  func implausibleLength(text: String, duration: Double, kept: Bool, label: String) {
    let result = TextProcessingUtility.discardingImplausibleTranscript(
      text, audioDurationSeconds: duration, mode: "TEST")
    #expect(result == (kept ? text : ""), "\(label)")
  }

  @Test("Trailing glossary echo is stripped only after a sentence boundary and only for 2+ ordered terms (or a long head)",
        arguments: [
    // Report A / Report B regressions: the glossary tacked on after the sentence.
    ("Wir kriegen von der Personalabteilung immer Ein- und Austrittslisten, damit ausgetretene Mitarbeiter im System gesperrt werden. Joschka SumUp lemniscus",
     trailingEchoGlossary,
     "Wir kriegen von der Personalabteilung immer Ein- und Austrittslisten, damit ausgetretene Mitarbeiter im System gesperrt werden.",
     "Report A"),
    ("Ein Kunde Medizintechnik Bartsch hat eine Anfrage an mich geschickt. Hintergrund, ich habe Im Flyer den Flyer für unsere Spracherkennung WhisperShortcut zugeschickt. Joschka, SumUp, lemniscus, WhisperShortcut.",
     trailingEchoGlossary,
     "Ein Kunde Medizintechnik Bartsch hat eine Anfrage an mich geschickt. Hintergrund, ich habe Im Flyer den Flyer für unsere Spracherkennung WhisperShortcut zugeschickt.",
     "Report B"),
    ("Das war's. SumUp.", trailingEchoGlossary, "Das war's. SumUp.", "single glossary term after the sentence stays"),
    ("Das MacBook Air hat ein 16 zu 10 Display, das heißt, du hast in der Höhe noch mal mehr Display. Also gefühlt wie ein 14 Zoll Notebook. Joschka.",
     trailingEchoGlossary,
     "Das MacBook Air hat ein 16 zu 10 Display, das heißt, du hast in der Höhe noch mal mehr Display. Also gefühlt wie ein 14 Zoll Notebook.",
     "lone term after a full-length sentence is stripped"),
    ("Ich habe das heute mit dem neuen Tool gebaut. SumUp lemniscus Joschka.", trailingEchoGlossary,
     "Ich habe das heute mit dem neuen Tool gebaut. SumUp lemniscus Joschka.", "out-of-order terms after a long head stay"),
    ("Ich habe das heute mit dem neuen Tool gebaut. Joschka Joschka.", trailingEchoGlossary,
     "Ich habe das heute mit dem neuen Tool gebaut. Joschka Joschka.", "same single term twice stays"),
    ("Ich habe das heute mit dem neuen Tool gebaut. Claude Code.", ["Claude Code"],
     "Ich habe das heute mit dem neuen Tool gebaut.", "multi-word term counts as one term"),
    ("Das war's. Wir nutzen SumUp und lemniscus.", trailingEchoGlossary,
     "Das war's. Wir nutzen SumUp und lemniscus.", "real sentence mentioning glossary terms stays"),
    ("Teilnehmer: Joschka, SumUp", trailingEchoGlossary, "Teilnehmer: Joschka, SumUp", "dictated list after a colon stays"),
    ("Joschka SumUp", trailingEchoGlossary, "Joschka SumUp", "no sentence boundary stays"),
    ("sabaki.dance", ["Sabaki", "Dance"], "sabaki.dance", "a dot inside a token is not a boundary"),
    ("Hallo. Joschka SumUp", [String](), "Hallo. Joschka SumUp", "empty glossary disables the strip"),
    ("Erster Absatz.\nJoschka, SumUp", trailingEchoGlossary, "Erster Absatz.", "newline is a sentence boundary"),
    ("Ah, was da natürlich noch cool wäre, wenn die aufgeladen ist. Das wäre vielleicht noch cool. "
        + keywordOrderEcho + ".",
     realGlossaryTerms,
     "Ah, was da natürlich noch cool wäre, wenn die aufgeladen ist. Das wäre vielleicht noch cool.",
     "2026-11-10: whole glossary in keywords order with Dr. dots inside"),
    ("Wir haben heute verglichen. Opus Grok Sonnet Claude Gemini Cursor.", realGlossaryTerms,
     "Wir haben heute verglichen. Opus Grok Sonnet Claude Gemini Cursor.",
     "short shuffled list of terms after a sentence stays"),
    ("Das war's. SumUp und lemniscus.", trailingEchoGlossary,
     "Das war's. SumUp und lemniscus.", "connector inside a trailing pair stays"),
  ])
  func strippingTrailingEcho(text: String, glossary: [String], expected: String, label: String) {
    #expect(
      TextProcessingUtility.strippingTrailingGlossaryEcho(text, glossaryTerms: glossary, mode: "TEST") == expected,
      "\(label)")
  }
}

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The Smart Rewrite gate. Every false negative here costs the user a 2–6 s Gemini round trip on
/// text the rewrite would return unchanged; every false positive sends `{`, `|` or a URL to the
/// voice verbatim. The gate is meant to be strict — when in doubt it says "not prose".
@Suite("Read Aloud — plain-prose gate for Smart Rewrite")
struct SpeechTextProseGateTests {

  @Test("German prose with numbers is plain prose")
  func germanProse() {
    let text = """
      Die Nordsee ist ein Randmeer des Atlantischen Ozeans. Sie liegt zwischen Großbritannien, \
      Norwegen, Dänemark, Deutschland, den Niederlanden, Belgien und Frankreich. Die Nordsee hat \
      eine Fläche von rund 575.000 Quadratkilometern. Ihre größte Tiefe erreicht sie in der \
      Norwegischen Rinne mit etwa 725 Metern.
      """
    #expect(SpeechTextSanitizer.looksLikePlainProse(text))
  }

  @Test("English prose with quotes, a question and a parenthesis is plain prose")
  func englishProse() {
    let text = "Is this the right approach? I think so (for now). \"Ship it,\" she said."
    #expect(SpeechTextSanitizer.looksLikePlainProse(text))
  }

  @Test("Multi-paragraph prose is plain prose")
  func paragraphs() {
    let text = "First paragraph ends here.\n\nSecond paragraph also ends properly."
    #expect(SpeechTextSanitizer.looksLikePlainProse(text))
  }

  @Test("Markdown keeps the rewrite on", arguments: [
    "# Heading\n\nSome text below it.",
    "- first item\n- second item.",
    "1. first step\n2. second step.",
    "Run `swift build` and wait.",
    "```swift\nlet x = 1\n```",
    "This is **important** to note.",
    "See [the docs](https://example.com) for details.",
    "| a | b |\n|---|---|\n| 1 | 2 |",
  ])
  func markdown(_ text: String) {
    #expect(!SpeechTextSanitizer.looksLikePlainProse(text))
  }

  @Test("URLs and file paths keep the rewrite on", arguments: [
    "Read more at https://example.com/page today.",
    "Visit www.example.org for the schedule.",
    "The config lives in /Users/me/Library/Preferences/app.plist now.",
    "Edit ./scripts/build.sh before running it.",
  ])
  func urlsAndPaths(_ text: String) {
    #expect(!SpeechTextSanitizer.looksLikePlainProse(text))
  }

  @Test("Code and logs keep the rewrite on", arguments: [
    "func run() { return 1 }",
    "{\"name\": \"value\", \"count\": 3}",
    "2026-09-14T08:54:57.612Z INFO Starting synthesis",
    "08:54:57.612 Df WhisperShortcut[77226] TTS: Sending request",
    "SELECT id, name FROM users WHERE id = 42;",
    "let result = items.map { $0.count }",
  ])
  func codeAndLogs(_ text: String) {
    #expect(!SpeechTextSanitizer.looksLikePlainProse(text))
  }

  @Test("Fragments that never end a sentence keep the rewrite on")
  func fragments() {
    #expect(!SpeechTextSanitizer.looksLikePlainProse("Meeting notes Tuesday budget headcount"))
    #expect(!SpeechTextSanitizer.looksLikePlainProse(""))
    #expect(!SpeechTextSanitizer.looksLikePlainProse("   \n  "))
  }

  @Test("Symbol- and digit-heavy text keeps the rewrite on")
  func symbolHeavy() {
    #expect(!SpeechTextSanitizer.looksLikePlainProse("ID 4f9a-22b1-88c0-1d2e, ref 2026/09/14, qty 1200, total 4.599,00 EUR."))
  }
}

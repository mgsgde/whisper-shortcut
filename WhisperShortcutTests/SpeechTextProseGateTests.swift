import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The Smart Rewrite gate. Every false negative here costs the user a 2–6 s Gemini round trip on
/// text the rewrite would return unchanged; every false positive sends `{`, `|` or a URL to the
/// voice verbatim. The gate is meant to be strict — when in doubt it says "not prose".
@Suite("Read Aloud — plain-prose gate for Smart Rewrite")
struct SpeechTextProseGateTests {

  @Test("Plain prose keeps the rewrite off", arguments: [
    // German prose with numbers
    """
    Die Nordsee ist ein Randmeer des Atlantischen Ozeans. Sie liegt zwischen Großbritannien, \
    Norwegen, Dänemark, Deutschland, den Niederlanden, Belgien und Frankreich. Die Nordsee hat \
    eine Fläche von rund 575.000 Quadratkilometern. Ihre größte Tiefe erreicht sie in der \
    Norwegischen Rinne mit etwa 725 Metern.
    """,
    // English with quotes, a question and a parenthesis
    "Is this the right approach? I think so (for now). \"Ship it,\" she said.",
    // A single sentence closed by German or French quotation marks
    "Er sagte nur: „Das reicht für heute.“",
    "Elle a dit : « C'est tout pour aujourd'hui. »",
    // Multi-paragraph prose
    "First paragraph ends here.\n\nSecond paragraph also ends properly.",
  ])
  func prose(_ text: String) {
    #expect(SpeechTextSanitizer.looksLikePlainProse(text))
  }

  @Test("Markdown, URLs, paths, code, logs, fragments and symbol-heavy text keep the rewrite on", arguments: [
    // markdown
    "# Heading\n\nSome text below it.",
    "- first item\n- second item.",
    "1. first step\n2. second step.",
    "Run `swift build` and wait.",
    "```swift\nlet x = 1\n```",
    "This is **important** to note.",
    "See [the docs](https://example.com) for details.",
    "| a | b |\n|---|---|\n| 1 | 2 |",
    // URLs and file paths
    "Read more at https://example.com/page today.",
    "Visit www.example.org for the schedule.",
    "The config lives in /Users/me/Library/Preferences/app.plist now.",
    "Edit ./scripts/build.sh before running it.",
    // code and logs
    "func run() { return 1 }",
    "{\"name\": \"value\", \"count\": 3}",
    "2026-09-14T08:54:57.612Z INFO Starting synthesis",
    "08:54:57.612 Df WhisperShortcut[77226] TTS: Sending request",
    "SELECT id, name FROM users WHERE id = 42;",
    "let result = items.map { $0.count }",
    // fragments that never end a sentence
    "Meeting notes Tuesday budget headcount",
    "",
    "   \n  ",
    // symbol- and digit-heavy
    "ID 4f9a-22b1-88c0-1d2e, ref 2026/09/14, qty 1200, total 4.599,00 EUR.",
  ])
  func notProse(_ text: String) {
    #expect(!SpeechTextSanitizer.looksLikePlainProse(text))
  }
}

/// The deterministic backstop for the prompt's "must not be longer" rule. The prompt lives in the
/// user's context file after first launch, so a prompt fix never reaches an existing install —
/// this guard is what actually stops a 35 % longer rewrite from being read aloud.
@Suite("Read Aloud — rewrite length guard")
struct ReadAloudRewriteLengthGuardTests {

  private func text(_ n: Int) -> String { String(repeating: "a", count: n) }

  @Test("Rewrite length budget", arguments: [
    (632, 469, false, "more than 30 % longer than a guarded input is rejected"),
    (300, 469, true, "shorter rewrite passes"),
    (600, 469, true, "modestly longer rewrite passes"),
    (150, 40, true, "short inputs are exempt, a terse fragment may grow"),
    (AppConstants.readAloudRewriteGrowthGuardMinChars * 2, AppConstants.readAloudRewriteGrowthGuardMinChars - 1, true,
     "just below the configured minimum length is exempt"),
    (AppConstants.readAloudRewriteGrowthGuardMinChars * 2, AppConstants.readAloudRewriteGrowthGuardMinChars, false,
     "guard starts exactly at the configured minimum length"),
  ])
  func lengthBudget(rewrite: Int, input: Int, passes: Bool, label: String) {
    #expect(SpeechService.rewriteStaysWithinLengthBudget(text(rewrite), for: text(input)) == passes, "\(label)")
  }
}

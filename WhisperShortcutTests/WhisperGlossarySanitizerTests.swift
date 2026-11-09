import Testing
@testable import WhisperShortcut_AppStore

/// Regression cover for the 2026-09-02 finding: the Whisper Glossary, passed to `promptTokens`
/// verbatim, could destroy an offline dictation. Whisper's prompt is example text that the decoder
/// continues, not a rule list — so `Claude (not "Cloud")` taught it to emit parenthesised, quoted
/// fragments, and one 64 s recording came back as 51 characters.
///
/// The decode itself needs a 1.6 GB model and lives in `OfflineWhisperBenchmarkTests`; what is
/// worth guarding on every run is the rewrite, which is pure.
@Suite("Whisper glossary sanitising")
struct WhisperGlossarySanitizerTests {

  /// The exact glossary that produced the reported failure.
  private static let reported = """
    Terms: App, BNI, Claude (not "Cloud"), Cursor, Cursor Grok 4.6 (not "Cursor Grog 4.6"), DKB, \
    Event, Events, Google, Grok Bot (not "Grogbot"), Heidelberg, Magnus Gödde (not "Magnus Göde"), \
    Pia, Sabaki Dance, Website, WhatsApp, WhisperShortcut
    """

  @Test("The reported glossary loses its instruction syntax and keeps every term")
  func sanitisesReportedGlossary() {
    let result = LocalSpeechService.sanitizeGlossaryForWhisper(Self.reported)

    // The three characters the decoder was copying.
    #expect(!result.contains("("))
    #expect(!result.contains(")"))
    #expect(!result.contains("\""))
    #expect(!result.lowercased().hasPrefix("terms:"))

    // The terms are the entire point of a glossary — none may be dropped.
    for term in [
      "App", "BNI", "Claude", "Cursor", "Cursor Grok 4.6", "DKB", "Event", "Events", "Google",
      "Grok Bot", "Heidelberg", "Magnus Gödde", "Pia", "Sabaki Dance", "Website", "WhatsApp",
      "WhisperShortcut",
    ] {
      #expect(result.contains(term), "sanitising dropped \(term)")
    }
    // The "not" spellings are corrections for a reader, and exactly what must not be suggested to
    // the decoder as text to produce.
    #expect(!result.contains("Cloud"))
    #expect(!result.contains("Grogbot"))
  }

  private struct GlossaryCase: Sendable {
    let input: String
    let expected: String
    let label: String
  }

  @Test(
    "Asides, stray entries, separators and empty input are sanitised to a clean one-line glossary",
    arguments: [
      // Stripping an entry's aside does not leave empty separators (", ,") or a trailing comma behind.
      GlossaryCase(
        input: "Alpha (not \"Alfa\"), Beta, (stray), Gamma", expected: "Alpha, Beta, Gamma",
        label: "no dangling separators"),
      GlossaryCase(
        input: "Heidelberg, Ramipril, Sonographie", expected: "Heidelberg, Ramipril, Sonographie",
        label: "plain glossary untouched"),
      GlossaryCase(
        input: "Alpha\nBeta (not \"Bravo\")\nGamma", expected: "Alpha, Beta, Gamma",
        label: "newline-separated normalised to one line"),
      // A glossary that is nothing but asides must produce no prompt at all rather than an empty
      // string that still gets encoded and conditioned on.
      GlossaryCase(input: "(only an aside)", expected: "", label: "only an aside"),
      GlossaryCase(input: "Terms:", expected: "", label: "only the Terms: label"),
      GlossaryCase(input: "   ", expected: "", label: "whitespace only"),
    ])
  private func sanitises(_ c: GlossaryCase) {
    #expect(LocalSpeechService.sanitizeGlossaryForWhisper(c.input) == c.expected, "\(c.label)")
  }
}

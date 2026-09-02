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

  @Test("Stripping an entry's aside does not leave empty separators behind")
  func noDanglingSeparators() {
    let result = LocalSpeechService.sanitizeGlossaryForWhisper(
      "Alpha (not \"Alfa\"), Beta, (stray), Gamma")
    #expect(result == "Alpha, Beta, Gamma")
    #expect(!result.contains(", ,"))
    #expect(!result.hasSuffix(","))
  }

  @Test("A glossary with nothing to strip is passed through unchanged")
  func plainGlossaryUntouched() {
    #expect(
      LocalSpeechService.sanitizeGlossaryForWhisper("Heidelberg, Ramipril, Sonographie")
        == "Heidelberg, Ramipril, Sonographie")
  }

  @Test("Newline-separated glossaries are normalised to one line")
  func newlineSeparated() {
    #expect(
      LocalSpeechService.sanitizeGlossaryForWhisper("Alpha\nBeta (not \"Bravo\")\nGamma")
        == "Alpha, Beta, Gamma")
  }

  /// A glossary that is nothing but asides must produce no prompt at all rather than an empty
  /// string that still gets encoded and conditioned on.
  @Test("A glossary that sanitises to nothing yields an empty result")
  func emptiesToNothing() {
    #expect(LocalSpeechService.sanitizeGlossaryForWhisper("(only an aside)").isEmpty)
    #expect(LocalSpeechService.sanitizeGlossaryForWhisper("Terms:").isEmpty)
    #expect(LocalSpeechService.sanitizeGlossaryForWhisper("   ").isEmpty)
  }
}

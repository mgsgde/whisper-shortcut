import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Covers the deterministic backstop behind the Whisper Glossary's `Term (not "Wrong")` pairs.
///
/// Every case here is drawn from one user's real dictation corpus, where "Claude CLI" came back
/// as "Cloud CLI" in four consecutive dictations while "Google Cloud" and "Sovereign Cloud" were
/// simultaneously correct and frequent. The correction has to fix the first without touching the
/// second, and it fails silently in both directions: too timid and the misheard word survives,
/// too eager and it rewrites a company's product name.
@Suite("Rejected-spelling correction")
struct RejectedSpellingCorrectionTests {

  private func corrected(_ text: String) -> String {
    SpeechService.replacingRejectedSpelling("Cloud CLI", with: "Claude CLI", in: text)
  }

  @Test("A rejected spelling after a lowercase word is corrected")
  func correctsAfterLowercaseWord() {
    #expect(corrected("Wie kann man am besten hier die Cloud CLI verwenden?")
      == "Wie kann man am besten hier die Claude CLI verwenden?")
  }

  @Test("A rejected spelling at the start of the text is corrected")
  func correctsAtStart() {
    #expect(corrected("Cloud CLI ist installiert.") == "Claude CLI ist installiert.")
  }

  @Test("A rejected spelling right after punctuation is corrected")
  func correctsAfterPunctuation() {
    #expect(corrected("Erstens, Cloud CLI einrichten.") == "Erstens, Claude CLI einrichten.")
  }

  @Test("A capitalised predecessor protects a legitimate compound")
  func keepsGoogleCloudCLI() {
    let text = "Ich nutze die Google Cloud CLI dafür."
    #expect(corrected(text) == text)
  }

  @Test("Several occurrences in one sentence are each judged on their own")
  func correctsPerOccurrence() {
    // The user's own contrast dictation, which the model collapsed into one spelling.
    #expect(corrected("Cloud CLI, nicht Cloud CLI.") == "Claude CLI, nicht Claude CLI.")
    // Mixed: the bare one is corrected, the Google-qualified one is not.
    #expect(corrected("Cloud CLI und Google Cloud CLI sind verschieden.")
      == "Claude CLI und Google Cloud CLI sind verschieden.")
  }

  @Test("Word boundaries are respected")
  func respectsWordBoundaries() {
    let text = "Das Wort Cloud CLIs steht hier."
    #expect(corrected(text) == text)
  }

  @Test("A bare rejected word is never rewritten by a multi-word pair")
  func leavesBareCloudAlone() {
    let text = "Meine Google Cloud Kosten und die Cloud allgemein."
    #expect(corrected(text) == text)
  }

  @Test("Text without the rejected spelling is returned untouched")
  func noopWithoutMatch() {
    let text = "Kann ich bei Claude CLI in den Dangerous Mode switchen?"
    #expect(corrected(text) == text)
  }

  @Test("Umlauts in the preceding word are read as letters, not boundaries")
  func handlesUmlautPredecessor() {
    // "Über" is capitalised → protected; "über" is not → corrected. The scan must treat "Ü"/"ü"
    // as part of the word, or it would stop at the umlaut and misread the first letter.
    #expect(corrected("Über Cloud CLI reden.") == "Über Cloud CLI reden.")
    #expect(corrected("Reden wir über Cloud CLI.") == "Reden wir über Claude CLI.")
  }
}

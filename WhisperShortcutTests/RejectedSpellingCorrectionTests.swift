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

/// A one-word rejected spelling is a legitimate noun on its own ("Läufer", "Daten"). It is
/// rewritten only when a personal title stands immediately before it, which is what makes the
/// token a name.
@Suite("Rejected one-word name after a title")
struct RejectedNameAfterTitleTests {

  private func corrected(_ text: String) -> String {
    SpeechService.replacingRejectedNameAfterTitle("Läufer", with: "Läuffer", in: text)
  }

  @Test("Frau Dr. before the misheard name is corrected, title included")
  func correctsAfterFrauDr() {
    #expect(corrected("Ich wundere mich, die Frau Dr. Läufer.")
      == "Ich wundere mich, die Frau Dr. Läuffer.")
  }

  @Test("Frau alone before the name is corrected")
  func correctsAfterFrau() {
    #expect(corrected("Frau Läufer hat geschrieben.") == "Frau Läuffer hat geschrieben.")
  }

  @Test("Herrn before the name is corrected")
  func correctsAfterHerrn() {
    #expect(corrected("Grüße an Herrn Läufer") == "Grüße an Herrn Läuffer")
  }

  @Test("Each titled occurrence in one sentence is corrected")
  func correctsEachTitledOccurrence() {
    #expect(corrected("Prof. Läufer, Dr. Läufer") == "Prof. Läuffer, Dr. Läuffer")
  }

  @Test("A bare noun with no title is left alone")
  func leavesBareNounAlone() {
    let text = "Der Läufer kam ins Ziel."
    #expect(corrected(text) == text)
  }

  @Test("A name with no title stays, even when repeated")
  func leavesUntitledNameAlone() {
    let text = "Läufer, Läufer immer falsch"
    #expect(corrected(text) == text)
  }

  @Test("A longer word that merely starts with the rejected spelling is left alone")
  func leavesLongerWordsAlone() {
    #expect(corrected("Frau Läuferin") == "Frau Läuferin")
    #expect(corrected("Frau Marathonläufer") == "Frau Marathonläufer")
  }

  @Test("The title has to be the whole word")
  func titleMustBeWholeWord() {
    let text = "die Frauen Läufer"
    #expect(corrected(text) == text)
  }

  @Test("A rejected common noun with no title is left alone")
  func leavesDatenAlone() {
    let text = "Wir speichern die Daten."
    #expect(SpeechService.replacingRejectedNameAfterTitle("Daten", with: "Datev", in: text) == text)
  }
}

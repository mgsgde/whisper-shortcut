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

  @Test("Rejected-spelling correction: fixes bare occurrences, protects legitimate compounds",
        arguments: [
    ("Wie kann man am besten hier die Cloud CLI verwenden?", "Wie kann man am besten hier die Claude CLI verwenden?", "after lowercase word"),
    ("Cloud CLI ist installiert.", "Claude CLI ist installiert.", "at start"),
    ("Erstens, Cloud CLI einrichten.", "Erstens, Claude CLI einrichten.", "after punctuation"),
    ("Ich nutze die Google Cloud CLI dafür.", "Ich nutze die Google Cloud CLI dafür.", "capitalised predecessor protects compound"),
    // The user's own contrast dictation, which the model collapsed into one spelling.
    ("Cloud CLI, nicht Cloud CLI.", "Claude CLI, nicht Claude CLI.", "each occurrence judged on its own"),
    // Mixed: the bare one is corrected, the Google-qualified one is not.
    ("Cloud CLI und Google Cloud CLI sind verschieden.", "Claude CLI und Google Cloud CLI sind verschieden.", "mixed occurrences"),
    ("Das Wort Cloud CLIs steht hier.", "Das Wort Cloud CLIs steht hier.", "word boundaries respected"),
    ("Meine Google Cloud Kosten und die Cloud allgemein.", "Meine Google Cloud Kosten und die Cloud allgemein.", "bare Cloud never rewritten"),
    ("Kann ich bei Claude CLI in den Dangerous Mode switchen?", "Kann ich bei Claude CLI in den Dangerous Mode switchen?", "no match is untouched"),
    // "Über" is capitalised -> protected; "über" is not -> corrected. The scan must treat "Ü"/"ü" as letters.
    ("Über Cloud CLI reden.", "Über Cloud CLI reden.", "umlaut predecessor, capitalised"),
    ("Reden wir über Cloud CLI.", "Reden wir über Claude CLI.", "umlaut predecessor, lowercase"),
  ])
  func correction(input: String, expected: String, label: String) {
    #expect(corrected(input) == expected, "\(label)")
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

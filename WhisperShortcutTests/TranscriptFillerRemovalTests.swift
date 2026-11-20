import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Fillers ("äh", "ähm", "hmm", …) are stripped on every transcript, not only Dictate Live.
/// A filler at the start or after a sentence end also capitalises the next letter.
@Suite("Transcript filler removal")
struct TranscriptFillerRemovalTests {

  private struct Case: Sendable {
    let input: String
    let expected: String
    let label: String
  }

  @Test(
    "Fillers drop mid-sentence without touching the next word's case",
    arguments: [
      Case(input: "Das ist ähm gut.", expected: "Das ist gut.", label: "ähm"),
      Case(input: "Das ist Äh, gut.", expected: "Das ist gut.", label: "Äh,"),
      Case(input: "Das ist öhm gut.", expected: "Das ist gut.", label: "öhm"),
      Case(input: "Das ist Mm-hmm gut.", expected: "Das ist gut.", label: "Mm-hmm"),
      Case(input: "Das ist mhm gut.", expected: "Das ist gut.", label: "mhm"),
      Case(input: "Das ist hmm gut.", expected: "Das ist gut.", label: "hmm"),
    ])
  private func dropsFillersMidSentence(_ c: Case) {
    #expect(TextProcessingUtility.removingFillers(c.input) == c.expected, "\(c.label)")
  }

  @Test(
    "A filler at the start or after a sentence end is dropped and the next letter is capitalised",
    arguments: [
      Case(input: "ähm das ist gut.", expected: "Das ist gut.", label: "ähm at start"),
      Case(input: "Äh, das ist gut.", expected: "Das ist gut.", label: "Äh, at start"),
      Case(input: "öhm das ist gut.", expected: "Das ist gut.", label: "öhm at start"),
      Case(input: "Mm-hmm das ist gut.", expected: "Das ist gut.", label: "Mm-hmm at start"),
      Case(input: "mhm das ist gut.", expected: "Das ist gut.", label: "mhm at start"),
      Case(input: "hmm das ist gut.", expected: "Das ist gut.", label: "hmm at start"),
      Case(input: "Ähm, ich komme", expected: "Ich komme", label: "Ähm, ich komme"),
      Case(input: "Okay. Ähm, das passt", expected: "Okay. Das passt", label: "after period"),
      Case(input: "Okay! ähm das passt", expected: "Okay! Das passt", label: "after exclamation"),
      Case(input: "Okay? ähm das passt", expected: "Okay? Das passt", label: "after question"),
      Case(input: "Okay.\nähm das passt", expected: "Okay.\n Das passt", label: "after newline"),
    ])
  private func capitalizesAfterALeadingFiller(_ c: Case) {
    #expect(TextProcessingUtility.removingFillers(c.input) == c.expected, "\(c.label)")
  }

  @Test(
    "Real words that only look like fillers stay",
    arguments: [
      Case(input: "Das ist ähnlich.", expected: "Das ist ähnlich.", label: "ähnlich"),
      Case(input: "Um zehn Uhr", expected: "Um zehn Uhr", label: "Um"),
      Case(input: "oh nein", expected: "oh nein", label: "oh"),
      Case(input: "achso, dann", expected: "achso, dann", label: "achso"),
      Case(input: "Herr Ehmann kommt", expected: "Herr Ehmann kommt", label: "Ehmann"),
    ])
  private func keepsRealWords(_ c: Case) {
    #expect(TextProcessingUtility.removingFillers(c.input) == c.expected, "\(c.label)")
  }

  @Test("A filler-only clip comes back empty", arguments: ["ähm", "Äh,", "öhm", "Mm-hmm", "mhm", "hmm", "hmm ähm"])
  func fillerOnlyIsEmpty(_ input: String) {
    #expect(TextProcessingUtility.removingFillers(input) == "")
  }

  @Test("A line break survives filler removal")
  func keepsTheNewline() {
    #expect(TextProcessingUtility.removingFillers("erste Zeile\nzweite ähm Zeile") == "erste Zeile\nzweite Zeile")
  }

  @Test("normalizeTranscriptionText strips a leading filler and capitalises")
  func normalizeStripsLeadingFiller() {
    #expect(TextProcessingUtility.normalizeTranscriptionText("Ähm, das ist gut.") == "Das ist gut.")
    #expect(TextProcessingUtility.normalizeTranscriptionText("ähm") == "")
  }
}

import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Offline transcript finisher")
struct OfflineTranscriptFinisherTests {

  @Test("keepsEdgeBreaks false trims a trailing paragraph break; true keeps it")
  func edgeBreaks() {
    let text = "Befund neuer Absatz"
    let trimmed = OfflineTranscriptFinisher.finish(
      text, mode: .automatic, timedMarks: false, keepsEdgeBreaks: false)
    let kept = OfflineTranscriptFinisher.finish(
      text, mode: .automatic, timedMarks: false, keepsEdgeBreaks: true)
    #expect(trimmed == "Befund")
    #expect(kept == "Befund\n\n")
    #expect(trimmed == SpokenPunctuation.apply(to: text))
    #expect(kept == SpokenPunctuation.apply(to: text, keepsEdgeBreaks: true))
  }

  @Test("A cloud model comes back unchanged")
  func cloudUnchanged() {
    let text = "äh die Haut ist trockenpunkt, Blutdruck 140 zu neunzig"
    #expect(
      OfflineTranscriptFinisher.finish(text, model: .openAIGPTTranscribe, mode: .spokenOnly) == text)
  }

  @Test("Spoken-only finish drops a leading filler and splits a glued Punkt")
  func fillerAndGluedPunkt() {
    #expect(
      OfflineTranscriptFinisher.finish(
        "äh die Haut ist trockenpunkt", mode: .spokenOnly, timedMarks: false, keepsEdgeBreaks: false)
        == "Die Haut ist trocken.")
  }

  @Test("finishPiece matches the pipeline Dictate Live used before the finisher")
  func matchesFormerLivePipeline() {
    #expect(
      LiveDictation.finishPiece("Blutdruck 140 zu neunzig", mode: .spokenOnly, timedMarks: true)
        == "Blutdruck 140 zu 90")
    #expect(
      LiveDictation.finishPiece("Einzel GdB Psyche zwanzig.", mode: .automatic, timedMarks: true)
        == "Einzel-GdB Psyche 20.")
    #expect(LiveDictation.finishPiece("Basistherapie ähm Punkt", mode: .spokenOnly) == "Basistherapie.")
    #expect(LiveDictation.finishPiece("Hmm, was ist das", mode: .automatic) == "Was ist das")
    #expect(
      LiveDictation.finishPiece("Ramipril zwei Komma fünf mg", mode: .spokenOnly, timedMarks: true)
        == "Ramipril 2,5 mg")
    #expect(LiveDictation.finishPiece("Befund neuer Absatz", mode: .automatic) == "Befund\n\n")
  }
}

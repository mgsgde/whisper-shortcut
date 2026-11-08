//
//  Qwen3TTSSplitTests.swift
//  WhisperShortcutTests
//
//  The splitter decides what one model call sees. It is one sentence per call — that is what
//  keeps the voice stable (the first sentence becomes the speaker reference for the rest) and
//  what makes the first audio arrive early. A bad cut is audible or expensive, so the rules are
//  pinned here rather than only exercised through a 3 GB model.
//

import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Qwen3 TTS sentence splitting")
struct Qwen3TTSSplitTests {

  @Test("One sentence per entry")
  func oneSentencePerEntry() {
    let text = "Guten Tag. Dies ist ein kurzer Satz. Und noch einer!"
    let sentences = Qwen3TTSService.splitIntoSentences(text, maxChars: 400)
    #expect(sentences == ["Guten Tag.", "Dies ist ein kurzer Satz.", "Und noch einer!"])
  }

  @Test("A single sentence stays one entry")
  func singleSentenceStaysWhole() {
    let text = "Dies ist ein einzelner Satz ohne weitere Unterbrechung."
    #expect(Qwen3TTSService.splitIntoSentences(text, maxChars: 400) == [text])
  }

  @Test("Empty and whitespace-only text produce no entries")
  func emptyTextProducesNothing() {
    #expect(Qwen3TTSService.splitIntoSentences("", maxChars: 400).isEmpty)
    #expect(Qwen3TTSService.splitIntoSentences("   \n\t ", maxChars: 400).isEmpty)
  }

  @Test("Sentences are not merged, however short they are")
  func shortSentencesAreNotMerged() {
    // The old chunker packed sentences up to a character cap. That is exactly what made the
    // voice drift: one call covered several sentences, and the next call started a new speaker.
    let text = "Ja. Nein. Vielleicht. Doch."
    #expect(Qwen3TTSService.splitIntoSentences(text, maxChars: 400).count == 4)
  }

  @Test("A sentence longer than the cap is cut at a word boundary")
  func longSentenceSplitsAtWords() {
    let text = String(repeating: "wort ", count: 200) + "."
    let sentences = Qwen3TTSService.splitIntoSentences(text, maxChars: 100)

    #expect(sentences.count > 1)
    for sentence in sentences {
      #expect(sentence.count <= 100, "entry over the cap: \(sentence.count)")
      #expect(!sentence.hasPrefix(" "))
    }
  }

  @Test("A decimal point does not split a sentence")
  func decimalPointDoesNotSplit() {
    let text = "Der Wert liegt bei 3.5 Prozent und das ist korrekt."
    #expect(Qwen3TTSService.splitIntoSentences(text, maxChars: 400) == [text])
  }

  @Test("No text is lost across the split")
  func noTextIsLost() {
    let text = "Erster Satz. Zweiter Satz! Dritter Satz? Vierter Satz."
    let sentences = Qwen3TTSService.splitIntoSentences(text, maxChars: 400)
    #expect(sentences.joined(separator: " ") == text)
  }

  // MARK: - Silence trimming
  // The checkpoint pads chunks it cannot vocalize (headers, bylines, bare domains) with long
  // silent lead-ins. `trimmingSilence` is what keeps those out of playback.

  @Test("Leading and trailing silence is dropped, speech is kept")
  func trimsLeadingAndTrailingSilence() {
    // 1 s of silence, 0.5 s of speech, 2 s of silence at 24 kHz.
    let rate = 24_000
    let silence = [Float](repeating: 0.001, count: rate)
    let speech = [Float](repeating: 0.5, count: rate / 2)
    let trimmed = Qwen3TTSService.trimmingSilence(silence + speech + silence + silence, sampleRate: rate)
    // The speech body survives; only the padding and the 5 ms fades are gone.
    #expect(trimmed.count > rate / 2 - 2 * rate / 200)
    #expect(trimmed.count < rate / 2 + 2 * rate / 200 + rate / 100)
    // No padding is left at the front: the fade-in is complete within ~5 ms, so the sample
    // just past the fade is already at speech level.
    #expect(abs(trimmed[rate / 200]) > 0.1)
  }

  @Test("A fully silent chunk comes back empty")
  func fullySilentChunkComesBackEmpty() {
    let silence = [Float](repeating: 0.001, count: 24_000 * 5)
    #expect(Qwen3TTSService.trimmingSilence(silence, sampleRate: 24_000).isEmpty)
  }

  @Test("A chunk that is speech from the first sample is returned unchanged")
  func speechOnlyChunkIsUnchanged() {
    let speech = [Float](repeating: 0.4, count: 4_800)
    let trimmed = Qwen3TTSService.trimmingSilence(speech, sampleRate: 24_000)
    // Only the two 5 ms fades differ from the input.
    #expect(trimmed.count == speech.count)
    #expect(trimmed[trimmed.count / 2] == speech[speech.count / 2])
  }
}

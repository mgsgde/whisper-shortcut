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

  private static let rate = 24_000

  @Test("Long leading silence is trimmed down to the 40 ms lead margin")
  func trimsLeadingSilenceToMargin() {
    let rate = Self.rate
    let silence = [Float](repeating: 0.001, count: rate * 3)
    let speech = [Float](repeating: 0.5, count: rate / 2)
    let trimmed = Qwen3TTSService.trimmingSilence(silence + speech, sampleRate: rate)
    // 40 ms margin + speech; no tail cut because the buffer ends with speech.
    #expect(trimmed.count == rate * 40 / 1000 + speech.count)
    // Fade-in sits inside the margin, speech is at full level after it.
    #expect(abs(trimmed[rate * 40 / 1000 + 10]) > 0.4)
  }

  @Test("Trailing silence is capped at 200 ms, not removed")
  func capsTrailingSilence() {
    let rate = Self.rate
    let speech = [Float](repeating: 0.5, count: rate / 2)
    let silence = [Float](repeating: 0.001, count: rate * 2)
    let trimmed = Qwen3TTSService.trimmingSilence(speech + silence, sampleRate: rate)
    #expect(trimmed.count == speech.count + rate * 200 / 1000)
    // Shorter tails are left untouched.
    let short = [Float](repeating: 0.001, count: rate / 10)
    #expect(Qwen3TTSService.trimmingSilence(speech + short, sampleRate: rate).count == speech.count + short.count)
  }

  @Test("A quiet onset ramp before loud speech is not cut into")
  func softOnsetIsKept() {
    let rate = Self.rate
    // 100 ms linear ramp 0 -> 0.1 (crosses the RMS threshold part-way), then loud speech.
    let ramp = (0..<(rate / 10)).map { Float($0) / Float(rate / 10) * 0.1 }
    let speech = [Float](repeating: 0.5, count: rate / 2)
    let pad = [Float](repeating: 0.001, count: rate * 2)
    let trimmed = Qwen3TTSService.trimmingSilence(pad + ramp + speech, sampleRate: rate)
    // Everything from the ramp's first loud-enough window on survives, plus the lead margin.
    #expect(trimmed.count >= ramp.count / 2 + speech.count)
    #expect(trimmed.suffix(speech.count).allSatisfy { $0 == 0.5 })
    // The last ramp samples (0.1 level, soft onset) are intact.
    let rampTailStart = trimmed.count - speech.count - 100
    #expect(abs(trimmed[rampTailStart] - ramp[ramp.count - 100]) < 1e-6)
  }

  @Test("A click inside a long silent pad does not defeat the trim")
  func clickInPadDoesNotCountAsSpeech() {
    let rate = Self.rate
    var pad = [Float](repeating: 0.001, count: rate * 3)
    pad[rate] = 0.15
    pad[rate + 1] = -0.15  // 2 samples: 10 ms RMS ~0.016 < 0.02, yet far above a per-sample threshold
    let speech = [Float](repeating: 0.5, count: rate / 2)
    let trimmed = Qwen3TTSService.trimmingSilence(pad + speech, sampleRate: rate)
    #expect(trimmed.count == rate * 40 / 1000 + speech.count)
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

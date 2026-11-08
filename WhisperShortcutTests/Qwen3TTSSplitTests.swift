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
}

//
//  Qwen3TTSSplitTests.swift
//  WhisperShortcutTests
//
//  The chunker decides how a long article is cut before it reaches the model. A bad cut is
//  audible (a sentence split mid-clause) or expensive (a chunk far over the cap), so the rules
//  are pinned here rather than only exercised through a 3 GB model.
//

import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Qwen3 TTS text splitting")
struct Qwen3TTSSplitTests {

  @Test("Short text stays one chunk")
  func shortTextIsOneChunk() {
    let text = "Guten Tag. Dies ist ein kurzer Satz."
    #expect(Qwen3TTSService.split(text, maxChars: 400) == [text])
  }

  @Test("Empty and whitespace-only text produce no chunks")
  func emptyTextProducesNoChunks() {
    #expect(Qwen3TTSService.split("", maxChars: 400).isEmpty)
    #expect(Qwen3TTSService.split("   \n\t ", maxChars: 400).isEmpty)
  }

  @Test("Long text splits at sentence boundaries and loses nothing")
  func longTextSplitsAtSentences() {
    let sentence = "Dies ist ein Satz mit ausreichend Laenge fuer den Test. "
    let text = String(repeating: sentence, count: 30)
    let chunks = Qwen3TTSService.split(text, maxChars: 400)

    #expect(chunks.count > 1)
    for chunk in chunks {
      #expect(chunk.count <= 400, "chunk over the cap: \(chunk.count)")
      // A chunk must not start or end mid-word.
      #expect(!chunk.hasPrefix(" "))
      #expect(!chunk.hasSuffix(" "))
    }
    // Every sentence survives exactly once.
    let rejoined = chunks.joined(separator: " ")
    #expect(rejoined.components(separatedBy: "Test.").count == text.components(separatedBy: "Test.").count)
  }

  @Test("A single sentence longer than the cap is cut at a word boundary")
  func longSentenceSplitsAtWords() {
    let text = String(repeating: "wort ", count: 200)
    let chunks = Qwen3TTSService.split(text, maxChars: 100)

    #expect(chunks.count > 1)
    for chunk in chunks {
      #expect(chunk.count <= 100, "chunk over the cap: \(chunk.count)")
      #expect(!chunk.hasPrefix(" "))
    }
  }

  @Test("A decimal point does not split a sentence")
  func decimalPointDoesNotSplit() {
    let text = "Der Wert liegt bei 3.5 Prozent und das ist korrekt."
    #expect(Qwen3TTSService.split(text, maxChars: 400) == [text])
  }
}

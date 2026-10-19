import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Locks the property of the TTS chunker that decides how long Read Aloud stays silent: the
/// first chunk — the only one playback waits for — is short (120 chars), and later caps ramp
/// geometrically (120 → 180 → 270 → 405 → 500) so each chunk's audio covers the next one's
/// synthesis. Measured without the ramp: a 94-char opener (7 s of audio) could not cover a
/// 436-char follower (18 s to synthesize), leaving ~8 s of silence at 1.5× (2026-09-17 09:21);
/// a one-sentence opener is still on the speakers in ~4 s.
@Suite("TTS chunker — first chunk")
struct TextChunkerFirstChunkTests {

  private let sentence = "Die Nordsee ist ein Randmeer des Atlantischen Ozeans. "  // 55 chars

  private func prose(sentences: Int) -> String {
    String(repeating: sentence, count: sentences).trimmingCharacters(in: .whitespaces)
  }

  @Test("A whitespace-only span between sentences leaves no gap in chunk indices")
  func skippedWhitespaceChunkKeepsIndicesContiguous() throws {
    let text = prose(sentences: 3) + String(repeating: "\n ", count: 200) + prose(sentences: 3)
    let chunks = try TextChunker(chunkSize: 500, firstChunkSize: 120).splitText(text)
    #expect(chunks.count > 1)
    #expect(chunks.map(\.index) == Array(0..<chunks.count))
  }

  @Test("Text under the first-chunk cap stays a single chunk")
  func shortTextIsSingleChunk() throws {
    let chunks = try TextChunker(chunkSize: 500, firstChunkSize: 120).splitText(prose(sentences: 2))
    #expect(chunks.count == 1)
  }

  @Test("Text over the first-chunk cap but under the chunk size is split so playback can start early")
  func mediumTextGetsShortOpener() throws {
    let text = prose(sentences: 5)  // ~275 chars: one chunk under the old 500-only rule
    let chunks = try TextChunker(chunkSize: 500, firstChunkSize: 120).splitText(text)
    #expect(chunks.count == 2)
    #expect(chunks[0].text.count <= 120)
    #expect(chunks[0].text.hasSuffix("."), "opener ends on a sentence boundary")
    #expect(chunks.map(\.text).joined(separator: " ") == text)
  }

  @Test("Later chunks ramp geometrically until they hit the full chunk size")
  func laterChunksFollowGeometricRamp() throws {
    let chunker = TextChunker(chunkSize: 500, firstChunkSize: 120, growthFactor: 1.5)
    let expectedCaps = [120, 180, 270, 405, 500, 500]
    for k in 0...5 {
      #expect(chunker.chunkCap(forIndex: k) == expectedCaps[k])
    }
    let text = prose(sentences: 40)  // ~2200 chars
    let chunks = try chunker.splitText(text)
    for (k, chunk) in chunks.enumerated() {
      #expect(chunk.text.count <= chunker.chunkCap(forIndex: k))
    }
    #expect(chunks.contains { $0.text.count > 405 }, "the ramp must actually reach the full cap")
  }

  @Test("Gemini's 260-char ceiling stops the ramp at 260 (120 → 180 → 260 → 260 …)")
  func geminiCeilingCapsRamp() throws {
    let chunker = TextChunker(chunkSize: AppConstants.ttsGeminiChunkSizeChars, firstChunkSize: 120, growthFactor: 1.5)
    #expect(AppConstants.ttsGeminiChunkSizeChars == 260)
    let expectedCaps = [120, 180, 260, 260, 260]
    for k in 0...4 {
      #expect(chunker.chunkCap(forIndex: k) == expectedCaps[k])
    }
    let chunks = try chunker.splitText(prose(sentences: 40))  // ~2200 chars
    for (k, chunk) in chunks.enumerated() {
      #expect(chunk.text.count <= chunker.chunkCap(forIndex: k))
    }
    #expect(chunks.allSatisfy { $0.text.count <= 260 })
    #expect(chunks.contains { $0.text.count > 180 }, "the ramp must actually reach the ceiling")
  }

  @Test("growth factor 1.0 disables the ramp: every cap equals firstChunkSize")
  func growthFactorOneDisablesRamp() {
    #expect(TextChunker(chunkSize: 500, firstChunkSize: 120, growthFactor: 1.0).chunkCap(forIndex: 3) == 120)
  }

  @Test("A first-chunk cap larger than the chunk size is clamped")
  func firstChunkCapIsClamped() {
    #expect(TextChunker(chunkSize: 100, firstChunkSize: 500).firstChunkSize == 100)
  }

  @Test("Shipped defaults: opener is a sentence or two, later chunks are 500")
  func shippedDefaults() throws {
    let chunks = try TextChunker().splitText(prose(sentences: 30))
    #expect(chunks[0].text.count <= AppConstants.ttsFirstChunkSizeChars)
    #expect(chunks[1].text.count > AppConstants.ttsFirstChunkSizeChars)
    #expect(chunks[1].text.count <= AppConstants.ttsChunkSizeChars)
  }

  @Test("German read-aloud sample pauses at the sentence and the clause, not after drehen")
  func germanSamplePausesOnAClause() throws {
    let text = "Umgang mit gesundheitlichen Problemen: Viele Menschen – auch sehr erfolgreiche – haben gesundheitliche Einschränkungen. Eine starke Haltung zeichnet sich nicht durch die Abwesenheit von Problemen aus, sondern durch den Umgang damit: Statt in Selbstmitleid zu verfallen und sich nur um sich selbst zu drehen, den Fokus nach außen auf das Leben und aktives Handeln richten und das Beste daraus machen. Die Entscheidung liegt bei mir."
    let chunker = TextChunker(chunkSize: 260, firstChunkSize: 120, growthFactor: 1.5)
    let chunks = try chunker.splitText(text)
    #expect(chunks.count >= 2)
    #expect(chunks[0].text.hasSuffix("Einschränkungen."))
    #expect(chunks[1].text.hasSuffix("damit:"))
    #expect(chunks.allSatisfy { !$0.text.hasSuffix("drehen,") })
    #expect(chunks.allSatisfy { $0.text.count <= 260 })
    #expect(chunks.map(\.text).joined(separator: " ") == text)
  }

  @Test("A sentence that ends just past the cap is finished via overshoot")
  func overshootFinishesTheOpenSentence() throws {
    let opener = String(repeating: "a", count: 149) + "."
    #expect(opener.count == 150)
    // The next sentence also ends inside the overshoot window (120, 180], so the
    // opener is kept only when the first sentence end in that window wins.
    let text = opener + " Kurz und klar. " + prose(sentences: 3)
    let chunks = try TextChunker(chunkSize: 500, firstChunkSize: 120).splitText(text)
    #expect(chunks[0].text == opener)
    #expect(chunks.map(\.text).joined(separator: " ") == text)
  }

  @Test("Abbreviations and ordinal numbers are not chunk ends")
  func abbreviationsAreNotChunkEnds() throws {
    let text = (String(repeating: "alpha ", count: 12)
      + "am 3. Oktober "
      + String(repeating: "beta ", count: 12)
      + "z. B. "
      + String(repeating: "gamma ", count: 30))
      .trimmingCharacters(in: .whitespaces)
    let chunks = try TextChunker(chunkSize: 200, firstChunkSize: 200).splitText(text)
    #expect(text.count > 200)
    #expect(chunks[0].text.contains("am 3. Oktober"))
    #expect(chunks[0].text.contains("z. B."))
    for chunk in chunks {
      #expect(!chunk.text.hasSuffix("z."))
      #expect(!chunk.text.hasSuffix("B."))
      #expect(!chunk.text.hasSuffix("3."))
      #expect(!chunk.text.hasSuffix("z. B."))
    }
    #expect(chunks.map(\.text).joined(separator: " ") == text)
  }

  @Test("A long sentence with only commas splits on the last comma inside the cap")
  func commaFallbackWhenNoOtherPause() throws {
    let unit = "wort wort wort wort, " // 21 characters, ends on comma + space
    let text = String(repeating: unit, count: 14) + "aaaaaa" // 300 characters
    #expect(text.count == 300)
    #expect(!text.contains("."))
    let chunks = try TextChunker(chunkSize: 200, firstChunkSize: 200).splitText(text)
    #expect(chunks[0].text.hasSuffix(","))
    #expect(chunks[0].text.count <= 200)
    #expect(chunks.map(\.text).joined(separator: " ") == text)
  }
}

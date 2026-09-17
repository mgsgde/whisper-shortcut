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
}

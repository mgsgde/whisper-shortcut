import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Locks the one property of the TTS chunker that decides how long Read Aloud stays silent: the
/// first chunk — the only one playback waits for — is short, while the rest keep the full size.
/// Measured before this existed: a 383-char opener took 16 s to synthesize (30 s of audio);
/// a one-sentence opener is on the speakers in ~4 s.
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
    let text = prose(sentences: 6)  // ~330 chars: one chunk under the old rule
    let chunks = try TextChunker(chunkSize: 500, firstChunkSize: 120).splitText(text)
    #expect(chunks.count == 2)
    #expect(chunks[0].text.count <= 120)
    #expect(chunks[0].text.hasSuffix("."), "opener ends on a sentence boundary")
    #expect(chunks.map(\.text).joined(separator: " ") == text)
  }

  @Test("Only the first chunk is capped low; the rest use the full chunk size")
  func laterChunksUseFullSize() throws {
    let text = prose(sentences: 30)  // ~1650 chars
    let chunks = try TextChunker(chunkSize: 500, firstChunkSize: 120).splitText(text)
    #expect(chunks[0].text.count <= 120)
    #expect(chunks[0].text.count >= Int(120 * AppConstants.ttsFirstChunkMinSizeRatio))
    let rest = chunks.dropFirst().dropLast()
    #expect(!rest.isEmpty)
    for chunk in rest {
      #expect(chunk.text.count > 120, "a later chunk (\(chunk.text.count) chars) should not be capped like the opener")
      #expect(chunk.text.count <= 500)
    }
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
  }
}

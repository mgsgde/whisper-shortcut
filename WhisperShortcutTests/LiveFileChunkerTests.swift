import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// `LiveFileChunker` cuts a file where Dictate Live would rotate: 0.2 s RMS windows, a pause of
/// at least 0.6 s, and only once the current piece is already 1.5 s long.
@Suite("Live file chunker")
struct LiveFileChunkerTests {
  private let rate: Double = 16_000

  @Test("Tone, a long pause, then tone is two pieces, cut 0.6 s into the pause")
  func toneSilenceTone() {
    let samples = tone(2) + silence(1) + tone(2)
    let chunks = LiveFileChunker.chunks(samples: samples, sampleRate: rate, policy: .live)
    #expect(chunks.count == 2)
    // 2.0 s of tone, then the first 0.6 s of the pause. The rest of the pause stays with the tail.
    let cut = Int(2.6 * rate)
    #expect(chunks[0].range == 0..<cut)
    #expect(chunks[1].range == cut..<samples.count)
    #expect(!chunks[0].isSilent)
    #expect(!chunks[1].isSilent)
  }

  @Test("Continuous tone is one piece")
  func continuousTone() {
    let samples = tone(3)
    let chunks = LiveFileChunker.chunks(samples: samples, sampleRate: rate, policy: .live)
    #expect(chunks.count == 1)
    #expect(chunks[0].range == 0..<samples.count)
    #expect(!chunks[0].isSilent)
  }

  @Test("A pause shorter than 0.6 s does not cut")
  func shortPause() {
    let samples = tone(2) + silence(0.4) + tone(2)
    let chunks = LiveFileChunker.chunks(samples: samples, sampleRate: rate, policy: .live)
    #expect(chunks.count == 1)
    #expect(chunks[0].range == 0..<samples.count)
  }

  @Test("A pause that ends before the piece is 1.5 s long does not cut")
  func chunkUnderMinimum() {
    let samples = tone(0.4) + silence(1) + tone(2)
    let chunks = LiveFileChunker.chunks(samples: samples, sampleRate: rate, policy: .live)
    #expect(chunks.count == 1)
    #expect(chunks[0].range == 0..<samples.count)
  }

  @Test("A file that never rises above the threshold is one silent piece")
  func entirelySilent() {
    let samples = silence(1)
    let chunks = LiveFileChunker.chunks(samples: samples, sampleRate: rate, policy: .live)
    #expect(chunks.count == 1)
    #expect(chunks[0].isSilent)
    #expect(chunks[0].range == 0..<samples.count)
  }

  @Test("Silence before 1.5 s is not counted toward the 0.6 s run")
  func silenceBeforeMinimumIsIgnored() {
    // The pause starts at 1.2 s. Counting begins at the first window that ends at or after 1.5 s
    // (1.6 s) and needs three windows, so the cut is at 2.0 s, not at 1.2 + 0.6.
    let samples = tone(1.2) + silence(1) + tone(2)
    let chunks = LiveFileChunker.chunks(samples: samples, sampleRate: rate, policy: .live)
    #expect(chunks.count == 2)
    let cut = Int(2.0 * rate)
    #expect(chunks[0].range == 0..<cut)
    #expect(chunks[1].range == cut..<samples.count)
  }

  private func tone(_ seconds: Double, amplitude: Float = 0.5) -> [Float] {
    let count = Int(seconds * rate)
    return (0..<count).map { index in
      amplitude * Float(sin(2 * Double.pi * 440 * Double(index) / rate))
    }
  }

  private func silence(_ seconds: Double) -> [Float] {
    Array(repeating: 0, count: Int(seconds * rate))
  }
}

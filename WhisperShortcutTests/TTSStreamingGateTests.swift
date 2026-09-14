import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The two pieces that let OpenAI's streamed PCM reach the speakers early without breaking the
/// one rule playback depends on: audio is handed over in order, once, never mid-sample.
@Suite("TTS streaming — batcher and playback-order gate")
struct TTSStreamingGateTests {

  // MARK: Batcher

  @Test("First slice flushes at the short threshold, later ones at the regular one")
  func batcherThresholds() {
    var batcher = PCMStreamBatcher(firstFlushSeconds: 0.25, flushSeconds: 0.5)
    var slices: [Int] = []
    for _ in 0..<(48_000) {  // one second of audio, byte by byte
      if let slice = batcher.append(0) { slices.append(slice.count) }
    }
    if let rest = batcher.drain() { slices.append(rest.count) }
    #expect(slices == [12_000, 24_000, 12_000])
  }

  @Test("Slices never split a 16-bit sample")
  func batcherSampleBoundary() {
    var batcher = PCMStreamBatcher(firstFlushSeconds: 0.0001, flushSeconds: 0.0001)  // 4-byte thresholds
    var slices: [Data] = []
    for _ in 0..<11 {  // odd byte count → last byte is half a sample
      if let slice = batcher.append(7) { slices.append(slice) }
    }
    if let rest = batcher.drain() { slices.append(rest) }
    for slice in slices { #expect(slice.count.isMultiple(of: 2)) }
    #expect(slices.reduce(0) { $0 + $1.count } == 10)
  }

  @Test("Drain returns nil when nothing is pending")
  func batcherDrainEmpty() {
    var batcher = PCMStreamBatcher()
    #expect(batcher.drain() == nil)
  }

  // MARK: Gate

  /// Records emissions as `(index, bytes-as-string)` so order and content are both checked.
  private final class Sink: @unchecked Sendable {
    var emitted: [(Int, String)] = []
    func handler(_ data: Data, _ index: Int, _ total: Int) {
      emitted.append((index, String(decoding: data, as: UTF8.self)))
    }
  }

  private func data(_ s: String) -> Data { Data(s.utf8) }

  @Test("Partials of the chunk at the gate pass straight through; completion emits only the rest")
  func liveChunkStreamsOnce() async {
    let sink = Sink()
    let gate = PlaybackOrderGate(totalChunks: 1, onChunkReady: sink.handler)
    await gate.partial(index: 0, data: data("ab"))
    await gate.partial(index: 0, data: data("cd"))
    await gate.complete(index: 0, data: data("abcdef"))
    #expect(sink.emitted.map(\.1) == ["ab", "cd", "ef"])
    #expect(sink.emitted.allSatisfy { $0.0 == 0 })
  }

  @Test("Partials of a later chunk are held until its predecessor completes, then flushed in order")
  func laterChunkIsBuffered() async {
    let sink = Sink()
    let gate = PlaybackOrderGate(totalChunks: 2, onChunkReady: sink.handler)
    await gate.partial(index: 1, data: data("B1"))
    await gate.partial(index: 1, data: data("B2"))
    #expect(sink.emitted.isEmpty)
    await gate.complete(index: 0, data: data("A"))
    #expect(sink.emitted.map(\.1) == ["A", "B1B2"])
    await gate.partial(index: 1, data: data("B3"))
    await gate.complete(index: 1, data: data("B1B2B3B4"))
    #expect(sink.emitted.map(\.1) == ["A", "B1B2", "B3", "B4"])
  }

  @Test("Whole-chunk providers behave as before: completion out of order, emission in order")
  func nonStreamingOrder() async {
    let sink = Sink()
    let gate = PlaybackOrderGate(totalChunks: 3, onChunkReady: sink.handler)
    await gate.complete(index: 2, data: data("C"))
    await gate.complete(index: 1, data: data("B"))
    #expect(sink.emitted.isEmpty)
    await gate.complete(index: 0, data: data("A"))
    #expect(sink.emitted.map { "\($0.0):\($0.1)" } == ["0:A", "1:B", "2:C"])
  }

  @Test("A failed chunk opens the gate for its successors")
  func failureReleasesSuccessors() async {
    let sink = Sink()
    let gate = PlaybackOrderGate(totalChunks: 2, onChunkReady: sink.handler)
    await gate.complete(index: 1, data: data("B"))
    await gate.fail(index: 0)
    #expect(sink.emitted.map { "\($0.0):\($0.1)" } == ["1:B"])
  }

  @Test("A retry after live partials resumes after the bytes already played")
  func retryAfterLivePartials() async {
    let sink = Sink()
    let gate = PlaybackOrderGate(totalChunks: 1, onChunkReady: sink.handler)
    await gate.partial(index: 0, data: data("ab"))  // played, then the stream broke
    await gate.discardBuffered(index: 0)             // beforeRetry
    await gate.complete(index: 0, data: data("abcd"))  // second attempt's full result
    #expect(sink.emitted.map(\.1) == ["ab", "cd"])
  }

  @Test("A retry after buffered (unplayed) partials resends them in full")
  func retryAfterBufferedPartials() async {
    let sink = Sink()
    let gate = PlaybackOrderGate(totalChunks: 2, onChunkReady: sink.handler)
    await gate.partial(index: 1, data: data("x"))  // never emitted: chunk 0 still pending
    await gate.discardBuffered(index: 1)
    await gate.complete(index: 0, data: data("A"))
    await gate.complete(index: 1, data: data("B"))
    #expect(sink.emitted.map(\.1) == ["A", "B"])
  }

  @Test("Partials arriving after completion or failure are ignored")
  func latePartialsIgnored() async {
    let sink = Sink()
    let gate = PlaybackOrderGate(totalChunks: 1, onChunkReady: sink.handler)
    await gate.complete(index: 0, data: data("A"))
    await gate.partial(index: 0, data: data("late"))
    #expect(sink.emitted.map(\.1) == ["A"])
  }
}

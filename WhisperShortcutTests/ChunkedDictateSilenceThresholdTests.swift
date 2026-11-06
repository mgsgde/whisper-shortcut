import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Locks the noise-floor-relative silence threshold that decides when Dictate Live rotates a chunk.
/// With a fixed -45 dB threshold a noisy room never registered a pause, so nothing was inserted
/// until the user stopped.
@Suite("Chunked dictate adaptive silence threshold")
struct ChunkedDictateSilenceThresholdTests {

  @Test("No measured floor falls back to -45 dB")
  func nilFloor() {
    #expect(ChunkedDictateRecorder.adaptiveSilenceThreshold(noiseFloorDB: nil) == -45)
  }

  @Test("A quiet floor never goes below the -45 dB minimum")
  func quietFloor() {
    #expect(ChunkedDictateRecorder.adaptiveSilenceThreshold(noiseFloorDB: -70) == -45)
  }

  @Test("A noisy floor raises the threshold by 10 dB")
  func noisyFloor() {
    #expect(ChunkedDictateRecorder.adaptiveSilenceThreshold(noiseFloorDB: -42) == -32)
  }

  @Test("A very loud floor is clamped at -30 dB")
  func loudFloor() {
    #expect(ChunkedDictateRecorder.adaptiveSilenceThreshold(noiseFloorDB: -20) == -30)
  }

  @Test("The floor falls immediately to a lower sample")
  func floorFallsFast() {
    #expect(ChunkedDictateRecorder.updatedNoiseFloor(current: -40, sample: -60) == -60)
    #expect(ChunkedDictateRecorder.updatedNoiseFloor(current: nil, sample: -55) == -55)
  }

  @Test("Start-up samples below -90 dB are ignored")
  func ignoresStartupSamples() {
    #expect(ChunkedDictateRecorder.updatedNoiseFloor(current: -42, sample: -160) == -42)
    #expect(ChunkedDictateRecorder.updatedNoiseFloor(current: nil, sample: -160) == nil)
  }

  @Test("The floor rises at most 0.05 dB per sample")
  func floorRisesSlowly() {
    let next = ChunkedDictateRecorder.updatedNoiseFloor(current: -50, sample: -10) ?? 0
    #expect(abs(next - (-49.95)) < 0.0001)
    let small = ChunkedDictateRecorder.updatedNoiseFloor(current: -50, sample: -49.98) ?? 0
    #expect(abs(small - (-49.98)) < 0.0001)
  }

  @Test("Fifty speech samples raise the floor by at most 2.5 dB")
  func speechBarelyMovesFloor() {
    var floor: Float? = -50
    for _ in 0..<50 { floor = ChunkedDictateRecorder.updatedNoiseFloor(current: floor, sample: -15) }
    #expect((floor ?? -50) - (-50) <= 2.5001)
  }
}

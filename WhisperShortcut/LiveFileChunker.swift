//
//  LiveFileChunker.swift
//  WhisperShortcut
//
//  Splits a mono recording into the pieces Dictate Live would rotate out of a live microphone.
//  Used by the test-profile WAV harness, which has no microphone to feed the recorder.
//

import Foundation

enum LiveFileChunker {

  /// One piece of the source buffer. `range` is a half-open sample index into that buffer.
  struct Chunk: Equatable {
    let range: Range<Int>
    /// Every window in the piece is below the silence threshold.
    let isSilent: Bool
  }

  /// The cadence `ChunkedDictateRecorder` uses for rotation (metering decimated from 20 Hz).
  static let windowDuration: TimeInterval = 0.2

  /// `samples` are mono floats in -1…1. Levels are RMS in dB, one per `windowDuration` (the tail
  /// shorter than a window is still one level). The noise floor is the 10th percentile of those
  /// levels; the threshold is `ChunkedDictateRecorder.adaptiveSilenceThreshold`.
  ///
  /// Silence counts only once the current piece is already `minDuration` long, matching the
  /// recorder's early return. A run of at least `silenceDuration` below the threshold ends the
  /// piece at that window. The remainder is the tail piece. A cut is never emitted at the last
  /// sample, so the tail is never empty.
  static func chunks(
    samples: [Float], sampleRate: Double, policy: ChunkedDictateRecorder.RotationPolicy
  ) -> [Chunk] {
    guard sampleRate > 0, !samples.isEmpty else { return [] }
    let windowSamples = max(1, Int((windowDuration * sampleRate).rounded()))
    var boundaries = [0]
    var levels: [Float] = []
    var cursor = 0
    while cursor < samples.count {
      let end = min(cursor + windowSamples, samples.count)
      levels.append(rmsDecibels(samples[cursor..<end]))
      cursor = end
      boundaries.append(cursor)
    }

    let threshold = ChunkedDictateRecorder.adaptiveSilenceThreshold(noiseFloorDB: tenthPercentile(levels))
    let silenceWindowsNeeded = max(1, Int(ceil(policy.silenceDuration / windowDuration - 1e-9)))

    var result: [Chunk] = []
    var chunkStart = 0
    var consecutiveSilence = 0
    for index in levels.indices {
      let chunkDuration = Double(boundaries[index + 1] - boundaries[chunkStart]) / sampleRate
      // The recorder ignores silence until the piece is long enough, and does not remember it.
      if chunkDuration + 1e-6 < policy.minDuration {
        consecutiveSilence = 0
        continue
      }
      if levels[index] < threshold {
        consecutiveSilence += 1
        let cut = boundaries[index + 1]
        if consecutiveSilence >= silenceWindowsNeeded, cut < samples.count {
          result.append(
            Chunk(
              range: boundaries[chunkStart]..<cut,
              isSilent: entirelySilent(levels[chunkStart...index], threshold: threshold)))
          chunkStart = index + 1
          consecutiveSilence = 0
        }
      } else {
        consecutiveSilence = 0
      }
    }
    if chunkStart < levels.count {
      result.append(
        Chunk(
          range: boundaries[chunkStart]..<samples.count,
          isSilent: entirelySilent(levels[chunkStart...], threshold: threshold)))
    }
    return result
  }

  // MARK: - Levels

  /// 20·log10(RMS), floored at -160. Silence (all zeros) is -160, same floor as the recorder.
  private static func rmsDecibels(_ samples: ArraySlice<Float>) -> Float {
    guard !samples.isEmpty else { return -160 }
    var sum: Float = 0
    for sample in samples {
      sum += sample * sample
    }
    let mean = sum / Float(samples.count)
    guard mean > 0 else { return -160 }
    return max(10 * log10(mean), -160)
  }

  /// Nearest-rank 10th percentile: the value at `floor(0.10 * (count - 1))` of the sorted levels.
  private static func tenthPercentile(_ values: [Float]) -> Float {
    let sorted = values.sorted()
    let index = Int((0.10 * Double(sorted.count - 1)).rounded(.down))
    return sorted[index]
  }

  private static func entirelySilent(_ levels: ArraySlice<Float>, threshold: Float) -> Bool {
    !levels.isEmpty && levels.allSatisfy { $0 < threshold }
  }
}

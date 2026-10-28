//
//  MeetingAudioMixer.swift
//  WhisperShortcut
//
//  Combines a recorded microphone track with the other participants' system audio into one
//  mono signal, for a meeting recording where both halves of the conversation should end up in
//  the same transcript.
//

import AVFoundation
import Foundation

enum MeetingAudioMixer {

  /// Sums `mic` and `system` sample by sample, each result clamped to `[-1, 1]`. A shorter
  /// `system` is zero-padded; a longer one is truncated. Result length always equals
  /// `mic.count`.
  static func mix(mic: [Float], system: [Float]) -> [Float] {
    var result = [Float](repeating: 0, count: mic.count)
    for i in 0..<mic.count {
      let systemValue = i < system.count ? system[i] : 0
      result[i] = max(-1, min(1, mic[i] + systemValue))
    }
    return result
  }

  /// Reads the recording at `micURL`, downmixes it to mono if needed, mixes in `system` (mono
  /// float at the file's own sample rate), and rewrites the same URL as 16-bit PCM mono WAV.
  ///
  /// Writes to a temp file next to `micURL` first and swaps it in with
  /// `FileManager.replaceItemAt`, so a failure midway never leaves `micURL` partially written —
  /// on any error the temp file (if it still exists) is removed and the original is untouched.
  static func mixInPlace(micURL: URL, system: [Float]) throws {
    let sourceFile = try AVAudioFile(forReading: micURL)
    let sampleRate = sourceFile.processingFormat.sampleRate
    let frameCount = AVAudioFrameCount(sourceFile.length)

    guard
      let readBuffer = AVAudioPCMBuffer(
        pcmFormat: sourceFile.processingFormat, frameCapacity: frameCount)
    else {
      throw NSError(domain: "MeetingAudioMixer", code: -1)
    }
    if frameCount > 0 {
      try sourceFile.read(into: readBuffer)
    }
    let mic = monoSamples(from: readBuffer)
    let mixed = mix(mic: mic, system: system)

    let directory = micURL.deletingLastPathComponent()
    let tempURL = directory.appendingPathComponent("\(UUID().uuidString).wav")

    do {
      let outputSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ]
      let writeFile = try AVAudioFile(
        forWriting: tempURL,
        settings: outputSettings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false)

      guard
        let writeFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
          interleaved: false),
        let writeBuffer = AVAudioPCMBuffer(
          pcmFormat: writeFormat, frameCapacity: AVAudioFrameCount(mixed.count))
      else {
        writeFile.close()
        throw NSError(domain: "MeetingAudioMixer", code: -2)
      }
      writeBuffer.frameLength = AVAudioFrameCount(mixed.count)
      if let channelData = writeBuffer.floatChannelData, !mixed.isEmpty {
        mixed.withUnsafeBufferPointer { source in
          channelData[0].update(from: source.baseAddress!, count: mixed.count)
        }
      }
      try writeFile.write(from: writeBuffer)
      writeFile.close()

      _ = try FileManager.default.replaceItemAt(micURL, withItemAt: tempURL)
    } catch {
      try? FileManager.default.removeItem(at: tempURL)
      throw error
    }
  }

  /// Peak absolute sample value in dB (`20*log10(peak)`), floored at -160. Empty or all-zero
  /// input reads as -160.
  static func peakPowerDB(_ samples: [Float]) -> Float {
    var peak: Float = 0
    for sample in samples {
      let magnitude = abs(sample)
      if magnitude > peak { peak = magnitude }
    }
    guard peak > 0 else { return -160 }
    return max(20 * log10(peak), -160)
  }

  // MARK: - Private

  /// Averages all channels of `buffer` down to one mono array. Single-channel buffers are
  /// copied as-is.
  private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0, let channelData = buffer.floatChannelData else { return [] }

    let channelCount = Int(buffer.format.channelCount)
    if channelCount <= 1 {
      return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    var result = [Float](repeating: 0, count: frameLength)
    for channel in 0..<channelCount {
      let channelPointer = channelData[channel]
      for i in 0..<frameLength {
        result[i] += channelPointer[i]
      }
    }
    let scale = Float(1.0 / Double(channelCount))
    for i in 0..<frameLength {
      result[i] *= scale
    }
    return result
  }
}

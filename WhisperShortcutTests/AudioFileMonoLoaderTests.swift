//
//  AudioFileMonoLoaderTests.swift
//  WhisperShortcutTests
//
//  The loader exists because the library's `loadAudioArray` reads only channel 0 of a stereo
//  file — a voice reference imported from stereo audio would lose everything on the right
//  channel. These tests pin the mixdown and the resampling.
//

import AVFoundation
import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("AudioFileMonoLoader")
struct AudioFileMonoLoaderTests {

  /// Writes `channels` as an interleaved-free multi-channel CAF file (AVFoundation's native
  /// container, so no encoder is needed for float PCM).
  private func writeTestFile(
    channels: [[Float]], sampleRate: Double, url: URL
  ) throws {
    let channelCount = channels.count
    let format = AVAudioFormat(
      standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount))!
    let frameCount = AVAudioFrameCount(channels[0].count)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    for (index, channel) in channels.enumerated() {
      let target = buffer.floatChannelData![index]
      for frame in 0..<channel.count { target[frame] = channel[frame] }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
  }

  @Test("A stereo file is mixed to mono, not just channel 0")
  func stereoIsMixedToMono() throws {
    // Left silent, right at full level: the library would load this as silence.
    let frames = 480
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("stereo-test-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeTestFile(
      channels: [[Float](repeating: 0, count: frames), [Float](repeating: 0.8, count: frames)],
      sampleRate: 24_000, url: url)

    let (_, samples) = try AudioFileMonoLoader.loadMonoSamples(from: url, targetRate: 24_000)
    #expect(samples.count == frames)
    // (0 + 0.8) / 2 — the right channel survives the mixdown.
    #expect(abs(samples[0] - 0.4) < 0.01)
  }

  @Test("A mono file loads unchanged")
  func monoFileLoadsUnchanged() throws {
    let frames = 100
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mono-test-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeTestFile(
      channels: [[Float](repeating: 0.5, count: frames)], sampleRate: 16_000, url: url)

    let (_, samples) = try AudioFileMonoLoader.loadMonoSamples(from: url, targetRate: 16_000)
    #expect(samples.count == frames)
    #expect(abs(samples[0] - 0.5) < 0.01)
  }

  @Test("A file at a different rate is resampled to the target rate")
  func resamplesToTargetRate() throws {
    // 1 s at 8 kHz → 2 s worth of samples at 16 kHz.
    let frames = 8_000
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("rate-test-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeTestFile(
      channels: [[Float](repeating: 0.3, count: frames)], sampleRate: 8_000, url: url)

    let (fileRate, samples) = try AudioFileMonoLoader.loadMonoSamples(from: url, targetRate: 16_000)
    #expect(fileRate == 8_000)
    #expect(samples.count == 16_000)
    #expect(abs(samples[0] - 0.3) < 0.01)
  }

  @Test("A zero-length file reports emptyAudio, not a decode failure")
  func emptyFileReportsEmptyAudio() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("empty-test-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    do { _ = try AVAudioFile(forWriting: url, settings: format.settings) }

    #expect(throws: AudioFileMonoLoaderError.self) {
      try AudioFileMonoLoader.loadMonoSamples(from: url, targetRate: 16_000)
    }
    do {
      _ = try AudioFileMonoLoader.loadMonoSamples(from: url, targetRate: 16_000)
      Issue.record("expected emptyAudio")
    } catch AudioFileMonoLoaderError.emptyAudio {
    }
  }
}

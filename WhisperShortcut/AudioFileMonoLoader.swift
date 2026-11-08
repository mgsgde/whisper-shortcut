//
//  AudioFileMonoLoader.swift
//  WhisperShortcut
//
//  Decodes an audio file to a mono float waveform for the Qwen3 models.
//
//  The library's `loadAudioArray` reads only channel 0 of a stereo file. A voice reference the
//  user imports is often stereo, and a voice that sits mostly on the right channel would arrive
//  as near-silence. This loader mixes all channels down to mono (equal-weight average) and
//  resamples in the same pass, so every Qwen3 path (TTS reference import, ASR transcription)
//  sees the same waveform.
//

import AVFoundation
import Foundation

enum AudioFileMonoLoaderError: LocalizedError {
  case cannotCreateBuffer
  case emptyAudio

  var errorDescription: String? {
    switch self {
    case .cannotCreateBuffer:
      return String(localized: "The audio file could not be decoded.")
    case .emptyAudio:
      return String(localized: "The audio file contained no audio.")
    }
  }
}

enum AudioFileMonoLoader {

  /// Decodes `url` to mono float samples at `targetRate` (linear resampling, matching what the
  /// Qwen3 services did before). Returns the samples and the file's original sample rate.
  static func loadMonoSamples(
    from url: URL, targetRate: Int
  ) throws -> (fileRate: Int, samples: [Float]) {
    let audioFile = try AVAudioFile(forReading: url)
    let format = audioFile.processingFormat
    let frameCount = AVAudioFrameCount(audioFile.length)

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
      throw AudioFileMonoLoaderError.cannotCreateBuffer
    }
    try audioFile.read(into: buffer)

    guard let channelData = buffer.floatChannelData else {
      throw AudioFileMonoLoaderError.cannotCreateBuffer
    }

    let frames = Int(buffer.frameLength)
    guard frames > 0 else { throw AudioFileMonoLoaderError.emptyAudio }

    let channelCount = Int(format.channelCount)
    let fileRate = Int(format.sampleRate)

    // Equal-weight mixdown of every channel: the common stereo case is a simple (L+R)/2, and a
    // file with more channels degrades gracefully instead of dropping content.
    var mono = [Float](repeating: 0, count: frames)
    for channel in 0..<channelCount {
      let data = UnsafeBufferPointer(start: channelData[channel], count: frames)
      for frame in 0..<frames {
        mono[frame] += data[frame]
      }
    }
    if channelCount > 1 {
      for frame in 0..<frames {
        mono[frame] /= Float(channelCount)
      }
    }

    guard !mono.isEmpty else { throw AudioFileMonoLoaderError.emptyAudio }

    // Linear resampling, same interpolation the Qwen3 services used before; the recorder's
    // 16 kHz matches the ASR model, so this only runs for imported files.
    if fileRate == targetRate {
      return (fileRate, mono)
    }
    let ratio = Double(targetRate) / Double(fileRate)
    let count = Int(Double(mono.count) * ratio)
    guard count > 0 else { throw AudioFileMonoLoaderError.emptyAudio }
    let resampled: [Float] = (0..<count).map { index in
      let position = Double(index) / ratio
      let lower = Int(position)
      let upper = min(lower + 1, mono.count - 1)
      let fraction = Float(position - Double(lower))
      return mono[lower] * (1 - fraction) + mono[upper] * fraction
    }
    return (fileRate, resampled)
  }
}

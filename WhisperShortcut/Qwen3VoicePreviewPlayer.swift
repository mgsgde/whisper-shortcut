//
//  Qwen3VoicePreviewPlayer.swift
//  WhisperShortcut
//
//  Plays a short on-device voice sample inside Settings.
//
//  Read Aloud playback goes through `TTSPlaybackSession`, which is built for a streamed,
//  seekable, cancellable utterance and needs a whole `MenuBarController` around it. A Settings
//  preview is the opposite: one short clip, no scrubbing, no queue, and it must never touch the
//  Read Aloud state machine (a preview would otherwise flip the app into `.speaking` and show the
//  pill). So this is a plain `AVAudioPlayer` over a WAV container built from the same s16le
//  24 kHz mono PCM every TTS provider returns.
//

import AVFoundation
import Foundation

@MainActor
final class Qwen3VoicePreviewPlayer: NSObject, AVAudioPlayerDelegate {
  static let shared = Qwen3VoicePreviewPlayer()

  private var player: AVAudioPlayer?
  /// Called on the main actor when a preview ends on its own or is stopped. Settings uses it to
  /// turn the Listen button back from Stop.
  private var onFinish: (() -> Void)?

  /// Whether a preview is currently audible. Drives the button's "Stop" state.
  var isPlaying: Bool { player?.isPlaying ?? false }

  /// Plays `pcm` (s16le, 24 kHz, mono) and returns immediately. A running preview is stopped
  /// first, so pressing the button twice never layers two voices.
  func play(pcm: Data, sampleRate: Double = 24_000, onFinish: (() -> Void)? = nil) throws {
    stop()
    let wav = Self.wavContainer(pcm: pcm, sampleRate: sampleRate)
    let player = try AVAudioPlayer(data: wav)
    player.delegate = self
    player.prepareToPlay()
    guard player.play() else {
      throw Qwen3VoicePreviewError.playbackFailed
    }
    self.player = player
    self.onFinish = onFinish
  }

  func stop() {
    let callback = onFinish
    onFinish = nil
    player?.stop()
    player = nil
    callback?()
  }

  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor in
      // Only the current player may clear the state: a stop() followed by a new play() leaves the
      // old player's completion arriving late.
      guard self.player === player else { return }
      let callback = self.onFinish
      self.onFinish = nil
      self.player = nil
      callback?()
    }
  }

  /// Wraps raw little-endian 16-bit mono PCM in a 44-byte RIFF/WAVE header. `AVAudioPlayer` reads
  /// containers, not bare PCM, and building the header here keeps the TTS output contract (raw
  /// PCM) unchanged for every other consumer.
  static func wavContainer(pcm: Data, sampleRate: Double) -> Data {
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)

    var data = Data(capacity: 44 + pcm.count)
    func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
    func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    appendASCII("RIFF")
    appendUInt32(UInt32(36 + pcm.count))
    appendASCII("WAVE")
    appendASCII("fmt ")
    appendUInt32(16)
    appendUInt16(1)  // PCM
    appendUInt16(channels)
    appendUInt32(UInt32(sampleRate))
    appendUInt32(byteRate)
    appendUInt16(blockAlign)
    appendUInt16(bitsPerSample)
    appendASCII("data")
    appendUInt32(UInt32(pcm.count))
    data.append(pcm)
    return data
  }
}

enum Qwen3VoicePreviewError: LocalizedError {
  case playbackFailed

  var errorDescription: String? {
    switch self {
    case .playbackFailed:
      return String(localized: "The voice sample could not be played.")
    }
  }
}

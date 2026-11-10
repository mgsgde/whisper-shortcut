//
//  Qwen3PrebufferGate.swift
//  WhisperShortcut
//
//  When Qwen3 generates slower than playback, handing each sentence to the player as it
//  finishes leaves a gap: the sentence plays out, then the pill waits while the next one is
//  still being made. This gate says when the audio held so far is enough to play through the
//  estimated remainder without that gap. It is pure so the decision can be tested without a
//  model.
//

import Foundation

/// Decides when held-back Qwen3 Read Aloud audio may start playing.
struct Qwen3PrebufferGate {
  /// Head-room on the estimate: sentence-sized arrivals and a noisy rate both argue for slack.
  static let safetyFactor = 1.25
  /// Never hold more than this much audio before starting; a very slow machine still hears
  /// something within a bounded time and falls back to the player's own buffering.
  static let maxHoldSeconds: Double = 60

  /// - bufferedAudio: seconds of audio produced and held so far (not yet released)
  /// - producedAudio: seconds of audio produced so far in this run (== bufferedAudio before release)
  /// - computeSeconds: wall-clock seconds spent generating those sentences (sum of per-sentence elapsed)
  /// - producedChars / remainingChars: characters of sentences done / still to generate
  /// - speed: playback rate (1.0, 1.25, …)
  static func shouldRelease(
    bufferedAudio: Double, producedAudio: Double, computeSeconds: Double,
    producedChars: Int, remainingChars: Int, speed: Double
  ) -> Bool {
    if remainingChars == 0 { return true }
    if bufferedAudio >= maxHoldSeconds { return true }
    // Nothing to estimate from: holding would wait forever, so stream.
    if producedChars == 0 || computeSeconds <= 0 || producedAudio <= 0 { return true }

    let rate = producedAudio / computeSeconds
    let remainingAudio = Double(remainingChars) * producedAudio / Double(producedChars)
    let effectiveSpeed = speed * safetyFactor
    // Already faster than playback, with slack: streaming cannot run dry.
    if rate >= effectiveSpeed { return true }
    // Playback consumes `effectiveSpeed` audio-seconds per wall second and production adds
    // `rate`. The remaining audio finishes at R/rate. No stall needs
    // effectiveSpeed * R/rate <= buffered + R, i.e. buffered >= R * (effectiveSpeed/rate - 1).
    return bufferedAudio >= remainingAudio * (effectiveSpeed / rate - 1)
  }

  /// Characters synthesized so far over the whole run, in 0...1.
  static func progress(producedChars: Int, remainingChars: Int) -> Double {
    let total = producedChars + remainingChars
    guard total > 0 else { return 0 }
    return min(1, max(0, Double(producedChars) / Double(total)))
  }
}

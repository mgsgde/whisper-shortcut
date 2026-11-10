//
//  Qwen3PrebufferGateTests.swift
//  WhisperShortcutTests
//
//  The gate decides whether Qwen3 Read Aloud may start playing or must keep holding. The
//  numbers below are the measured M1 Pro run (3.69 s of audio in 9.0 s) and the extremes
//  the formula has to get right without a model in the loop.
//

import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Qwen3 Read Aloud pre-buffer gate")
struct Qwen3PrebufferGateTests {

  @Test("A fast machine releases immediately")
  func fastMachineReleasesImmediately() {
    // r = 2 audio-seconds per wall second, playback at 1×. Far above speed × 1.25, so even a
    // long tail and a tiny buffer must not be held.
    #expect(Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: 0.1, producedAudio: 2, computeSeconds: 1,
      producedChars: 40, remainingChars: 4_000, speed: 1))
  }

  @Test("The measured slow run holds until the buffer covers the tail")
  func measuredRunHoldsUntilThreshold() {
    let producedAudio = 3.69
    let computeSeconds = 9.0
    let producedChars = 60
    let remainingChars = 300
    let speed = 1.25

    #expect(!Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: producedAudio, producedAudio: producedAudio, computeSeconds: computeSeconds,
      producedChars: producedChars, remainingChars: remainingChars, speed: speed))

    let rate = producedAudio / computeSeconds
    let remainingAudio = Double(remainingChars) * producedAudio / Double(producedChars)
    let threshold = remainingAudio * (speed * Qwen3PrebufferGate.safetyFactor / rate - 1)
    // Pins the measured inputs to ~52 s. Dropping the 1.25 slack lands near 38 s and fails this.
    #expect(abs(threshold - 51.8625) < 0.001)
    #expect(threshold < Qwen3PrebufferGate.maxHoldSeconds)

    #expect(!Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: threshold.nextDown, producedAudio: producedAudio,
      computeSeconds: computeSeconds, producedChars: producedChars,
      remainingChars: remainingChars, speed: speed))
    #expect(Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: threshold, producedAudio: producedAudio, computeSeconds: computeSeconds,
      producedChars: producedChars, remainingChars: remainingChars, speed: speed))
  }

  @Test("The wait cap releases after 45 s of generation even when the estimate wants more")
  func maxWaitCapReleases() {
    let args = (bufferedAudio: 18.0, producedChars: 300, remainingChars: 3_000, speed: 1.25)
    #expect(!Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: args.bufferedAudio, producedAudio: args.bufferedAudio,
      computeSeconds: Qwen3PrebufferGate.maxWaitSeconds - 0.1, producedChars: args.producedChars,
      remainingChars: args.remainingChars, speed: args.speed))
    #expect(Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: args.bufferedAudio, producedAudio: args.bufferedAudio,
      computeSeconds: Qwen3PrebufferGate.maxWaitSeconds, producedChars: args.producedChars,
      remainingChars: args.remainingChars, speed: args.speed))
  }

  @Test("Nothing left to generate releases")
  func noRemainingCharactersReleases() {
    #expect(Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: 0.1, producedAudio: 0.1, computeSeconds: 100,
      producedChars: 10, remainingChars: 0, speed: 2))
  }

  @Test("The hold cap releases even when the estimate wants more")
  func maxHoldCapReleases() {
    // r = 0.1 against a huge tail, so the formula's threshold is far above 60 s.
    let slow = (
      producedAudio: 3.0, computeSeconds: 30.0, producedChars: 100,
      remainingChars: 100_000, speed: 1.25)
    #expect(Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: Qwen3PrebufferGate.maxHoldSeconds,
      producedAudio: slow.producedAudio, computeSeconds: slow.computeSeconds,
      producedChars: slow.producedChars, remainingChars: slow.remainingChars, speed: slow.speed))
    #expect(!Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: Qwen3PrebufferGate.maxHoldSeconds - 0.1,
      producedAudio: slow.producedAudio, computeSeconds: slow.computeSeconds,
      producedChars: slow.producedChars, remainingChars: slow.remainingChars, speed: slow.speed))
  }

  @Test("A missing estimate does not hold")
  func zeroComputeReleases() {
    #expect(Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: 1, producedAudio: 1, computeSeconds: 0,
      producedChars: 10, remainingChars: 100, speed: 1))
    #expect(Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: 1, producedAudio: 1, computeSeconds: -1,
      producedChars: 10, remainingChars: 100, speed: 1))
    #expect(Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: 1, producedAudio: 0, computeSeconds: 5,
      producedChars: 10, remainingChars: 100, speed: 1))
    #expect(Qwen3PrebufferGate.shouldRelease(
      bufferedAudio: 1, producedAudio: 1, computeSeconds: 5,
      producedChars: 0, remainingChars: 100, speed: 1))
  }

  @Test("Progress stays inside 0...1")
  func progressBounds() {
    #expect(Qwen3PrebufferGate.progress(producedChars: 0, remainingChars: 10) == 0)
    #expect(Qwen3PrebufferGate.progress(producedChars: 10, remainingChars: 0) == 1)
    #expect(Qwen3PrebufferGate.progress(producedChars: 0, remainingChars: 0) == 0)
    #expect(Qwen3PrebufferGate.progress(producedChars: 1, remainingChars: 3) == 0.25)
  }
}

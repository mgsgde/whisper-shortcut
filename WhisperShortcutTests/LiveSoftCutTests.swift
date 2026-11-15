import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The soft max piece length of Dictate Live: after 5 s one quiet 0.2 s decision under a relaxed
/// threshold cuts. Pure decision function plus the kill switch.
@Suite("Live soft cut")
struct LiveSoftCutTests {
  private typealias Recorder = ChunkedDictateRecorder
  private let step = 0.2

  private func criterion(_ policy: Recorder.RotationPolicy, _ seconds: Double, base: Float = -45)
    -> Recorder.SilenceCriterion
  {
    Recorder.silenceCriterion(
      policy: policy, pieceDuration: seconds, baseThresholdDB: base, decisionInterval: step)
  }

  @Test("No soft cut before 5 s: three decisions below the base threshold")
  func beforeSoftCut() {
    let c = criterion(.live, 4.8)
    #expect(!c.isSoft)
    #expect(c.decisionsNeeded == 3)
    #expect(c.thresholdDB == -45)
  }

  @Test("From 5 s one decision under threshold plus 10 dB cuts")
  func afterSoftCut() {
    let c = criterion(.live, 5.0)
    #expect(c.isSoft)
    #expect(c.decisionsNeeded == 1)
    #expect(c.thresholdDB == -35)
  }

  @Test("The relaxed threshold is capped at -20 dB")
  func capped() {
    #expect(criterion(.live, 6, base: -30).thresholdDB == -20)
  }

  @Test(".standard is unchanged at any length")
  func standardUnchanged() {
    for seconds in [1.0, 5.0, 30.0] {
      let c = criterion(.standard, seconds)
      #expect(!c.isSoft)
      #expect(c.thresholdDB == -45)
      #expect(c.decisionsNeeded == Recorder.rotationSilenceSamplesNeeded(for: .standard))
    }
  }

  @Test("Kill switch restores the old live behavior")
  func killSwitch() {
    let suite = UserDefaults(suiteName: "live-soft-cut-\(UUID().uuidString)")!
    #expect(Recorder.RotationPolicy.currentLive(defaults: suite) == .live)
    suite.set(true, forKey: UserDefaultsKeys.liveSoftCutDisabled)
    let policy = Recorder.RotationPolicy.currentLive(defaults: suite)
    #expect(policy == .liveWithoutSoftCut)
    let c = criterion(policy, 12)
    #expect(!c.isSoft)
    #expect(c.decisionsNeeded == 3)
  }

  @Test("The file chunker cuts fluent speech at a soft pause, and not with the kill switch")
  func fileChunkerSoftCut() {
    let rate = 16_000.0
    func tone(_ s: Double) -> [Float] {
      (0..<Int(s * rate)).map { 0.5 * sin(Float($0) * 0.1) }
    }
    // Quiet floor at -40 dB RMS stays above the hard threshold but under the soft one.
    func murmur(_ s: Double) -> [Float] {
      (0..<Int(s * rate)).map { 0.014 * sin(Float($0) * 0.1) }
    }
    let samples = tone(5.4) + murmur(0.2) + tone(3)
    let soft = LiveFileChunker.chunks(samples: samples, sampleRate: rate, policy: .live)
    let old = LiveFileChunker.chunks(samples: samples, sampleRate: rate, policy: .liveWithoutSoftCut)
    #expect(soft.count == 2)
    #expect(old.count == 1)
  }
}

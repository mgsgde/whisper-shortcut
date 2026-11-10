//
//  SpeechActivityGate.swift
//  WhisperShortcut
//
//  Silero VAD (FluidAudio) in front of cloud transcription. A chunk that is noise or a long
//  pause used to be uploaded anyway, and gpt-transcribe answered with the glossary keywords.
//  This gate drops a chunk with almost no speech and trims a long quiet head or tail.
//  Offline Whisper, Parakeet and Qwen never come through here.
//

import AVFoundation
import FluidAudio
import Foundation

private enum SpeechActivityGateError: Error {
  case emptyRange
  case unreadableAudio
}

/// One Silero model for the process. `decide` never waits on the download: until `prepare`
/// has finished, it returns nil and the caller uploads the chunk as before.
actor SpeechActivityGate {
  static let shared = SpeechActivityGate()

  enum Decision: Equatable {
    case noSpeech
    case keep
    /// Keep samples in `[start, end)` of the original file. Times are seconds.
    case trim(start: TimeInterval, end: TimeInterval)
  }

  private enum LoadState {
    case notStarted
    case loading
    case ready(VadManager)
    case failed
  }

  private var loadState: LoadState = .notStarted

  /// Loads `silero-vad-coreml` once. A failure is logged once and the gate stays off
  /// for this launch. Never throws.
  func prepare() async {
    guard case .notStarted = loadState else { return }
    loadState = .loading
    let started = CFAbsoluteTimeGetCurrent()
    do {
      // 0.5 is Silero's standard threshold. The package default (0.85) drops quiet speech,
      // and this gate's job is to drop audio, so a miss here is a lost dictation.
      let manager = try await VadManager(config: VadConfig(defaultThreshold: 0.5))
      loadState = .ready(manager)
      let milliseconds = Int(((CFAbsoluteTimeGetCurrent() - started) * 1000).rounded())
      DebugLogger.log("SPEECH-GATE: Silero VAD ready (\(milliseconds)ms)")
    } catch {
      loadState = .failed
      DebugLogger.logWarning("SPEECH-GATE: Silero VAD failed to load: \(error.logDescription)")
    }
  }

  /// nil means the gate is off, not loaded yet, or could not read this file. The caller
  /// then does what it did before this gate existed.
  func decide(for url: URL) async -> Decision? {
    guard Self.isEnabled else { return nil }
    // Do not wait on an in-flight download. A chunk recorded during first launch uploads.
    guard case .ready(let vad) = loadState else { return nil }
    let started = CFAbsoluteTimeGetCurrent()
    do {
      let samples = try AudioConverter().resampleAudioFile(url)
      let vadSegments = try await vad.segmentSpeech(
        samples, config: VadSegmentationConfig(speechPadding: 0.1))
      let duration = Double(samples.count) / 16000
      let segments = vadSegments.map { (start: $0.startTime, end: $0.endTime) }
      let speech = segments.reduce(0.0) { $0 + ($1.end - $1.start) }
      let decision = Self.decision(segments: segments, duration: duration)
      let milliseconds = Int(((CFAbsoluteTimeGetCurrent() - started) * 1000).rounded())
      DebugLogger.logSpeech(
        "SPEECH-GATE: \(Self.label(decision)) (audio \(Self.seconds(duration))s, speech \(Self.seconds(speech))s, \(segments.count) segments, \(milliseconds)ms)")
      return decision
    } catch {
      DebugLogger.logWarning("SPEECH-GATE: could not classify audio: \(error.logDescription)")
      return nil
    }
  }

  /// Pure rule, no audio and no model.
  ///
  /// Under 0.25 s of speech is not a dictation. Otherwise keep a 0.4 s lead-in and a 0.6 s
  /// tail; trim only when that still removes at least 1.5 s. `segments` are in time order
  /// (first start, last end), which is what Silero returns.
  nonisolated static func decision(
    segments: [(start: TimeInterval, end: TimeInterval)],
    duration: TimeInterval
  ) -> Decision {
    let speech = segments.reduce(0.0) { $0 + ($1.end - $1.start) }
    guard speech >= 0.25, let first = segments.first, let last = segments.last else {
      return .noSpeech
    }
    let start = max(0, first.start - 0.4)
    let end = min(duration, last.end + 0.6)
    if (start + (duration - end)) >= 1.5 {
      return .trim(start: start, end: end)
    }
    return .keep
  }

  /// Frames `[start, end)` in the file's own format, written as a new WAV under the temp directory.
  nonisolated static func writeTrimmedCopy(of url: URL, start: TimeInterval, end: TimeInterval) throws -> URL {
    let input = try AVAudioFile(forReading: url)
    let rate = input.fileFormat.sampleRate
    guard rate > 0, end > start else { throw SpeechActivityGateError.emptyRange }
    let startFrame = max(0, min(input.length, AVAudioFramePosition((start * rate).rounded(.down))))
    let endFrame = max(startFrame, min(input.length, AVAudioFramePosition((end * rate).rounded(.down))))
    guard endFrame > startFrame else { throw SpeechActivityGateError.emptyRange }

    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("speechgate-\(UUID().uuidString).wav")
    let output: AVAudioFile
    do {
      output = try AVAudioFile(
        forWriting: destination,
        settings: input.fileFormat.settings,
        commonFormat: input.processingFormat.commonFormat,
        interleaved: input.processingFormat.isInterleaved
      )
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }

    input.framePosition = startFrame
    let chunk: AVAudioFrameCount = 65_536
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
      output.close()
      try? FileManager.default.removeItem(at: destination)
      throw SpeechActivityGateError.unreadableAudio
    }
    var remaining = endFrame - startFrame
    do {
      while remaining > 0 {
        let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
        try input.read(into: buffer, frameCount: count)
        guard buffer.frameLength > 0 else { throw SpeechActivityGateError.unreadableAudio }
        try output.write(from: buffer)
        remaining -= AVAudioFramePosition(buffer.frameLength)
      }
      output.close()
      return destination
    } catch {
      output.close()
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  /// Unset means on. No Settings row; this is a kill switch only.
  private nonisolated static var isEnabled: Bool {
    let key = UserDefaultsKeys.speechActivityGateEnabled
    guard UserDefaults.standard.object(forKey: key) != nil else { return true }
    return UserDefaults.standard.bool(forKey: key)
  }

  private nonisolated static func label(_ decision: Decision) -> String {
    switch decision {
    case .noSpeech: return "noSpeech"
    case .keep: return "keep"
    case .trim(let start, let end):
      return "trim(\(seconds(start))-\(seconds(end)))"
    }
  }

  private nonisolated static func seconds(_ value: TimeInterval) -> String {
    String(format: "%.1f", value)
  }
}

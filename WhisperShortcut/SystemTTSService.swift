import AVFoundation
import Foundation

/// On-device Read Aloud via `AVSpeechSynthesizer`.
///
/// Emits the same raw PCM the cloud TTS providers return (s16le, 24 kHz, mono) so
/// `SpeechService.performTTS` can hand the result to `MenuBarController`'s existing playback
/// path (`readSelectionAloud` / `readProseAloud` → `onChunkReady`). A follow-up that wires
/// the Offline Mode shortcut entry point does not need a second player — it already calls
/// those SpeechService methods.
final class SystemTTSService: NSObject {
  static let shared = SystemTTSService()

  private let synthesizer = AVSpeechSynthesizer()
  private let lock = NSLock()
  private var activeContinuation: CheckedContinuation<Data, Error>?
  private var collectedPCM = Data()

  private static let outputSampleRate: Double = 24_000

  private override init() {
    super.init()
  }

  /// Voices from `AVSpeechSynthesisVoice.speechVoices()`, current-language first.
  static var voices: [TTSVoice] {
    let currentLang = AVSpeechSynthesisVoice.currentLanguageCode()
    let homePrefix = String(currentLang.prefix(2))
    return AVSpeechSynthesisVoice.speechVoices()
      .sorted { lhs, rhs in
        let lHome = lhs.language.hasPrefix(homePrefix)
        let rHome = rhs.language.hasPrefix(homePrefix)
        if lHome != rHome { return lHome && !rHome }
        if lhs.language != rhs.language { return lhs.language < rhs.language }
        return lhs.name < rhs.name
      }
      .map { voice in
        let gender: String
        switch voice.gender {
        case .male: gender = "m"
        case .female: gender = "w"
        default: gender = "neutral"
        }
        let qualityLabel: String
        switch voice.quality {
        case .enhanced: qualityLabel = "Enhanced"
        case .premium: qualityLabel = "Premium"
        default: qualityLabel = ""
        }
        let descriptor = qualityLabel.isEmpty
          ? voice.language
          : "\(voice.language) · \(qualityLabel)"
        return TTSVoice(
          id: voice.identifier,
          gender: gender,
          descriptor: descriptor,
          displayLabel: voice.name)
      }
  }

  static var defaultVoiceIdentifier: String {
    let lang = AVSpeechSynthesisVoice.currentLanguageCode()
    if let match = AVSpeechSynthesisVoice(language: lang) {
      return match.identifier
    }
    return AVSpeechSynthesisVoice.speechVoices().first?.identifier ?? ""
  }

  /// Synthesizes `text` to s16le 24 kHz mono PCM.
  ///
  /// `AVSpeechSynthesizer.write` is started on the main queue (it wants a run loop) but the
  /// continuation lives off the main actor so the write callback cannot deadlock behind it.
  func synthesizePCM(text: String, voiceIdentifier: String) async throws -> Data {
    // `write` is only guaranteed to deliver the terminating empty buffer for an utterance it
    // actually speaks. Nothing to say means the continuation would never resume, and Read Aloud
    // would hang instead of finishing quietly.
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Data() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.main.async {
          self.beginWrite(text: text, voiceIdentifier: voiceIdentifier, continuation: continuation)
        }
      }
    } onCancel: {
      self.cancel()
    }
  }

  func cancel() {
    DispatchQueue.main.async { [weak self] in
      self?.synthesizer.stopSpeaking(at: .immediate)
    }
    finish(with: .failure(CancellationError()))
  }

  private func beginWrite(
    text: String,
    voiceIdentifier: String,
    continuation: CheckedContinuation<Data, Error>
  ) {
    lock.lock()
    if let previous = activeContinuation {
      activeContinuation = nil
      previous.resume(throwing: CancellationError())
    }
    activeContinuation = continuation
    collectedPCM = Data()
    lock.unlock()

    let utterance = AVSpeechUtterance(string: text)
    if !voiceIdentifier.isEmpty,
       let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
      utterance.voice = voice
    }
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate

    synthesizer.write(utterance) { [weak self] buffer in
      guard let self else { return }
      guard let pcm = buffer as? AVAudioPCMBuffer else { return }
      if pcm.frameLength == 0 {
        self.lock.lock()
        let data = self.collectedPCM
        self.lock.unlock()
        DebugLogger.log("SYSTEM-TTS: synthesized \(data.count) bytes (\(text.count) chars)")
        self.finish(with: .success(data))
        return
      }
      if let converted = Self.convertToS16le24k(pcm) {
        self.lock.lock()
        self.collectedPCM.append(converted)
        self.lock.unlock()
      }
    }
  }

  private func finish(with result: Result<Data, Error>) {
    lock.lock()
    let cont = activeContinuation
    activeContinuation = nil
    lock.unlock()
    cont?.resume(with: result)
  }

  /// Converts one synthesizer buffer into the PCM layout `TTSPlaybackSession` expects.
  private static func convertToS16le24k(_ input: AVAudioPCMBuffer) -> Data? {
    guard input.frameLength > 0 else { return nil }
    let inFormat = input.format
    guard let outFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: outputSampleRate,
      channels: 1,
      interleaved: true)
    else { return nil }

    if inFormat.commonFormat == .pcmFormatInt16,
       inFormat.sampleRate == outputSampleRate,
       inFormat.channelCount == 1,
       let channel = input.int16ChannelData {
      let byteCount = Int(input.frameLength) * 2
      return Data(bytes: channel[0], count: byteCount)
    }

    guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
      DebugLogger.logWarning("SYSTEM-TTS: no converter for \(inFormat)")
      return nil
    }
    let ratio = outFormat.sampleRate / inFormat.sampleRate
    let outFrames = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up) + 32)
    guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrames) else {
      return nil
    }

    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if consumed {
        status.pointee = .endOfStream
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return input
    }
    if let error {
      DebugLogger.logWarning("SYSTEM-TTS: convert failed (\(error.localizedDescription))")
      return nil
    }
    guard output.frameLength > 0, let channel = output.int16ChannelData else { return nil }
    let byteCount = Int(output.frameLength) * Int(outFormat.streamDescription.pointee.mBytesPerFrame)
    return Data(bytes: channel[0], count: byteCount)
  }
}

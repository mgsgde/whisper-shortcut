import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Own-server Read Aloud asks for `response_format: wav` and decodes it to s16le 24 kHz mono.
/// Servers that stream the WAV cannot know the length up front and write 0xFFFFFFFF (or 0) into
/// the RIFF and data size fields.
@Suite("Own server WAV decode")
struct OwnServerWavDecodeTests {

  private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
  private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

  /// A PCM s16le WAV with a sine wave; `sizeField` overrides both size fields when set.
  private func makeWav(sampleRate: Int, channels: Int, seconds: Double, sizeField: UInt32? = nil) -> Data {
    let frames = Int(Double(sampleRate) * seconds)
    var pcm = [UInt8]()
    for i in 0..<frames {
      let sample = Int16(8000 * sin(2 * .pi * 440 * Double(i) / Double(sampleRate)))
      for _ in 0..<channels { pcm += le16(UInt16(bitPattern: sample)) }
    }
    var out = [UInt8]()
    out += Array("RIFF".utf8) + le32(sizeField ?? UInt32(36 + pcm.count)) + Array("WAVE".utf8)
    out += Array("fmt ".utf8) + le32(16) + le16(1) + le16(UInt16(channels))
    out += le32(UInt32(sampleRate)) + le32(UInt32(sampleRate * channels * 2))
    out += le16(UInt16(channels * 2)) + le16(16)
    out += Array("data".utf8) + le32(sizeField ?? UInt32(pcm.count)) + pcm
    return Data(out)
  }

  @Test("A well-formed 24 kHz mono WAV passes through at its own length")
  func wellFormed24k() throws {
    let pcm = try SpeechService.wavToS16le24k(makeWav(sampleRate: 24000, channels: 1, seconds: 0.5))
    #expect(pcm.count == 12000 * 2)
  }

  @Test("Streaming headers (sizes 0xFFFFFFFF) still decode to the full audio")
  func streamingHeaderMaxSize() throws {
    let wav = makeWav(sampleRate: 24000, channels: 1, seconds: 0.5, sizeField: 0xFFFF_FFFF)
    let pcm = try SpeechService.wavToS16le24k(wav)
    #expect(pcm.count == 12000 * 2)
  }

  @Test("Streaming headers (sizes 0) still decode to the full audio")
  func streamingHeaderZeroSize() throws {
    let wav = makeWav(sampleRate: 24000, channels: 1, seconds: 0.5, sizeField: 0)
    let pcm = try SpeechService.wavToS16le24k(wav)
    #expect(pcm.count == 12000 * 2)
  }

  @Test("44.1 kHz stereo converts to 24 kHz mono of about the same duration")
  func stereoResample() throws {
    let pcm = try SpeechService.wavToS16le24k(makeWav(sampleRate: 44100, channels: 2, seconds: 1.0))
    let frames = pcm.count / 2
    #expect(abs(frames - 24000) < 600)
  }

  @Test("A non-WAV body is an error")
  func nonWavBody() {
    let body = Data(#"{"error":{"message":"no such model"}}"#.utf8)
    #expect(throws: (any Error).self) { try SpeechService.wavToS16le24k(body) }
  }
}

@Suite("Read Aloud fallback record")
struct ReadAloudFallbackRecordTests {
  @Test("An own server that lost its URL leaves no record a cloud key could upgrade")
  func ownServerFallbackIsNotRecorded() {
    #expect(!ModelSelectionReconciler.recordsReadAloudFallback(current: .ownServerTTS, replacement: .systemMacOS))
    // A lost cloud key is still recorded so a returning key restores a cloud voice.
    #expect(ModelSelectionReconciler.recordsReadAloudFallback(current: .gemini38FlashTTS, replacement: .systemMacOS))
    #expect(!ModelSelectionReconciler.recordsReadAloudFallback(current: .gemini38FlashTTS, replacement: .openAIGpt4oMiniTTS))
  }
}

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The "object → PCM bytes" step of the Gemini TTS stream (`SpeechService.parseGeminiTTSStreamObject`):
/// audio parts are base64-decoded and concatenated, metadata-only objects yield nil, a
/// finishReason is surfaced, and server-side errors / blocks throw so the retry policy sees them.
@Suite("Gemini TTS stream object → PCM")
struct GeminiTTSStreamObjectTests {

  private func object(_ json: String) -> Data { Data(json.utf8) }

  private let pcm = Data([0x01, 0x02, 0x03, 0x04])

  @Test("An object with inlineData yields the decoded PCM")
  func audioObject() throws {
    let json = """
      {"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"audio/l16; rate=24000; channels=1","data":"\(pcm.base64EncodedString())"}}],"role":"model"},"index":0}],"usageMetadata":{"promptTokenCount":12}}
      """
    let parsed = try SpeechService.parseGeminiTTSStreamObject(object(json))
    #expect(parsed.audio == pcm)
    #expect(parsed.finishReason == nil)
  }

  @Test("Several inlineData parts in one object are concatenated in order")
  func multipleParts() throws {
    let a = Data([0x0A, 0x0B]), b = Data([0x0C, 0x0D])
    let json = """
      {"candidates":[{"content":{"parts":[{"inlineData":{"data":"\(a.base64EncodedString())"}},{"inlineData":{"data":"\(b.base64EncodedString())"}}]}}]}
      """
    #expect(try SpeechService.parseGeminiTTSStreamObject(object(json)).audio == a + b)
  }

  @Test("A usage-metadata-only object yields no audio")
  func usageOnlyObject() throws {
    let json = #"{"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":300,"totalTokenCount":312},"modelVersion":"gemini-3.1-flash-tts-preview"}"#
    let parsed = try SpeechService.parseGeminiTTSStreamObject(object(json))
    #expect(parsed.audio == nil)
    #expect(parsed.finishReason == nil)
  }

  @Test("finishReason is surfaced alongside the last audio slice")
  func finishReasonObject() throws {
    let json = """
      {"candidates":[{"content":{"parts":[{"inlineData":{"data":"\(pcm.base64EncodedString())"}}]},"finishReason":"STOP"}]}
      """
    let parsed = try SpeechService.parseGeminiTTSStreamObject(object(json))
    #expect(parsed.audio == pcm)
    #expect(parsed.finishReason == "STOP")
  }

  @Test("A bare finishReason without audio yields nil audio but keeps the reason")
  func finishReasonOnly() throws {
    let json = #"{"candidates":[{"finishReason":"MAX_TOKENS","index":0}]}"#
    let parsed = try SpeechService.parseGeminiTTSStreamObject(object(json))
    #expect(parsed.audio == nil)
    #expect(parsed.finishReason == "MAX_TOKENS")
  }

  @Test("A top-level error object throws a TranscriptionError")
  func errorObjectThrows() {
    let json = #"{"error":{"code":503,"message":"The model is overloaded. Please try again later.","status":"UNAVAILABLE"}}"#
    #expect(throws: TranscriptionError.self) {
      try SpeechService.parseGeminiTTSStreamObject(object(json))
    }
  }

  @Test("A promptFeedback.blockReason throws a TranscriptionError")
  func blockReasonThrows() {
    let json = #"{"promptFeedback":{"blockReason":"SAFETY"}}"#
    #expect(throws: TranscriptionError.self) {
      try SpeechService.parseGeminiTTSStreamObject(object(json))
    }
  }
}

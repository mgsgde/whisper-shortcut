import Testing
@testable import WhisperShortcut_AppStore

@Suite("Read Aloud model migration")
struct ReadAloudModelMigrationTests {

  @Test("Retired Gemini TTS slugs forward to 3.8 Flash-Lite TTS")
  func retiredGeminiTTSForward() throws {
    for raw in ["gemini-3.1-flash-tts-preview", "gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts"] {
      #expect(TTSModel.migrateLegacyReadAloudRawValue(raw) == TTSModel.gemini38FlashLiteTTS.rawValue)
    }
    // Current selections are left alone. gpt-4o-mini-tts stays the retired raw value so
    // ModelSelectionReconciler.retiredReadAloudReplacement sees it and moves it by key:
    // an OpenAI key → gpt-realtime-2.1-mini, a Gemini key and no OpenAI key → Gemini 3.8
    // Flash-Lite TTS, neither key → the macOS voice.
    #expect(TTSModel.migrateLegacyReadAloudRawValue("gemini-3.8-flash-tts") == "gemini-3.8-flash-tts")
    let stored = TTSModel.migrateLegacyReadAloudRawValue("gpt-4o-mini-tts")
    #expect(stored == "gpt-4o-mini-tts")
    let retired = try #require(TTSModel(rawValue: stored))
    #expect(
      ModelSelectionReconciler.retiredReadAloudReplacement(
        for: retired, hasKey: { $0 == .openai }) == .openAIRealtimeMiniTTS)
    #expect(
      ModelSelectionReconciler.retiredReadAloudReplacement(
        for: retired, hasKey: { $0 == .gemini }) == .gemini38FlashLiteTTS)
    #expect(
      ModelSelectionReconciler.retiredReadAloudReplacement(
        for: retired, hasKey: { _ in false }) == .systemMacOS)
  }
}

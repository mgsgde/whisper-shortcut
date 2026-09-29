import Testing
@testable import WhisperShortcut_AppStore

@Suite("Read Aloud model migration")
struct ReadAloudModelMigrationTests {

  @Test("Retired Gemini TTS slugs forward to 3.8 Flash-Lite TTS")
  func retiredGeminiTTSForward() {
    for raw in ["gemini-3.1-flash-tts-preview", "gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts"] {
      #expect(TTSModel.migrateLegacyReadAloudRawValue(raw) == TTSModel.gemini38FlashLiteTTS.rawValue)
    }
    // Current and non-Gemini selections are left alone.
    #expect(TTSModel.migrateLegacyReadAloudRawValue("gemini-3.8-flash-tts") == "gemini-3.8-flash-tts")
    #expect(TTSModel.migrateLegacyReadAloudRawValue("gpt-4o-mini-tts") == "gpt-4o-mini-tts")
  }

  @Test("Default is 3.8 Flash-Lite TTS and both 3.8 models are offered")
  func lineup() {
    #expect(SettingsDefaults.readAloudModel == .gemini38FlashLiteTTS)
    #expect(TTSModel.gemini38FlashLiteTTS.provider == .gemini)
    #expect(
      TTSModel.gemini38FlashTTS.apiEndpoint
        == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash-tts:streamGenerateContent?alt=sse")
  }
}

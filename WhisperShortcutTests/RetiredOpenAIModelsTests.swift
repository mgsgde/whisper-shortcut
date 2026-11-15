import Testing
@testable import WhisperShortcut_AppStore

@Suite("Retired OpenAI speech models")
@MainActor
struct RetiredOpenAIModelsTests {

  @Test("Stored gpt-4o-transcribe selections forward to gpt-transcribe")
  func gpt4oTranscribeForwards() {
    #expect(
      TranscriptionModel.migrateLegacyTranscriptionRawValue("openai-gpt-4o-transcribe")
        == "openai-gpt-transcribe")
  }

  @Test("gpt-4o-transcribe is hidden from dictation; the other OpenAI models stay")
  func gpt4oTranscribeHiddenFromDictation() {
    let selectable = TranscriptionModel.selectableForDictation(offlineMode: false)
    #expect(!selectable.contains(.openAIGPT4oTranscribe))
    #expect(selectable.contains(.openAIGPT4oMiniTranscribe))
    #expect(selectable.contains(.openAIGPTTranscribe))
  }

  @Test("gpt-4o-mini-tts is not offered for Read Aloud")
  func miniTTSHiddenFromReadAloud() {
    #expect(!TTSModel.readAloudModels.contains(.openAIGpt4oMiniTTS))
  }

  @Test("Retired Read Aloud moves to Gemini Flash-Lite TTS with a Gemini key, else the macOS voice")
  func retiredReadAloudReplacement() {
    func hasKey(_ keys: Set<String>) -> (TTSProvider) -> Bool {
      { provider in
        switch provider {
        case .gemini: return keys.contains("gemini")
        case .openai: return keys.contains("openai")
        case .xai: return keys.contains("xai")
        case .system, .localMLX, .custom: return false
        }
      }
    }
    #expect(
      ModelSelectionReconciler.retiredReadAloudReplacement(
        for: .openAIGpt4oMiniTTS, hasKey: hasKey(["gemini"])) == .gemini38FlashLiteTTS)
    #expect(
      ModelSelectionReconciler.retiredReadAloudReplacement(
        for: .openAIGpt4oMiniTTS, hasKey: hasKey(["openai"])) == .systemMacOS)
    #expect(
      ModelSelectionReconciler.retiredReadAloudReplacement(
        for: .openAIGpt4oMiniTTS, hasKey: hasKey([])) == .systemMacOS)
    #expect(
      ModelSelectionReconciler.retiredReadAloudReplacement(
        for: .grokVoiceTTS, hasKey: hasKey(["gemini"])) == nil)
  }

  @Test("A stored gpt-4o-mini-tts previous upgrades to Gemini Flash-Lite when both keys exist")
  func storedMiniTTSUpgradesToGemini() {
    let upgrade = ModelSelectionReconciler.readAloudUpgrade(previous: .openAIGpt4oMiniTTS) { provider in
      provider == .openai || provider == .gemini
    }
    #expect(upgrade == .gemini38FlashLiteTTS)
  }
}

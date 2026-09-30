import Testing
@testable import WhisperShortcut_AppStore

/// Decision helpers only — the Keychain / UserDefaults wiring stays out of this suite
/// so CI never touches the login Keychain.
/// `@MainActor` because `ModelSelectionReconciler` is — the helpers below are pure, but they
/// inherit the type's isolation.
@Suite("ModelSelectionReconciler (pure helpers)")
@MainActor
struct ModelSelectionReconcilerTests {

  private let chatCandidates: [PromptModel] = [
    .gemini37Flash, .openaiGPT6Sol, .grok43,
  ]

  @Test("Preferred prompt model follows Gemini → OpenAI → Grok")
  func preferredPromptFollowsProviderOrder() {
    #expect(
      ModelSelectionReconciler.preferredPromptModel(among: chatCandidates, hasKey: { $0 == .gemini })
        == .gemini37Flash)
    #expect(
      ModelSelectionReconciler.preferredPromptModel(among: chatCandidates, hasKey: { $0 == .openai })
        == .openaiGPT6Sol)
    #expect(
      ModelSelectionReconciler.preferredPromptModel(among: chatCandidates, hasKey: { $0 == .grok })
        == .grok43)

    // Gemini wins when more than one key is present.
    #expect(
      ModelSelectionReconciler.preferredPromptModel(
        among: chatCandidates,
        hasKey: { $0 == .gemini || $0 == .openai }
      ) == .gemini37Flash)
  }

  @Test("No key among the preferred providers yields no replacement")
  func preferredPromptIsNilWithoutAKey() {
    #expect(
      ModelSelectionReconciler.preferredPromptModel(among: chatCandidates, hasKey: { _ in false })
        == nil)
    // Anthropic is never a substitute — `providerPreference` does not include it.
    #expect(
      ModelSelectionReconciler.preferredPromptModel(among: chatCandidates, hasKey: { $0 == .anthropic })
        == nil)
  }

  @Test("Falls back to the first candidate of a keyed provider")
  func preferredPromptFallsBackToFirstCandidate() {
    // When the canonical default is in the list, prefer it even if it is not first.
    let withDefault: [PromptModel] = [.openaiGPT5Mini, .openaiGPT6Sol]
    #expect(
      ModelSelectionReconciler.preferredPromptModel(among: withDefault, hasKey: { $0 == .openai })
        == ChatModelProvider.openai.defaultChatModel)
    // When the canonical default is not in the list, take the first of that provider.
    let noDefault: [PromptModel] = [.openaiGPT5Mini]
    #expect(
      ModelSelectionReconciler.preferredPromptModel(among: noDefault, hasKey: { $0 == .openai })
        == .openaiGPT5Mini)
  }

  @Test("Key-less fallback picks the offline MLX default only when no cloud provider has a key")
  func keylessOfflineModelRule() {
    let offline = PromptModel.forLocalLLMModel(LocalLLMModelType.defaultModel)
    let candidates: [PromptModel] = chatCandidates + [.claudeOpus55, .localModel, offline]
    // No key anywhere: offline. The always-"keyed" local server must not count as a cloud key.
    #expect(
      ModelSelectionReconciler.keylessOfflineModel(
        among: candidates, hasKey: { $0 == .local || $0 == .localMLX }) == offline)
    // Any cloud key — including Anthropic, which `preferredPromptModel` never substitutes — wins.
    for provider: ChatModelProvider in [.gemini, .openai, .grok, .anthropic] {
      #expect(
        ModelSelectionReconciler.keylessOfflineModel(among: candidates, hasKey: { $0 == provider })
          == nil)
    }
    // Intel / no MLX in the list: nothing to fall back to.
    #expect(ModelSelectionReconciler.keylessOfflineModel(among: chatCandidates, hasKey: { _ in false }) == nil)
  }

  @Test("Key-less upgrade restores the previous pick, then the preferred default, then any keyed cloud model")
  func keylessUpgradeOrder() {
    let offline = PromptModel.forLocalLLMModel(LocalLLMModelType.defaultModel)
    let candidates: [PromptModel] = chatCandidates + [.gemini31Pro, .claudeOpus55, .localModel, offline]
    // A keychain read that failed at launch: the explicit pick comes back, not the provider default.
    #expect(
      ModelSelectionReconciler.keylessUpgrade(
        previous: .gemini31Pro, among: candidates, hasKey: { $0 == .gemini }) == .gemini31Pro)
    // Previous provider still keyless, another keyed: that provider's default.
    #expect(
      ModelSelectionReconciler.keylessUpgrade(
        previous: .gemini31Pro, among: candidates, hasKey: { $0 == .openai }) == .openaiGPT6Sol)
    // Anthropic is never a `providerPreference` substitute, but a Claude key still ends the fallback.
    #expect(
      ModelSelectionReconciler.keylessUpgrade(
        previous: nil, among: candidates, hasKey: { $0 == .anthropic }) == .claudeOpus55)
    // Still no cloud key (the local server does not count): stay.
    #expect(
      ModelSelectionReconciler.keylessUpgrade(
        previous: .gemini31Pro, among: candidates, hasKey: { $0 == .local || $0 == .localMLX }) == nil)
  }

  @Test("Transcription replacement maps each cloud provider and rejects the rest")
  func transcriptionReplacementTable() {
    #expect(
      ModelSelectionReconciler.transcriptionReplacement(for: .gemini)
        == .gemini31FlashLite)
    #expect(
      ModelSelectionReconciler.transcriptionReplacement(for: .openai)
        == .openAIGPTTranscribe)
    #expect(ModelSelectionReconciler.transcriptionReplacement(for: .grok) == .xaiTranscribe)
    for provider: ChatModelProvider in [.local, .localMLX, .customOpenAI, .anthropic] {
      #expect(ModelSelectionReconciler.transcriptionReplacement(for: provider) == nil)
    }
  }

  @Test("Offline transcription prefers a downloaded model, else the accuracy pick")
  func offlineTranscriptionReplacement() {
    #expect(
      ModelSelectionReconciler.offlineTranscriptionReplacement(downloaded: nil)
        == TranscriptionModel.forOfflineModel(OfflineModelType.mostAccurate))
    #expect(
      ModelSelectionReconciler.offlineTranscriptionReplacement(downloaded: .whisperBase)
        == TranscriptionModel.forOfflineModel(.whisperBase))
    #expect(
      ModelSelectionReconciler.offlineTranscriptionReplacement(downloaded: .whisperLargeTurbo)
        == TranscriptionModel.forOfflineModel(.whisperLargeTurbo))
  }
}

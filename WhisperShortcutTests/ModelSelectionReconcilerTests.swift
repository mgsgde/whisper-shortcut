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
    .gemini37Flash, .openaiGPT56Sol, .grok43,
  ]

  @Test("Preferred prompt model follows Gemini → OpenAI → Grok")
  func preferredPromptFollowsProviderOrder() {
    #expect(
      ModelSelectionReconciler.preferredPromptModel(among: chatCandidates, hasKey: { $0 == .gemini })
        == .gemini37Flash)
    #expect(
      ModelSelectionReconciler.preferredPromptModel(among: chatCandidates, hasKey: { $0 == .openai })
        == .openaiGPT56Sol)
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
    let withDefault: [PromptModel] = [.openaiGPT5Mini, .openaiGPT56Sol]
    #expect(
      ModelSelectionReconciler.preferredPromptModel(among: withDefault, hasKey: { $0 == .openai })
        == ChatModelProvider.openai.defaultChatModel)
    // When the canonical default is not in the list, take the first of that provider.
    let noDefault: [PromptModel] = [.openaiGPT5Mini]
    #expect(
      ModelSelectionReconciler.preferredPromptModel(among: noDefault, hasKey: { $0 == .openai })
        == .openaiGPT5Mini)
  }

  @Test("Transcription replacement maps each cloud provider and rejects the rest")
  func transcriptionReplacementTable() {
    #expect(
      ModelSelectionReconciler.transcriptionReplacement(for: .gemini)
        == SettingsDefaults.selectedTranscriptionModel)
    #expect(
      ModelSelectionReconciler.transcriptionReplacement(for: .openai)
        == .openAIGPT4oMiniTranscribe)
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

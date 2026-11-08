import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Locks the two facts that used to be written in several places at once.
///
/// `ChatModelProvider.credentialRequirement` is now the only per-provider credential switch, and
/// `TranscriptionModel.apiEndpoint` is a template over `TranscriptionProvider.fixedEndpoint`
/// instead of a hand-maintained URL per Gemini model. Both collapses are only safe if they produce
/// exactly what the copies produced, so that equivalence is asserted rather than eyeballed.
@Suite("Provider credential and endpoint facts")
struct ProviderCredentialFactsTests {

  // MARK: - Endpoints (R23)

  /// The literal URLs the five per-model `case` arms used to return. If the template ever stops
  /// reproducing these byte for byte, transcription silently 404s against a wrong model path.
  private static let expectedEndpoints: [TranscriptionModel: String] = [
    .gemini31Pro:
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro-preview:generateContent",
    .gemini31FlashLite:
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent",
    .gemini35FlashLite:
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent",
    .gemini4Argon:
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-argon:generateContent",
    .gemini38Flash:
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent",
  ]

  @Test("Endpoints are unchanged: Gemini exact URLs, cloud providers fixed, offline and self-hosted empty")
  func endpointsUnchanged() {
    for (model, expected) in Self.expectedEndpoints {
      #expect(model.apiEndpoint == expected, "\(model.rawValue) endpoint drifted")
    }
    #expect(TranscriptionModel.openAIGPTTranscribe.apiEndpoint == AppConstants.openAITranscriptionsEndpoint)
    #expect(TranscriptionModel.openAIGPT4oTranscribe.apiEndpoint == AppConstants.openAITranscriptionsEndpoint)
    #expect(TranscriptionModel.openAIGPT4oMiniTranscribe.apiEndpoint == AppConstants.openAITranscriptionsEndpoint)
    #expect(TranscriptionModel.xaiTranscribe.apiEndpoint == AppConstants.xaiSTTEndpoint)
    #expect(TranscriptionModel.openRouterTranscription.apiEndpoint == AppConstants.openRouterChatCompletionsEndpoint)
    // Offline runs locally; the self-hosted URL comes from Settings, not from the model.
    #expect(TranscriptionModel.selfHostedTranscription.apiEndpoint.isEmpty)
    for model in TranscriptionModel.allCases where model.provider == .offline {
      #expect(model.apiEndpoint.isEmpty, "\(model.rawValue) must not carry an endpoint")
    }
  }

  // MARK: - Chat credentials (R26)

  /// The "you have no keys at all" warning must not be silenced by a provider the user never had to
  /// configure — otherwise a fresh install with a reachable local server would look set up.
  @Test("Local needs nothing; endpoint-configured and credential-free providers cannot satisfy the any-key check")
  func credentialFreeProviders() {
    #expect(ChatModelProvider.local.hasCredential)
    #expect(!ChatModelProvider.local.requiresUserSuppliedCredential)
    #expect(ChatModelProvider.local.credentialRequiredMessage.isEmpty)
    #expect(!ChatModelProvider.customOpenAI.requiresUserSuppliedCredential)
    let keyed = ChatModelProvider.allCases.filter { $0.requiresUserSuppliedCredential }
    #expect(Set(keyed) == Set([.gemini, .openai, .grok, .anthropic, .openRouter]))
  }

  @Test("Keyed providers report configured exactly when a non-empty key is stored")
  func keyedProvidersTrackTheKeychain() {
    let pairs: [(ChatModelProvider, KeychainCredential)] = [
      (.openai, .openAI), (.grok, .xai), (.anthropic, .anthropic), (.openRouter, .openRouter),
    ]
    for (provider, credential) in pairs {
      #expect(
        provider.hasCredential == KeychainManager.shared.hasNonEmpty(credential),
        "\(provider.rawValue) disagrees with the Keychain")
    }
  }

  /// `ProviderCredentials.Kind.storedKey` reads `KeychainManager.shared`, so a test cannot plant a
  /// whitespace-only key without touching the real keychain. Agreement still locks the mapping:
  /// every feature presence check is the provider's `hasCredential` (which trims key kinds).
  @MainActor
  @Test("Prompt, TTS, transcription and the reconciler agree with hasCredential")
  func featurePresenceAgreesWithProviderCredential() {
    for model in PromptModel.allCases {
      #expect(model.hasRequiredCredential == model.provider.hasCredential, "\(model.rawValue)")
      if model.provider == .openai {
        #expect(model.hasRequiredCredentialForDictatePrompt == ProviderCredentials.hasKey(.openAI))
      } else {
        #expect(
          model.hasRequiredCredentialForDictatePrompt == model.hasRequiredCredential,
          "\(model.rawValue)")
      }
    }
    for model in TTSModel.allCases {
      // `.localMLX` is the one provider with two models under one key: VoiceDesign and
      // CustomVoice are separate downloads, so "can this model run" is per checkpoint while
      // `provider.hasCredential` answers "is either of them on disk". A user with only one
      // downloaded is the normal case, not a disagreement.
      if model.qwen3ModelType != nil {
        #expect(
          model.hasRequiredCredential == Qwen3ModelManager.shared.isModelAvailable(model.qwen3ModelType!),
          "\(model.rawValue)")
      } else {
        #expect(model.hasRequiredCredential == model.provider.hasCredential, "\(model.rawValue)")
      }
    }
    #expect(TTSProvider.gemini.hasCredential == ChatModelProvider.gemini.hasCredential)
    #expect(TTSProvider.openai.hasCredential == ChatModelProvider.openai.hasCredential)
    #expect(TTSProvider.xai.hasCredential == ChatModelProvider.grok.hasCredential)
    #expect(TTSProvider.system.hasCredential)
    #expect(TranscriptionProvider.openAI.hasCredential == ChatModelProvider.openai.hasCredential)
    #expect(TranscriptionProvider.xai.hasCredential == ChatModelProvider.grok.hasCredential)
    #expect(TranscriptionProvider.openRouter.hasCredential == ChatModelProvider.openRouter.hasCredential)
    #expect(TranscriptionProvider.google.hasCredential == ChatModelProvider.gemini.hasCredential)
    #expect(!TranscriptionProvider.offline.hasCredential)
    for provider in ChatModelProvider.allCases {
      #expect(ModelSelectionReconciler.hasKey(provider) == provider.hasCredential, "\(provider.rawValue)")
    }
  }
}

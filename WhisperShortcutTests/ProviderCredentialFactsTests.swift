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
    .gemini35Flash:
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent",
    .gemini36Flash:
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent",
    .gemini37Flash:
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.7-flash:generateContent",
  ]

  @Test("Gemini endpoints still resolve to the exact URLs the per-model switch returned")
  func geminiEndpointsUnchanged() {
    for (model, expected) in Self.expectedEndpoints {
      #expect(model.apiEndpoint == expected, "\(model.rawValue) endpoint drifted")
    }
  }

  @Test("Cloud providers keep their fixed endpoints; offline and self-hosted stay empty")
  func nonGeminiEndpointsUnchanged() {
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

  @Test("Only Google defers its endpoint to the model")
  func onlyGoogleHasNoFixedEndpoint() {
    for provider in TranscriptionProvider.allCases {
      if provider == .google {
        #expect(provider.fixedEndpoint == nil)
      } else {
        #expect(provider.fixedEndpoint != nil, "\(provider.rawValue) must declare a fixed endpoint")
      }
    }
  }

  // MARK: - Chat credentials (R26)

  @Test("Every provider that needs a credential explains where to put it")
  func credentialMessagesAreActionable() {
    for provider in ChatModelProvider.allCases where provider.requiresUserSuppliedCredential {
      let message = provider.credentialRequiredMessage
      #expect(!message.isEmpty, "\(provider.rawValue) has no message")
      // The whole point of unifying on the ProviderCredentials wording: the old ChatView copies
      // said "in Settings" without naming the tab, which is where the key field actually is.
      #expect(
        message.contains("Settings → General") || message.contains("Settings → Chat"),
        "\(provider.rawValue) message does not name the Settings tab: \(message)")
    }
  }

  @Test("Local needs nothing and is always considered configured")
  func localNeedsNoCredential() {
    #expect(ChatModelProvider.local.hasCredential)
    #expect(!ChatModelProvider.local.requiresUserSuppliedCredential)
    #expect(ChatModelProvider.local.credentialRequiredMessage.isEmpty)
  }

  /// The "you have no keys at all" warning must not be silenced by a provider the user never had to
  /// configure — otherwise a fresh install with a reachable local server would look set up.
  @Test("Endpoint-configured and credential-free providers cannot satisfy the any-key check")
  func anyKeyCheckIgnoresNonKeyedProviders() {
    #expect(!ChatModelProvider.local.requiresUserSuppliedCredential)
    #expect(!ChatModelProvider.customOpenAI.requiresUserSuppliedCredential)
    let keyed = ChatModelProvider.allCases.filter { $0.requiresUserSuppliedCredential }
    #expect(Set(keyed) == Set([.gemini, .openai, .grok, .anthropic]))
  }

  /// `hasCredential` must agree with the Keychain check the request path itself performs, or the
  /// UI enables a send that then fails on a missing key.
  @Test("Keyed providers report configured exactly when a non-empty key is stored")
  func keyedProvidersTrackTheKeychain() {
    let pairs: [(ChatModelProvider, KeychainCredential)] = [
      (.openai, .openAI), (.grok, .xai), (.anthropic, .anthropic),
    ]
    for (provider, credential) in pairs {
      #expect(
        provider.hasCredential == KeychainManager.shared.hasNonEmpty(credential),
        "\(provider.rawValue) disagrees with the Keychain")
    }
  }
}

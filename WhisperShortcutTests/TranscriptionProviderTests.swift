import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins the model → provider mapping that the Dictate grid groups by.
///
/// Adding a case to `TranscriptionModel` breaks the `provider` switch at compile time, which is the
/// protection that matters. What compiles fine is a *wrong* assignment — a new router landing in
/// `.direct` would silently reintroduce exactly the confusion the grouping exists to remove, so the
/// group membership is asserted explicitly rather than derived.
@Suite("Transcription provider")
struct TranscriptionProviderTests {

  @Test("Gemini 3.1 Pro is never offered as a dictation choice, and persisted picks migrate away")
  func proIsNotSelectableForDictation() {
    // It returns nothing at all for short audio (2026-08-03 measurement; see isSelectableForDictation),
    // and the app waits 300 s before giving up — so it must not reach a picker.
    #expect(!TranscriptionModel.gemini31Pro.isSelectableForDictation)
    #expect(!TranscriptionModel.selectableForDictation.contains(.gemini31Pro))

    // Everything else stays offerable; this is a one-model exclusion, not a category.
    #expect(TranscriptionModel.selectableForDictation.count == TranscriptionModel.allCases.count - 1)

    // Both Pro slugs land on the working default, so no one is left stuck on it.
    for slug in ["gemini-3.1-pro-preview", "gemini-3-pro-preview"] {
      #expect(
        TranscriptionModel.migrateLegacyTranscriptionRawValue(slug)
          == TranscriptionModel.gemini31FlashLite.rawValue, "\(slug)")
    }

    // The case itself must stay: PromptModel.asTranscriptionModel resolves the Gemini endpoint
    // through it for Dictate Prompt and Smart Improvement.
    #expect(PromptModel.gemini31Pro.asTranscriptionModel == .gemini31Pro)
    #expect(TranscriptionModel.gemini31Pro.apiEndpoint.contains("gemini-3.1-pro-preview"))
  }

  @Test("Routed contains exactly the entries that are not themselves models")
  func routedGroupHoldsOnlyRouters() {
    let routed = Set(
      TranscriptionModel.allCases
        .filter { $0.provider.group == .routed })

    #expect(routed == [.openRouterTranscription, .selfHostedTranscription])
  }

  @Test("Direct models map to their own vendor")
  func directModelsMapToVendors() {
    #expect(TranscriptionModel.gemini36Flash.provider == .google)
    #expect(TranscriptionModel.gemini31Pro.provider == .google)
    #expect(TranscriptionModel.openAIGPTTranscribe.provider == .openAI)
    #expect(TranscriptionModel.openAIGPT4oMiniTranscribe.provider == .openAI)
    #expect(TranscriptionModel.xaiTranscribe.provider == .xai)

    for model in [TranscriptionModel.gemini36Flash, .openAIGPTTranscribe, .xaiTranscribe] {
      #expect(model.provider.group == .direct, "\(model.rawValue)")
    }
  }

  @Test("Every Whisper model is offline, and nothing else is")
  func offlineGroupIsWhisperOnly() {
    let offline = Set(TranscriptionModel.allCases.filter { $0.provider == .offline })
    #expect(
      offline == [
        .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge, .whisperLargeTurbo,
      ])

    for model in offline {
      #expect(model.provider.group == .offline, "\(model.rawValue)")
    }
  }

  /// The four booleans used to be independent switches; they are now views onto `provider`. This
  /// guards the collapse — call sites across 23 files still read them.
  @Test("The legacy provider booleans still agree with the axis")
  func legacyBooleansAgreeWithProvider() {
    for model in TranscriptionModel.allCases {
      #expect(model.isGemini == (model.provider == .google), "\(model.rawValue)")
      #expect(model.isOpenAI == (model.provider == .openAI), "\(model.rawValue)")
      #expect(model.isXAI == (model.provider == .xai), "\(model.rawValue)")
      #expect(model.isOffline == (model.provider == .offline), "\(model.rawValue)")
    }
  }

  /// `.offline` deliberately returns false from the provider-level check because availability is
  /// per downloaded file — `TranscriptionModel.hasRequiredCredential` special-cases it. If that
  /// special case is ever dropped, every Whisper model silently becomes unselectable.
  @Test("Offline credential checks stay per model, not per provider")
  func offlineCredentialIsPerModel() {
    #expect(TranscriptionProvider.offline.hasCredential == false)
    #expect(
      TranscriptionModel.whisperBase.hasRequiredCredential
        == TranscriptionModel.whisperBase.isOfflineModelAvailable())
  }

  @Test("Credential prompts never tell a keyless provider to add an API key")
  func credentialTitlesMatchWhatIsActuallyNeeded() {
    #expect(TranscriptionProvider.offline.credentialRequiredTitle == "Model Not Downloaded")
    #expect(TranscriptionProvider.selfHosted.credentialRequiredTitle == "Endpoint Not Configured")

    for provider in [TranscriptionProvider.google, .openAI, .xai, .openRouter] {
      #expect(provider.credentialRequiredTitle == "API Key Required", "\(provider.rawValue)")
    }
  }

  @Test("Only models that act on the dictation prompt claim to, and gpt-transcribe says so")
  func systemPromptApplicabilityIsHonest() {
    // The Settings editor shows one "System prompt" for every model. Two families drop it, and
    // until 2026-08-27 the editor's subtitle named "OpenAI Transcribe" among the models that use
    // it — so anyone dictating with gpt-transcribe kept every filler word while the UI promised
    // they would be removed. Pinned here because the fix lives in a subtitle string, which nothing
    // else would catch.
    #expect(!TranscriptionModel.openAIGPTTranscribe.honorsSystemPrompt)
    for offline in [TranscriptionModel.whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge] {
      #expect(!offline.honorsSystemPrompt, "\(offline.rawValue)")
    }

    // The instructable ones must keep honouring it — this is a two-model-family exception, not a
    // general disclaimer.
    for instructable in [TranscriptionModel.gemini31FlashLite, .gemini35Flash, .gemini37Flash,
                         .openAIGPT4oTranscribe, .openAIGPT4oMiniTranscribe, .xaiTranscribe,
                         .openRouterTranscription, .selfHostedTranscription] {
      #expect(instructable.honorsSystemPrompt, "\(instructable.rawValue)")
    }

    // A reason exists exactly when the prompt is dropped, so the banner can never render empty or
    // be silently skipped for a model that needs it.
    for model in TranscriptionModel.allCases {
      #expect((model.systemPromptIgnoredReason != nil) == !model.honorsSystemPrompt, "\(model.rawValue)")
    }

    // The wire-level switch in SpeechService keys off this id; if the raw value ever moves, the
    // request builder and this property stop agreeing and the UI starts lying again.
    #expect(TranscriptionModel.openAIGPTTranscribe.openAIAPIModelID == "gpt-transcribe")
  }

}

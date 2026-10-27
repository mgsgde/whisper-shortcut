import Foundation

/// Who actually runs a transcription, and what it takes to reach them.
///
/// `TranscriptionModel` is a flat list that mixes three different things: real models
/// (`gemini-3.6-flash`), a transport (`selfHostedTranscription`), and a router
/// (`openRouterTranscription`). The provider axis was already there before this type existed — it
/// was just written out by hand as `isGemini` / `isOpenAI` / `isXAI` / `isOffline` plus `==` checks
/// against the two odd cases, repeated in `hasRequiredCredential`, `credentialRequiredTitle` and
/// `apiKeyRequiredMessage`. Three copies that had to agree, and nothing made them.
///
/// This type is **derived**, not persisted: `TranscriptionModel` still owns the stored raw value.
/// That keeps the split free of a settings migration while giving the code and the UI one place to
/// ask "which provider is this, and what does it need?".
enum TranscriptionProvider: String, CaseIterable {
  case google
  case openAI
  case xai
  case openRouter
  case selfHosted
  case offline

  /// How the model picker groups providers.
  ///
  /// The distinction users kept tripping over is `direct` vs `routed`: Gemini 3.5 Flash-Lite is a
  /// tile in the grid *and* an entry in OpenRouter's own model list, and nothing said that one is
  /// "billed to my Google key" and the other "billed to my OpenRouter balance".
  enum Group {
    /// Talk to the model vendor with that vendor's key.
    case direct
    /// Reach models through something the user configures — a router account or their own server.
    case routed
    /// Runs on this Mac.
    case offline
  }

  var group: Group {
    switch self {
    case .google, .openAI, .xai: return .direct
    case .openRouter, .selfHosted: return .routed
    case .offline: return .offline
    }
  }

  var displayName: String {
    switch self {
    case .google: return "Google Gemini"
    case .openAI: return "OpenAI"
    case .xai: return "xAI (Grok)"
    case .openRouter: return "OpenRouter"
    case .selfHosted: return String(localized: "Self-hosted")
    case .offline: return String(localized: "On-device")
    }
  }

  /// Whether the user currently has what this provider needs.
  ///
  /// OpenAI, xAI and OpenRouter go through `ProviderCredentials.hasKey` so a whitespace-only key
  /// is missing here as well as in `verifyConfigured`. Gemini stays on `GeminiCredentialProvider`;
  /// self-hosted is a non-empty endpoint URL; offline availability is per downloaded file.
  var hasCredential: Bool {
    switch self {
    case .google:
      return GeminiCredentialProvider.shared.hasCredential()
    case .openAI:
      return ProviderCredentials.hasKey(.openAI)
    case .xai:
      return ProviderCredentials.hasKey(.xAI)
    case .openRouter:
      return ProviderCredentials.hasKey(.openRouter)
    case .selfHosted:
      let url = UserDefaults.standard.string(forKey: UserDefaultsKeys.customTranscriptionAPIURL)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return !url.isEmpty
    case .offline:
      // Availability is per downloaded model file, so only `TranscriptionModel` can answer this.
      return false
    }
  }

  /// Popup title matching `credentialRequiredMessage`.
  ///
  /// Offline and self-hosted need no API key, so titling their popup "API Key Required" used to
  /// contradict its own body and sent users hunting for a key that would not have helped.
  var credentialRequiredTitle: String {
    switch self {
    case .offline: return String(localized: "Model Not Downloaded")
    case .selfHosted: return String(localized: "Endpoint Not Configured")
    case .google, .openAI, .xai, .openRouter: return String(localized: "API Key Required")
    }
  }

  /// Where a transcription request for this provider goes.
  ///
  /// Google is the exception and returns nil: its URL embeds the model id, so only the model can
  /// finish it (see `TranscriptionModel.apiEndpoint`). Offline and self-hosted have no fixed
  /// endpoint — one runs locally, the other is whatever URL the user configured.
  var fixedEndpoint: String? {
    switch self {
    case .google: return nil
    case .openAI: return AppConstants.openAITranscriptionsEndpoint
    case .xai: return AppConstants.xaiSTTEndpoint
    case .openRouter: return AppConstants.openRouterChatCompletionsEndpoint
    case .selfHosted, .offline: return ""
    }
  }

  /// Actionable message shown when this provider can't run for lack of a credential.
  var credentialRequiredMessage: String {
    switch self {
    case .google:
      return String(localized: "Add your Gemini API key in Settings → Accounts to use dictation. For offline use, download an offline model in Settings → Dictate.")
    case .openAI:
      return String(localized: "Add your OpenAI API key in Settings → Accounts to use dictation, or pick a different transcription model in Settings → Dictate.")
    case .xai:
      return String(localized: "Add your xAI API key in Settings → Accounts to use dictation, or pick a different transcription model in Settings → Dictate.")
    case .openRouter:
      return String(localized: "Connect your OpenRouter account in Settings → Accounts to transcribe through OpenRouter, or pick a different model.")
    case .selfHosted:
      return String(localized: "Configure your self-hosted transcription endpoint in Dictate settings, or pick a different model.")
    case .offline:
      return String(localized: "Download the selected offline model in Settings → Dictate, or pick a different transcription model.")
    }
  }
}

// MARK: - TranscriptionModel → provider

extension TranscriptionModel {
  var provider: TranscriptionProvider {
    switch self {
    case .gemini4Argon, .gemini31Pro, .gemini31FlashLite, .gemini35FlashLite,
         .gemini38Flash:
      return .google
    case .openAIGPTTranscribe, .openAIGPT4oTranscribe, .openAIGPT4oMiniTranscribe:
      return .openAI
    case .xaiTranscribe:
      return .xai
    case .openRouterTranscription:
      return .openRouter
    case .selfHostedTranscription:
      return .selfHosted
    case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge,
         .whisperLargeTurbo, .parakeetUltra:
      return .offline
    }
  }
}

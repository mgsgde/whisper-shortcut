import Foundation

/// Keeps per-feature model selections consistent with the API keys the user actually has.
///
/// The factory defaults point at Gemini, but a user might provide only an OpenAI or only an xAI
/// key. This reconciler rewrites any persisted selection whose provider has no key to a model of a
/// provider the user *does* have a key for — so a single API key is enough to use every feature
/// (transcription, dictate prompt, chat, meeting summary, smart improvement, read aloud).
///
/// It never changes a selection whose provider already has a key, so explicit choices made when
/// multiple keys are present are preserved. Offline Whisper and self-hosted transcription need no
/// key and are left untouched.
///
/// Run it at launch, after an API key is entered, and when settings load.
enum ModelSelectionReconciler {

  // MARK: - Key availability

  static func hasKey(_ provider: ChatModelProvider) -> Bool {
    switch provider {
    case .gemini: return GeminiCredentialProvider.shared.hasCredential()
    case .openai: return KeychainManager.shared.hasValidOpenAIAPIKey()
    case .grok: return KeychainManager.shared.hasValidXAIAPIKey()
    // Local server needs no key — treat as "always available" so a user's explicit local
    // selection is never reconciled away.
    case .local: return true
    }
  }

  private static func hasKey(_ provider: TTSProvider) -> Bool {
    switch provider {
    case .gemini: return GeminiCredentialProvider.shared.hasCredential()
    case .openai: return KeychainManager.shared.hasValidOpenAIAPIKey()
    case .xai: return KeychainManager.shared.hasValidXAIAPIKey()
    }
  }

  /// Substitute-provider preference, consulted only when the current selection's provider has no
  /// key. Gemini first (it's the app's primary backend), then OpenAI, then xAI.
  private static let providerPreference: [ChatModelProvider] = [.gemini, .openai, .grok]

  // MARK: - Entry point

  static func reconcileAll() {
    reconcilePromptSelection(key: UserDefaultsKeys.selectedChatModel,
                             candidates: PromptModel.chatModels,
                             fallback: SettingsDefaults.selectedChatModel)
    reconcilePromptSelection(key: UserDefaultsKeys.selectedPromptModel,
                             candidates: PromptModel.dictatePromptCapableModels,
                             fallback: SettingsDefaults.selectedPromptModel)
    reconcilePromptSelection(key: UserDefaultsKeys.selectedImprovementModel,
                             candidates: PromptModel.chatModels,
                             fallback: SettingsDefaults.selectedImprovementModel)
    reconcilePromptSelection(key: UserDefaultsKeys.selectedMeetingSummaryModel,
                             candidates: PromptModel.chatModels,
                             fallback: SettingsDefaults.selectedMeetingSummaryModel)
    reconcileReadAloud()
    reconcileTranscription(key: UserDefaultsKeys.selectedTranscriptionModel,
                           fallback: SettingsDefaults.selectedTranscriptionModel)
    reconcileTranscription(key: UserDefaultsKeys.selectedTranscriptionModelForMeetings,
                           fallback: SettingsDefaults.selectedTranscriptionModel)
  }

  // MARK: - PromptModel-backed features (chat, dictate prompt, improvement, meeting summary)

  private static func reconcilePromptSelection(key: String, candidates: [PromptModel], fallback: PromptModel) {
    let raw = UserDefaults.standard.string(forKey: key) ?? fallback.rawValue
    let current = PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(raw)) ?? fallback
    if hasKey(current.provider) { return }
    guard let replacement = preferredPromptModel(among: candidates) else { return }
    UserDefaults.standard.set(replacement.rawValue, forKey: key)
    DebugLogger.log("MODEL-RECONCILE: \(key): \(current.rawValue) → \(replacement.rawValue) (no key for \(current.provider))")
  }

  private static func preferredPromptModel(among candidates: [PromptModel]) -> PromptModel? {
    for provider in providerPreference where hasKey(provider) {
      // Prefer the provider's canonical default if the feature allows it, else its first candidate.
      if candidates.contains(provider.defaultChatModel) { return provider.defaultChatModel }
      if let first = candidates.first(where: { $0.provider == provider }) { return first }
    }
    return nil
  }

  // MARK: - Read Aloud (TTSModel)

  private static func reconcileReadAloud() {
    let key = UserDefaultsKeys.selectedReadAloudModel
    let raw = UserDefaults.standard.string(forKey: key) ?? SettingsDefaults.readAloudModel.rawValue
    let current = TTSModel(rawValue: TTSModel.migrateLegacyReadAloudRawValue(raw)) ?? SettingsDefaults.readAloudModel
    if hasKey(current.provider) { return }
    guard let replacement = TTSModel.readAloudModels.first(where: { hasKey($0.provider) }) else { return }
    UserDefaults.standard.set(replacement.rawValue, forKey: key)
    DebugLogger.log("MODEL-RECONCILE: \(key): \(current.rawValue) → \(replacement.rawValue)")
  }

  // MARK: - Transcription (TranscriptionModel)

  private static func reconcileTranscription(key: String, fallback: TranscriptionModel) {
    let raw = UserDefaults.standard.string(forKey: key) ?? fallback.rawValue
    let current = TranscriptionModel(rawValue: TranscriptionModel.migrateLegacyTranscriptionRawValue(raw)) ?? fallback
    // Offline Whisper and self-hosted endpoints need no provider key — leave those selections alone.
    guard current.isGemini || current.isOpenAI || current.isXAI else { return }
    let currentProvider: ChatModelProvider = current.isGemini ? .gemini : (current.isOpenAI ? .openai : .grok)
    if hasKey(currentProvider) { return }
    guard let provider = providerPreference.first(where: { hasKey($0) }) else { return }
    let replacement: TranscriptionModel
    switch provider {
    case .gemini: replacement = .gemini31FlashLite
    case .openai: replacement = .openAIGPT4oMiniTranscribe
    case .grok: replacement = .xaiTranscribe
    // `providerPreference` never includes `.local`, so this is unreachable; leave the
    // transcription selection untouched rather than substitute a non-transcription model.
    case .local: return
    }
    UserDefaults.standard.set(replacement.rawValue, forKey: key)
    DebugLogger.log("MODEL-RECONCILE: \(key): \(current.rawValue) → \(replacement.rawValue)")
  }
}

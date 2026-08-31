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
    case .openai: return KeychainManager.shared.hasNonEmpty(.openAI)
    case .customOpenAI: return OpenAIChatPreferences.isConfigured
    case .grok: return KeychainManager.shared.hasNonEmpty(.xai)
    case .anthropic: return KeychainManager.shared.hasNonEmpty(.anthropic)
    // Local server needs no key — treat as "always available" so a user's explicit local
    // selection is never reconciled away.
    case .local: return true
    }
  }

  private static func hasKey(_ provider: TTSProvider) -> Bool {
    switch provider {
    case .gemini: return GeminiCredentialProvider.shared.hasCredential()
    case .openai: return KeychainManager.shared.hasNonEmpty(.openAI)
    case .xai: return KeychainManager.shared.hasNonEmpty(.xai)
    }
  }

  /// Substitute-provider preference, consulted only when the current selection's provider has no
  /// key. Gemini first (it's the app's primary backend), then OpenAI, then xAI.
  private static let providerPreference: [ChatModelProvider] = [.gemini, .openai, .grok]

  // MARK: - Entry point

  static func reconcileAll() {
    // Offline Mode inverts this type's job: instead of following the keys the user has, the
    // selections that can run locally are pulled back onto this Mac. Without it the reconciler
    // actively fights the mode — an OpenAI key entered for something else is enough for it to
    // rewrite dictation to a cloud model, the exact failure the mode exists to make impossible.
    if OfflineMode.isEnabled {
      reconcileForOfflineMode()
      return
    }
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

  // MARK: - Offline Mode

  /// Moves the selections that *have* an on-device equivalent — dictation, meeting transcription,
  /// Dictate Prompt — onto this Mac. Read Aloud, Chat, meeting summary and Smart Improvement are
  /// deliberately left alone: nothing in this build runs them locally, so there is nothing to move
  /// them to. They stay selected and fail at the network guard, which is the honest outcome.
  private static func reconcileForOfflineMode() {
    for key in [
      UserDefaultsKeys.selectedTranscriptionModel,
      UserDefaultsKeys.selectedTranscriptionModelForMeetings,
    ] {
      let raw = UserDefaults.standard.string(forKey: key)
        ?? SettingsDefaults.selectedTranscriptionModel.rawValue
      let current = TranscriptionModel(rawValue: TranscriptionModel.migrateLegacyTranscriptionRawValue(raw))
        ?? SettingsDefaults.selectedTranscriptionModel
      guard !current.runsOnThisMac else { continue }
      let replacement = offlineTranscriptionReplacement()
      UserDefaults.standard.set(replacement.rawValue, forKey: key)
      DebugLogger.log(
        "MODEL-RECONCILE: \(key): \(current.rawValue) → \(replacement.rawValue) (Offline Mode)")
    }

    // Only Dictate Prompt is moved. Chat, meeting summary and Smart Improvement have no on-device
    // model in this build (the local model is wired for Dictate Prompt only), so there is nothing
    // to move them to — like Read Aloud, they stay selected and fail at the guard.
    let promptKey = UserDefaultsKeys.selectedPromptModel
    let raw = UserDefaults.standard.string(forKey: promptKey) ?? SettingsDefaults.selectedPromptModel.rawValue
    let current = PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(raw))
      ?? SettingsDefaults.selectedPromptModel
    // A custom OpenAI-compatible endpoint may already point at the user's own server; the network
    // guard is what decides, so leave that choice alone.
    guard current.provider != .local, current.provider != .customOpenAI else { return }
    UserDefaults.standard.set(PromptModel.localModel.rawValue, forKey: promptKey)
    DebugLogger.log(
      "MODEL-RECONCILE: \(promptKey): \(current.rawValue) → \(PromptModel.localModel.rawValue) (Offline Mode)")
  }

  /// The best on-device model the user has actually downloaded, or the accuracy pick if none is —
  /// pointing at a model that still needs downloading is a solvable dead end (Settings offers the
  /// button), whereas silently selecting Tiny would quietly degrade every transcript.
  private static func offlineTranscriptionReplacement() -> TranscriptionModel {
    let downloaded = OfflineModelType.byAccuracy.last { ModelManager.shared.isModelAvailable($0) }
    return TranscriptionModel.forOfflineModel(downloaded ?? OfflineModelType.mostAccurate)
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
    // Offline Whisper and self-hosted endpoints need no provider key — leave those selections
    // alone, unconditionally.
    //
    // There used to be an exception here: an offline model that was not downloaded yet was
    // treated as a dead end and replaced with a cloud model as soon as any API key existed. That
    // turned "I chose on-device Whisper" into "my audio goes to OpenAI" without a word to the
    // user — observed on 2026-08-31, where three dictations after a failed offline attempt were
    // silently transcribed by GPT Transcribe. A missing model is no longer a dead end either:
    // selecting one downloads it, and dictating waits for it (`ModelManager.ensureReady`).
    guard current.isGemini || current.isOpenAI || current.isXAI else { return }
    let currentProvider: ChatModelProvider = current.isGemini ? .gemini : (current.isOpenAI ? .openai : .grok)
    if hasKey(currentProvider) { return }
    replaceTranscriptionSelection(key: key, current: current)
  }

  private static func replaceTranscriptionSelection(key: String, current: TranscriptionModel) {
    guard let provider = providerPreference.first(where: { hasKey($0) }) else { return }
    let replacement: TranscriptionModel
    switch provider {
    case .gemini: replacement = SettingsDefaults.selectedTranscriptionModel
    case .openai: replacement = .openAIGPT4oMiniTranscribe
    case .grok: replacement = .xaiTranscribe
    // `providerPreference` never includes these; Anthropic has no transcription models here.
    case .local, .customOpenAI, .anthropic: return
    }
    UserDefaults.standard.set(replacement.rawValue, forKey: key)
    DebugLogger.log("MODEL-RECONCILE: \(key): \(current.rawValue) → \(replacement.rawValue)")
  }
}

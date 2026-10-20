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
/// `@MainActor` because every caller already is — the app delegate's startup path, the settings
/// view model, the onboarding window — and because reconciling now has to ask
/// `LocalLLMModelManager` which models are on disk. Reaching that state from a nonisolated static
/// was the kind of access the compiler only started rejecting once the manager gained isolation.
@MainActor
enum ModelSelectionReconciler {

  // MARK: - Key availability

  static func hasKey(_ provider: ChatModelProvider) -> Bool {
    switch provider {
    case .gemini: return GeminiCredentialProvider.shared.hasCredential()
    case .openai: return KeychainManager.shared.hasNonEmpty(.openAI)
    case .customOpenAI: return OpenAIChatPreferences.isConfigured
    case .openRouter: return OpenRouterChatPreferences.isConfigured
    case .grok: return KeychainManager.shared.hasNonEmpty(.xai)
    case .anthropic: return KeychainManager.shared.hasNonEmpty(.anthropic)
    // Local server and in-process MLX need no key — treat as "always available" so a user's explicit local
    // selection is never reconciled away.
    case .local, .localMLX: return true
    }
  }

  private static func hasKey(_ provider: TTSProvider) -> Bool {
    switch provider {
    case .gemini: return GeminiCredentialProvider.shared.hasCredential()
    case .openai: return KeychainManager.shared.hasNonEmpty(.openAI)
    case .xai: return KeychainManager.shared.hasNonEmpty(.xai)
    case .system: return true
    }
  }

  /// Substitute-provider preference, consulted only when the current selection's provider has no
  /// key. Gemini first (it's the app's primary backend), then OpenAI, then xAI, then OpenRouter —
  /// last because it is the one account that can stand in for all of them, so someone who connected
  /// only OpenRouter during onboarding gets a working Chat instead of a Gemini slot with no key.
  /// OpenRouter has no transcription stand-in here (`transcriptionReplacement` returns nil).
  nonisolated static let providerPreference: [ChatModelProvider] = [.gemini, .openai, .grok, .openRouter]

  /// Keys whose values Offline Mode rewrites. Snapshotted on enable, restored on disable.
  private static let snapshotKeys: [String] = [
    UserDefaultsKeys.selectedTranscriptionModel,
    UserDefaultsKeys.selectedTranscriptionModelForMeetings,
    UserDefaultsKeys.selectedPromptModel,
    UserDefaultsKeys.selectedChatModel,
    UserDefaultsKeys.selectedReadAloudModel,
    UserDefaultsKeys.selectedMeetingSummaryModel,
    UserDefaultsKeys.selectedImprovementModel,
  ]

  // MARK: - Entry point

  /// Every selection key `reconcileAll` may rewrite — compared before and after so open views can
  /// be told when it did.
  private static let reconciledKeys: [String] = snapshotKeys + [
    UserDefaultsKeys.selectedImprovementModel,
    UserDefaultsKeys.selectedMeetingSummaryModel,
  ]

  /// Rewrites the persisted selections, then posts `.modelSelectionsReconciled` if any changed.
  ///
  /// The settings window holds the selections in memory (`SettingsViewModel.data`) and writes all
  /// of them back on its next save. Without the notice, switching Offline Mode on left every
  /// picker showing the old cloud model — and the next unrelated settings change wrote those cloud
  /// models back over the on-device ones the mode had just selected.
  static func reconcileAll() {
    let before = reconciledKeys.map { UserDefaults.standard.string(forKey: $0) }
    reconcileAllSelections()
    let after = reconciledKeys.map { UserDefaults.standard.string(forKey: $0) }
    guard before != after else { return }
    postSelectionsChanged()
  }

  /// Tells the settings window and the speech service that persisted selections were rewritten
  /// behind their back. Also used by `CloudModelOffer` after the user accepts a switch.
  static func postSelectionsChanged() {
    NotificationCenter.default.post(name: .modelSelectionsReconciled, object: nil)
    // Speech service and the offline-model preload follow the dictation slot.
    if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedTranscriptionModel),
      let model = TranscriptionModel(rawValue: TranscriptionModel.migrateLegacyTranscriptionRawValue(raw)) {
      NotificationCenter.default.post(name: .modelChanged, object: model)
    }
  }

  private static func reconcileAllSelections() {
    OpenRouterChatPreferences.migrateCustomEndpointIfNeeded()
    LocalLLMPreferences.migrateHiddenMLXFlagIfNeeded()
    // Offline Mode inverts this type's job: instead of following the keys the user has, the
    // selections that can run locally are pulled back onto this Mac. Without it the reconciler
    // actively fights the mode — an OpenAI key entered for something else is enough for it to
    // rewrite dictation to a cloud model, the exact failure the mode exists to make impossible.
    if OfflineMode.isEnabled {
      // Turning Offline Mode on is a decision for on-device models; a later key must not read the
      // key-less fallback as "never chosen" and move these slots to the cloud once the mode is off.
      adoptKeylessOfflineFallbacks()
      // Same for Read Aloud: Offline Mode is a deliberate choice for the on-device voice.
      UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.keylessReadAloudFallback)
      snapshotPreOfflineSelectionsIfNeeded()
      reconcileForOfflineMode()
      return
    }
    restorePreOfflineSelectionsIfNeeded()
    reconcilePromptSelection(key: UserDefaultsKeys.selectedChatModel,
                             candidates: PromptModel.chatModels,
                             fallback: SettingsDefaults.selectedChatModel,
                             offlineWhenKeyless: true)
    reconcilePromptSelection(key: UserDefaultsKeys.selectedPromptModel,
                             candidates: PromptModel.dictatePromptCapableModels,
                             fallback: SettingsDefaults.selectedPromptModel,
                             offlineWhenKeyless: true)
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

  // MARK: - Offline Mode snapshot / restore

  /// Captures the current selections the first time Offline Mode is on, so turning it off can
  /// put the user back on the cloud models they had. Later reconciles while the mode stays on
  /// must not overwrite that snapshot with the already-rewritten offline values.
  /// Marks a key that held no value when Offline Mode was turned on; restore removes the key so
  /// the factory default applies again instead of leaving the on-device value behind.
  static let unsetSnapshotSentinel = "__unset__"

  static func snapshotPreOfflineSelectionsIfNeeded(defaults: UserDefaults = .standard) {
    var snapshot = defaults.dictionary(forKey: UserDefaultsKeys.offlineModePreOfflineSelections)
      as? [String: String]
    let existing = snapshot != nil
    var added = 0
    for key in snapshotKeys where snapshot?[key] == nil {
      // A snapshot taken by an older build lacks keys added later. Merge them in with the current
      // value — this runs before the reconciler moves the slot in the same pass. A value that is
      // already on-device is the reconciler's own write (or the user's choice for Offline Mode),
      // not a cloud choice to go back to, so it is left alone.
      if existing, let value = defaults.string(forKey: key),
        PromptModel(rawValue: value)?.localMLXModelType != nil
      {
        continue
      }
      if snapshot == nil { snapshot = [:] }
      snapshot?[key] = defaults.string(forKey: key) ?? unsetSnapshotSentinel
      added += 1
    }
    guard existing ? added > 0 : true else { return }
    defaults.set(snapshot ?? [:], forKey: UserDefaultsKeys.offlineModePreOfflineSelections)
    DebugLogger.log("MODEL-RECONCILE: snapshotted \(added) pre-offline selection(s)")
  }

  static func restorePreOfflineSelectionsIfNeeded(defaults: UserDefaults = .standard) {
    guard let snapshot = defaults.dictionary(forKey: UserDefaultsKeys.offlineModePreOfflineSelections)
            as? [String: String] else { return }
    for (key, value) in snapshot {
      if value == unsetSnapshotSentinel {
        defaults.removeObject(forKey: key)
        DebugLogger.log("MODEL-RECONCILE: \(key): removed, was unset (Offline Mode off)")
      } else {
        defaults.set(value, forKey: key)
        DebugLogger.log("MODEL-RECONCILE: \(key): restored \(value) (Offline Mode off)")
      }
    }
    defaults.removeObject(forKey: UserDefaultsKeys.offlineModePreOfflineSelections)
  }

  // MARK: - Offline Mode

  /// Moves the selections that have an on-device equivalent onto this Mac: dictation, meeting
  /// transcription, Dictate Prompt, Chat, Read Aloud, the meeting summary, and Smart Improvement
  /// (which also drives Voice Feedback). The last two follow the Dictate Prompt model so a single
  /// on-device model serves every text slot and only one MLX model needs to be in memory.
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

    reconcilePromptSlotForOfflineMode(key: UserDefaultsKeys.selectedPromptModel)
    reconcilePromptSlotForOfflineMode(key: UserDefaultsKeys.selectedChatModel)
    for key in [UserDefaultsKeys.selectedMeetingSummaryModel, UserDefaultsKeys.selectedImprovementModel] {
      reconcileSlotToDictatePromptModelForOfflineMode(key: key)
    }

    let ttsKey = UserDefaultsKeys.selectedReadAloudModel
    let ttsRaw = UserDefaults.standard.string(forKey: ttsKey) ?? SettingsDefaults.readAloudModel.rawValue
    let ttsCurrent = TTSModel(rawValue: TTSModel.migrateLegacyReadAloudRawValue(ttsRaw))
      ?? SettingsDefaults.readAloudModel
    if ttsCurrent.provider != .system {
      UserDefaults.standard.set(TTSModel.systemMacOS.rawValue, forKey: ttsKey)
      DebugLogger.log(
        "MODEL-RECONCILE: \(ttsKey): \(ttsCurrent.rawValue) → \(TTSModel.systemMacOS.rawValue) (Offline Mode)")
    }
  }

  private static func reconcilePromptSlotForOfflineMode(key: String) {
    let raw = UserDefaults.standard.string(forKey: key) ?? SettingsDefaults.selectedPromptModel.rawValue
    let current = PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(raw))
      ?? SettingsDefaults.selectedPromptModel
    // A custom OpenAI-compatible endpoint may already point at the user's own server; the network
    // guard is what decides, so leave that choice alone. In-process MLX (when this Mac can run it)
    // and the HTTP local server already run on this Mac — leave those alone too.
    if current.provider == .customOpenAI || current.provider == .local { return }
    if current.provider == .localMLX, current.isOfferableOnThisMac { return }
    let replacement = offlinePromptReplacement()
    guard replacement != current else { return }
    UserDefaults.standard.set(replacement.rawValue, forKey: key)
    DebugLogger.log(
      "MODEL-RECONCILE: \(key): \(current.rawValue) → \(replacement.rawValue) (Offline Mode)")
  }

  /// Moves a slot that has no model of its own offline onto whatever Dictate Prompt now uses
  /// (already reconciled by the caller), unless it already runs on this Mac or on the user's own
  /// endpoint.
  static func reconcileSlotToDictatePromptModelForOfflineMode(
    key: String, defaults: UserDefaults = .standard
  ) {
    let fallback = key == UserDefaultsKeys.selectedMeetingSummaryModel
      ? SettingsDefaults.selectedMeetingSummaryModel : SettingsDefaults.selectedImprovementModel
    let raw = defaults.string(forKey: key) ?? fallback.rawValue
    let current = PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(raw)) ?? fallback
    if current.provider == .customOpenAI || current.provider == .local { return }
    if current.provider == .localMLX, current.isOfferableOnThisMac { return }
    let promptRaw = defaults.string(forKey: UserDefaultsKeys.selectedPromptModel)
      ?? SettingsDefaults.selectedPromptModel.rawValue
    let target = PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(promptRaw))
      ?? offlinePromptReplacement()
    guard target != current else { return }
    defaults.set(target.rawValue, forKey: key)
    DebugLogger.log(
      "MODEL-RECONCILE: \(key): \(current.rawValue) → \(target.rawValue) (Offline Mode)")
  }

  /// Prefer a downloaded MLX model this Mac can run; otherwise the recommended catalogue
  /// default, or the HTTP local server on machines with no MLX (Intel).
  private static func offlinePromptReplacement() -> PromptModel {
    let downloaded = LocalLLMModelType.byPreference.last {
      $0.isOfferable && LocalLLMModelManager.shared.isModelAvailable($0)
    }
    if let downloaded {
      return PromptModel.forLocalLLMModel(downloaded)
    }
    if LocalLLMModelType.isSupportedOnThisMac {
      return PromptModel.forLocalLLMModel(LocalLLMModelType.defaultModel)
    }
    return .localModel
  }

  /// The best on-device model the user has actually downloaded, or the accuracy pick if none is —
  /// pointing at a model that still needs downloading is a solvable dead end (Settings offers the
  /// button), whereas silently selecting Tiny would quietly degrade every transcript.
  private static func offlineTranscriptionReplacement() -> TranscriptionModel {
    offlineTranscriptionReplacement(
      downloaded: OfflineModelType.byAccuracy.last { ModelManager.shared.isModelAvailable($0) })
  }

  /// The pure half of the decision above, split out so it can be tested without `ModelManager`
  /// and the on-disk model store.
  static func offlineTranscriptionReplacement(downloaded: OfflineModelType?) -> TranscriptionModel {
    TranscriptionModel.forOfflineModel(downloaded ?? OfflineModelType.mostAccurate)
  }

  // MARK: - PromptModel-backed features (chat, dictate prompt, improvement, meeting summary)

  /// `offlineWhenKeyless`: with no cloud key at all, fall back to the offline MLX default instead of
  /// leaving a cloud model selected that can only fail. Only for Dictate Prompt and Chat — the
  /// features a new user tries by hand. Smart Improvement and meeting summaries run unattended, and
  /// a 4B model grinding through them in the background is not a default anyone chose.
  private static func reconcilePromptSelection(
    key: String, candidates: [PromptModel], fallback: PromptModel, offlineWhenKeyless: Bool = false
  ) {
    let raw = UserDefaults.standard.string(forKey: key) ?? fallback.rawValue
    let current = PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(raw)) ?? fallback
    if let mlx = current.localMLXModelType, !mlx.isOfferable {
      let replacement = preferredPromptModel(among: candidates, hasKey: { hasKey($0) })
        ?? PromptModel.forLocalLLMModel(LocalLLMModelType.defaultModel)
      UserDefaults.standard.set(replacement.rawValue, forKey: key)
      DebugLogger.log(
        "MODEL-RECONCILE: \(key): \(current.rawValue) → \(replacement.rawValue) (MLX not offerable)")
      return
    }
    // A slot the key-less fallback put on MLX — and that has not been used offline since — goes
    // back once a cloud key exists: to what it held before if that provider has a key again (a
    // keychain read that failed at launch looks exactly like "no keys"), else to the keyed
    // provider's default. `hasKey(.localMLX)` is always true, so this runs before the return below.
    if offlineWhenKeyless, let record = keylessOfflineFallback(key: key, current: current) {
      guard let upgrade = keylessUpgrade(
        previous: record.previous, among: candidates, hasKey: { hasKey($0) })
      else { return }
      UserDefaults.standard.set(upgrade.rawValue, forKey: key)
      setKeylessOfflineFallback(key: key, record: nil)
      DebugLogger.log("MODEL-RECONCILE: \(key): \(current.rawValue) → \(upgrade.rawValue) (key added)")
      return
    }
    if hasKey(current.provider) { return }
    if let replacement = preferredPromptModel(among: candidates, hasKey: { hasKey($0) }) {
      UserDefaults.standard.set(replacement.rawValue, forKey: key)
      DebugLogger.log("MODEL-RECONCILE: \(key): \(current.rawValue) → \(replacement.rawValue) (no key for \(current.provider))")
      return
    }
    guard offlineWhenKeyless,
      let offline = keylessOfflineModel(among: candidates, hasKey: { hasKey($0) })
    else { return }
    UserDefaults.standard.set(offline.rawValue, forKey: key)
    setKeylessOfflineFallback(
      key: key, record: KeylessOfflineRecord(fallback: offline, previous: current))
    DebugLogger.log("MODEL-RECONCILE: \(key): \(current.rawValue) → \(offline.rawValue) (no cloud key — offline)")
  }

  /// The offline MLX default, when it is among `candidates` (Apple Silicon) and no cloud provider
  /// in them has a key. A configured custom endpoint counts as a key; the local HTTP server does
  /// not — it may not be running, and nothing about a fresh install suggests one is.
  static func keylessOfflineModel(
    among candidates: [PromptModel],
    hasKey hasKeyForProvider: (ChatModelProvider) -> Bool
  ) -> PromptModel? {
    let offline = PromptModel.forLocalLLMModel(LocalLLMModelType.defaultModel)
    guard candidates.contains(offline) else { return nil }
    let anyCloudKey = candidates.contains {
      $0.provider != .local && $0.provider != .localMLX && hasKeyForProvider($0.provider)
    }
    return anyCloudKey ? nil : offline
  }

  /// Where a key-less fallback slot goes once a cloud key exists, or nil while none does: the
  /// previous selection if its provider is keyed again, else `preferredPromptModel`, else the first
  /// keyed cloud candidate — which covers Anthropic and custom-endpoint keys that
  /// `providerPreference` never substitutes.
  static func keylessUpgrade(
    previous: PromptModel?,
    among candidates: [PromptModel],
    hasKey hasKeyForProvider: (ChatModelProvider) -> Bool
  ) -> PromptModel? {
    func isKeyedCloud(_ model: PromptModel) -> Bool {
      model.provider != .local && model.provider != .localMLX && hasKeyForProvider(model.provider)
    }
    if let previous, candidates.contains(previous), isKeyedCloud(previous) { return previous }
    return preferredPromptModel(among: candidates, hasKey: hasKeyForProvider)
      ?? candidates.first(where: isKeyedCloud)
  }

  struct KeylessOfflineRecord {
    let fallback: PromptModel
    let previous: PromptModel?
  }

  /// The record for `key` while the slot still holds the value the fallback wrote. A slot the user
  /// has since changed drops its record, so a later manual pick of the same model is not upgraded.
  nonisolated static func keylessOfflineFallback(key: String, current: PromptModel) -> KeylessOfflineRecord? {
    let records = UserDefaults.standard.dictionary(forKey: UserDefaultsKeys.keylessOfflineFallbacks)
    guard let entry = records?[key] as? [String: String],
      let fallback = entry["fallback"].flatMap(PromptModel.init(rawValue:))
    else { return nil }
    guard fallback == current else {
      setKeylessOfflineFallback(key: key, record: nil)
      return nil
    }
    return KeylessOfflineRecord(fallback: fallback, previous: entry["previous"].flatMap(PromptModel.init(rawValue:)))
  }

  /// The user has now run a request on the offline model (or turned Offline Mode on): from here it
  /// is their model, and adding a key later must not move them to the cloud without a word — the
  /// same rule `reconcileTranscription` states for offline dictation.
  nonisolated static func adoptKeylessOfflineFallbacks() {
    guard UserDefaults.standard.dictionary(forKey: UserDefaultsKeys.keylessOfflineFallbacks) != nil else { return }
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.keylessOfflineFallbacks)
    DebugLogger.log("MODEL-RECONCILE: key-less offline selections adopted — no automatic cloud upgrade")
  }

  nonisolated private static func setKeylessOfflineFallback(key: String, record: KeylessOfflineRecord?) {
    var records = UserDefaults.standard.dictionary(forKey: UserDefaultsKeys.keylessOfflineFallbacks) ?? [:]
    records[key] = record.map { r -> [String: String] in
      var entry = ["fallback": r.fallback.rawValue]
      entry["previous"] = r.previous?.rawValue
      return entry
    }
    UserDefaults.standard.set(records, forKey: UserDefaultsKeys.keylessOfflineFallbacks)
  }

  /// `hasKey` is passed in rather than read here, so the ordering rule can be tested without the
  /// Keychain. No default argument: those are evaluated outside this type's `@MainActor`
  /// isolation, which `hasKey` cannot be called from.
  static func preferredPromptModel(
    among candidates: [PromptModel],
    hasKey hasKeyForProvider: (ChatModelProvider) -> Bool
  ) -> PromptModel? {
    for provider in providerPreference where hasKeyForProvider(provider) {
      // Prefer the provider's canonical default if the feature allows it, else its first candidate.
      if candidates.contains(provider.defaultChatModel) { return provider.defaultChatModel }
      if let first = candidates.first(where: { $0.provider == provider }) { return first }
    }
    return nil
  }

  // MARK: - Read Aloud (TTSModel)

  /// Cloud Read Aloud models in preference order. Not `readAloudModels`: that list is filtered by
  /// Offline Mode and starts with the macOS voice.
  private static let readAloudCloudPreference: [TTSModel] = [
    .gemini38FlashLiteTTS, .gemini38FlashTTS, .openAIGpt4oMiniTTS, .grokVoiceTTS,
  ]

  /// Where Read Aloud goes once a cloud key exists after the macOS-voice fallback, or nil while
  /// none does: the previous selection if its provider is keyed again, else the first keyed cloud
  /// model. `hasKey` is passed in so the rule can be tested without the Keychain.
  static func readAloudUpgrade(
    previous: TTSModel?,
    hasKey hasKeyForProvider: (TTSProvider) -> Bool
  ) -> TTSModel? {
    if let previous, previous != .systemMacOS,
      readAloudCloudPreference.contains(previous), hasKeyForProvider(previous.provider)
    {
      return previous
    }
    return readAloudCloudPreference.first(where: { hasKeyForProvider($0.provider) })
  }

  private static func reconcileReadAloud() {
    let key = UserDefaultsKeys.selectedReadAloudModel
    let recordKey = UserDefaultsKeys.keylessReadAloudFallback
    let raw = UserDefaults.standard.string(forKey: key) ?? SettingsDefaults.readAloudModel.rawValue
    let current = TTSModel(rawValue: TTSModel.migrateLegacyReadAloudRawValue(raw)) ?? SettingsDefaults.readAloudModel
    let storedPrevious = UserDefaults.standard.string(forKey: recordKey)
    // The macOS voice has no key, so without the record a later cloud key would never move the
    // slot off the fallback. A slot the user changed drops its record, so a later manual pick of
    // the macOS voice is not upgraded.
    if let storedPrevious {
      if current == .systemMacOS {
        let previous = TTSModel(rawValue: TTSModel.migrateLegacyReadAloudRawValue(storedPrevious))
        if let upgrade = readAloudUpgrade(previous: previous, hasKey: { hasKey($0) }) {
          UserDefaults.standard.set(upgrade.rawValue, forKey: key)
          UserDefaults.standard.removeObject(forKey: recordKey)
          DebugLogger.log("MODEL-RECONCILE: \(key): systemMacOS → \(upgrade.rawValue) (cloud key added)")
        }
        return
      }
      UserDefaults.standard.removeObject(forKey: recordKey)
    }
    if hasKey(current.provider) { return }
    guard let replacement = TTSModel.readAloudModels.first(where: { hasKey($0.provider) }) else { return }
    UserDefaults.standard.set(replacement.rawValue, forKey: key)
    if replacement == .systemMacOS {
      UserDefaults.standard.set(current.rawValue, forKey: recordKey)
    }
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

  /// Which transcription model stands in for a given chat provider, or `nil` when that provider
  /// has none. Split out of `replaceTranscriptionSelection` so the table can be tested directly.
  static func transcriptionReplacement(for provider: ChatModelProvider) -> TranscriptionModel? {
    switch provider {
    // Each provider's best-measured tier (plans/model-audits/2026-09-03-audit.md). Gemini is named
    // explicitly: the app-wide default is now an OpenAI model and would dead-end a Gemini-only user.
    case .gemini: return .gemini31FlashLite
    case .openai: return .openAIGPTTranscribe
    case .grok: return .xaiTranscribe
    // OpenRouter is in `providerPreference` for chat slots only; the rest are never substitutes.
    case .local, .localMLX, .customOpenAI, .openRouter, .anthropic: return nil
    }
  }

  private static func replaceTranscriptionSelection(key: String, current: TranscriptionModel) {
    guard let provider = providerPreference.first(where: { hasKey($0) }) else { return }
    guard let replacement = transcriptionReplacement(for: provider) else { return }
    UserDefaults.standard.set(replacement.rawValue, forKey: key)
    DebugLogger.log("MODEL-RECONCILE: \(key): \(current.rawValue) → \(replacement.rawValue)")
  }
}

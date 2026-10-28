import AppKit

/// After the user adds an API key, offers to move the features that still run on this Mac onto
/// that provider's cloud models — instead of doing it silently.
///
/// A key-less install puts dictation on offline Whisper/Parakeet and Dictate Prompt / Chat on the
/// MLX model. Adding a key later used to leave those slots where they were (dictation by design,
/// see `ModelSelectionReconciler.reconcileTranscription`), so a user who just pasted a key kept
/// the slower, weaker models without knowing better ones were one picker away. Switching
/// automatically would be worse: it turns "on-device" into "audio goes to Google" without a word,
/// which is exactly what a practice dictating patient findings must never get. So: ask once.
///
/// Asked only when a key is saved — never at launch — and never while Offline Mode is on. A "No"
/// is remembered per provider; a key for a different provider asks again.
@MainActor
enum CloudModelOffer {

  struct Upgrade: Equatable {
    let key: String
    let feature: String
    let fromName: String
    let to: String
    let toName: String
    let provider: ChatModelProvider
  }

  // MARK: - Decision (pure, tested)

  /// The slots that sit on an on-device model and the cloud model each would move to. Only the
  /// app's own offline models count: a self-hosted transcription endpoint, a local Ollama server
  /// or a custom endpoint is something the user set up on purpose.
  static func upgrades(
    selections: [String: String],
    hasKey: (ChatModelProvider) -> Bool
  ) -> [Upgrade] {
    var result: [Upgrade] = []

    let transcriptionSlots: [(String, String)] = [
      (UserDefaultsKeys.selectedTranscriptionModel, String(localized: "Dictation")),
      (UserDefaultsKeys.selectedTranscriptionModelForMeetings, String(localized: "Meeting transcription")),
    ]
    if let provider = ModelSelectionReconciler.providerPreference.first(where: hasKey),
      let target = ModelSelectionReconciler.transcriptionReplacement(for: provider) {
      for (key, feature) in transcriptionSlots {
        guard let raw = selections[key],
          let current = TranscriptionModel(
            rawValue: TranscriptionModel.migrateLegacyTranscriptionRawValue(raw)),
          current.isOffline
        else { continue }
        result.append(Upgrade(
          key: key, feature: feature, fromName: current.displayName,
          to: target.rawValue, toName: target.displayName, provider: provider))
      }
    }

    let promptSlots: [(String, String, [PromptModel])] = [
      (UserDefaultsKeys.selectedPromptModel, String(localized: "Dictate Prompt"), PromptModel.dictatePromptCapableModels),
      (UserDefaultsKeys.selectedChatModel, String(localized: "Chat"), PromptModel.chatModels),
      (UserDefaultsKeys.selectedMeetingSummaryModel, String(localized: "Meeting summary"), PromptModel.chatModels),
      (UserDefaultsKeys.selectedImprovementModel, String(localized: "Smart Improvement"), PromptModel.chatModels),
    ]
    for (key, feature, candidates) in promptSlots {
      guard let raw = selections[key],
        let current = PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(raw)),
        current.provider == .localMLX,
        let target = ModelSelectionReconciler.keylessUpgrade(
          previous: nil, among: candidates, hasKey: hasKey)
      else { continue }
      result.append(Upgrade(
        key: key, feature: feature, fromName: current.displayName,
        to: target.rawValue, toName: target.displayName, provider: target.provider))
    }
    return result
  }

  /// Whether to ask: something to upgrade, and at least one target provider the user has not
  /// already said "no" to.
  static func shouldOffer(_ upgrades: [Upgrade], declined: Set<String>) -> Bool {
    !upgrades.isEmpty && !Set(upgrades.map(\.provider.rawValue)).isSubset(of: declined)
  }

  // MARK: - Trigger

  private static var pending: Task<Void, Never>?
  private static var isShowing = false

  /// Call after a key was saved. Debounced: the Settings key field saves on every keystroke, and
  /// the dialog must not pop up after the first character of a typed key.
  static func scheduleCheck() {
    pending?.cancel()
    pending = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      guard !Task.isCancelled else { return }
      presentIfNeeded()
    }
  }

  private static func presentIfNeeded() {
    guard !isShowing, !OfflineMode.isEnabled else { return }
    var selections: [String: String] = [:]
    for key in [
      UserDefaultsKeys.selectedTranscriptionModel,
      UserDefaultsKeys.selectedTranscriptionModelForMeetings,
      UserDefaultsKeys.selectedPromptModel,
      UserDefaultsKeys.selectedChatModel,
      UserDefaultsKeys.selectedMeetingSummaryModel,
      UserDefaultsKeys.selectedImprovementModel,
    ] {
      selections[key] = UserDefaults.standard.string(forKey: key)
    }
    let upgrades = upgrades(selections: selections, hasKey: { ModelSelectionReconciler.hasKey($0) })
    let declined = Set(
      UserDefaults.standard.stringArray(forKey: UserDefaultsKeys.cloudModelOfferDeclinedProviders) ?? [])
    guard shouldOffer(upgrades, declined: declined) else { return }
    present(upgrades)
  }

  // MARK: - UI

  private static func present(_ upgrades: [Upgrade]) {
    let providers = orderedProviders(upgrades)
    let alert = NSAlert()
    alert.alertStyle = .informational
    if providers.count == 1, let only = providers.first {
      alert.messageText = String(localized: "Use \(familyName(only)) instead of the on-device models?")
      alert.addButton(withTitle: String(localized: "Switch to \(familyName(only))"))
    } else {
      alert.messageText = String(localized: "Use your cloud models instead of the on-device ones?")
      alert.addButton(withTitle: String(localized: "Switch"))
    }
    alert.addButton(withTitle: String(localized: "Keep On-Device"))

    let lines = upgrades.map { "\($0.feature): \($0.fromName) → \($0.toName)" }.joined(separator: "\n")
    let companies = providers.map(companyName).joined(separator: " and ")
    alert.informativeText = String(localized: """
      These features still run on this Mac:

      \(lines)

      The cloud models are more accurate and faster. Recordings and text for these features are \
      then sent to \(companies). You can change each one later in Settings.
      """)

    isShowing = true
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      isShowing = false
      if response == .alertFirstButtonReturn {
        apply(upgrades)
      } else {
        decline(providers)
      }
    }
    if let window = NSApp.keyWindow, window.isVisible {
      alert.beginSheetModal(for: window, completionHandler: finish)
    } else {
      NSApp.activate(ignoringOtherApps: true)
      finish(alert.runModal())
    }
  }

  private static func apply(_ upgrades: [Upgrade]) {
    for upgrade in upgrades {
      UserDefaults.standard.set(upgrade.to, forKey: upgrade.key)
      DebugLogger.log(
        "MODEL-RECONCILE: \(upgrade.key): \(upgrade.fromName) → \(upgrade.to) (cloud offer accepted)")
    }
    ModelSelectionReconciler.postSelectionsChanged()
  }

  private static func decline(_ providers: [ChatModelProvider]) {
    var declined = Set(
      UserDefaults.standard.stringArray(forKey: UserDefaultsKeys.cloudModelOfferDeclinedProviders) ?? [])
    declined.formUnion(providers.map(\.rawValue))
    UserDefaults.standard.set(Array(declined).sorted(), forKey: UserDefaultsKeys.cloudModelOfferDeclinedProviders)
    DebugLogger.log("MODEL-RECONCILE: cloud offer declined for \(declined.sorted()) — staying on-device")
  }

  private static func orderedProviders(_ upgrades: [Upgrade]) -> [ChatModelProvider] {
    var seen: [ChatModelProvider] = []
    for upgrade in upgrades where !seen.contains(upgrade.provider) { seen.append(upgrade.provider) }
    return seen
  }

  private static func familyName(_ provider: ChatModelProvider) -> String {
    switch provider {
    case .gemini: return "Gemini"
    case .openai: return "OpenAI"
    case .grok: return "Grok"
    case .anthropic: return "Claude"
    case .openRouter: return "OpenRouter"
    case .chatGPTPlan: return "your ChatGPT plan"
    case .customOpenAI: return "your own server"
    case .local, .localMLX: return "local models"
    }
  }

  private static func companyName(_ provider: ChatModelProvider) -> String {
    switch provider {
    case .gemini: return "Google"
    case .openai: return "OpenAI"
    case .grok: return "xAI"
    case .anthropic: return "Anthropic"
    case .openRouter: return "OpenRouter"
    case .chatGPTPlan: return "OpenAI"
    case .customOpenAI: return "your own server"
    case .local, .localMLX: return "this Mac"
    }
  }
}

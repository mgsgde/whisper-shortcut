import Testing
@testable import WhisperShortcut_AppStore

@Suite("Gemini chat lineup after 3.8")
struct ChatModelLineupTests {

  @Test("New 3.8 Flash case is wired through PromptModel")
  func newCaseIsWired() {
    #expect(PromptModel.gemini38Flash.rawValue == "gemini-3.8-flash")
    #expect(PromptModel.gemini38Flash.provider == .gemini)
    #expect(PromptModel.gemini38Flash.supportsTextChat)
    #expect(PromptModel.gemini38Flash.supportsDictatePrompt)
    #expect(PromptModel.gemini38Flash.asTranscriptionModel == .gemini38Flash)
    #expect(PromptModel.gemini38Flash.shortAlias == "gemini38flash")
    #expect(Set(PromptModel.allCases.map(\.shortAlias)).count == PromptModel.allCases.count)
  }

  @Test("Chat and Smart Improvement defaults moved to 3.8 Flash")
  func defaultsMoved() {
    #expect(SettingsDefaults.selectedChatModel == .gemini38Flash)
    #expect(SettingsDefaults.selectedImprovementModel == .gemini38Flash)
    #expect(ChatModelProvider.gemini.defaultChatModel == .gemini38Flash)
    #expect(AppConstants.contextDerivationEndpoint.contains("gemini-3.8-flash"))
  }

  @Test("Chat offers Gemini 4 Argon and 3.8 Flash, not 3.7")
  func chatOffersArgonNot37() {
    #expect(PromptModel.gemini4Argon.chatReplacement == nil)
    #expect(PromptModel.gemini38Flash.chatReplacement == nil)
    #expect(PromptModel(rawValue: "gemini-3.7-flash") == nil)
    // `chatModels` is filtered by Offline Mode, which reads the real app's defaults on a dev Mac.
    let previousOffline = OfflineMode.isEnabled
    defer { OfflineMode.setEnabled(previousOffline) }
    OfflineMode.setEnabled(false)
    #expect(PromptModel.chatModels.contains(.gemini4Argon))
    #expect(PromptModel.chatModels.contains(.gemini38Flash))
    #expect(!PromptModel.chatModels.contains { $0.rawValue == "gemini-3.7-flash" })
  }

  @Test("Removed 3.5, 3.6 and 3.7 Flash selections forward to 3.8 Flash")
  func removedFlashForwardsTo38() {
    for slug in ["gemini-3.5-flash", "gemini-3.6-flash", "gemini-3.7-flash"] {
      #expect(PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(slug)) == .gemini38Flash, "\(slug)")
      #expect(
        TranscriptionModel(rawValue: TranscriptionModel.migrateLegacyTranscriptionRawValue(slug))
          == .gemini38Flash, "\(slug)")
    }
    for slug in ["gemini-2.5-flash", "gemini-3-flash-preview"] {
      #expect(
        TranscriptionModel(rawValue: TranscriptionModel.migrateLegacyTranscriptionRawValue(slug))
          == .gemini38Flash, "\(slug)")
    }
  }

  @Test("Legacy 2.5-flash and 3-flash-preview land on a still-visible model")
  func nobodyMigratedOntoAHiddenModel() {
    for slug in ["gemini-2.5-flash", "gemini-3-flash-preview"] {
      let migrated = PromptModel.migrateLegacyPromptRawValue(slug)
      #expect(migrated == PromptModel.gemini38Flash.rawValue, "\(slug) → \(migrated)")
      let model = PromptModel(rawValue: migrated)
      #expect(model != nil, "\(slug) did not parse after migration")
      #expect(model?.chatReplacement == nil, "\(slug) landed on a hidden model")
    }
  }

  @Test("/model resolves 3.8 and bare Gemini 3")
  func resolver() {
    let current = PromptModel.gemini38Flash
    for argument in ["3.8", "gemini 3.8 flash", "gemini-3.8-flash"] {
      #expect(
        ChatModelCommandResolver.resolve(argument: argument, currentSelection: current)
          == .applied(model: .gemini38Flash),
        "\(argument)")
    }
    #expect(
      ChatModelCommandResolver.resolve(argument: "gemini 3", currentSelection: current)
        == .applied(model: .gemini38Flash))
    #expect(
      ChatModelCommandResolver.resolve(argument: "3.1 flash lite", currentSelection: current)
        == .applied(model: .gemini31FlashLite))
  }

  @Test("/gemini argon and gemini 4 resolve to Argon; 3.7 lands on 3.8")
  func argonAndRemoved37Resolve() {
    let current = PromptModel.gemini38Flash
    for argument in ["/gemini argon", "gemini 4"] {
      #expect(
        ChatModelCommandResolver.resolve(argument: argument, currentSelection: current)
          == .applied(model: .gemini4Argon),
        "\(argument)")
    }
    #expect(
      ChatModelCommandResolver.resolve(argument: "3.7", currentSelection: current)
        == .applied(model: .gemini38Flash))
  }

  @Test("A slot on a superseded Flash resolves to what the loader would return")
  func resolverMirrorsTheLoader() {
    // Legacy slugs forward through migrateLegacyPromptRawValue, which is what the loader persists.
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "gemini-3.5-flash") == .gemini38Flash)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "gemini-3.6-flash") == .gemini38Flash)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "gemini-3.7-flash") == .gemini38Flash)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "gemini-2.5-flash") == .gemini38Flash)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "gemini-3-flash-preview") == .gemini38Flash)
    // Already there, and unrelated picks, must not be swept up.
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "gemini-3.8-flash") == .gemini38Flash)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "grok-4.7") == .grok47)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "grok-4.6") == .grok47)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "gpt-5.6-sol") == .openaiGPT6Sol)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "gpt-5.6-terra") == .openaiGPT6Sol)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "gpt-5.6-luna") == .openaiGPT6Luna)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "gpt-5.4-mini") == .openaiGPT5Mini)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "claude-opus-5") == .claudeOpus55)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "claude-sonnet-5") == .claudeSonnet55)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "claude-fable-5") == .claudeOpus55)
    #expect(PromptModel.resolvedChatSlotModel(forRawValue: "not-a-model") == nil)
  }

  @Test("Removed superseded chat models forward to their replacements")
  func removedModelsForward() {
    let expected: [String: PromptModel] = [
      "grok-4.20-0309-non-reasoning": .grok43, "grok-4.20-0309-reasoning": .grok43,
      "grok-4.5": .grok47, "grok-4.6": .grok47,
      "gpt-5": .openaiGPT6Sol, "gpt-5.4": .openaiGPT6Sol, "gpt-5.5": .openaiGPT6Sol,
      "gpt-5.6-sol": .openaiGPT6Sol, "gpt-5.6-terra": .openaiGPT6Sol, "gpt-5.6-luna": .openaiGPT6Luna,
      "claude-opus-4-8": .claudeOpus55, "claude-opus-5": .claudeOpus55, "claude-fable-5": .claudeOpus55,
      "claude-sonnet-5": .claudeSonnet55,
    ]
    for (raw, model) in expected {
      #expect(PromptModel(rawValue: raw) == nil, "\(raw) should no longer be an enum case")
      #expect(PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(raw)) == model, "\(raw)")
      #expect(PromptModel.resolvedChatSlotModel(forRawValue: raw) == model, "\(raw)")
    }
    // Nothing is currently superseded: dominated models are removed outright.
    #expect(PromptModel.allCases.filter { $0.chatReplacement != nil }.isEmpty)
    #expect(PromptModel(rawValue: "gpt-5.4-mini") == .openaiGPT5Mini)
  }

  @Test("Transcription side of 3.8 Flash is Google, selectable, and clamps MINIMAL")
  func transcriptionSide() {
    #expect(TranscriptionModel.gemini38Flash.provider == .google)
    #expect(
      TranscriptionModel.gemini38Flash.apiEndpoint
        == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
    #expect(TranscriptionModel.gemini38Flash.asymmetryClass == .geminiFlash)
    #expect(TranscriptionModel.gemini38Flash.isSelectableForDictation)
    let clamped = TranscriptionModel.gemini38Flash.geminiTranscriptionGenerationConfig(
      temperature: 0.0, effort: .minimal)
    #expect(clamped.thinkingConfig?.thinkingLevel == TranscriptionThinkingEffort.low.geminiValue)
  }
}

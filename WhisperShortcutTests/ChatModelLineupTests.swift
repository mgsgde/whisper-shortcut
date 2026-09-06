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

  @Test("3.5 and 3.6 Flash are pruned from chat; 3.7 is not forwarded to 3.8")
  func pruneAndOnlyTheAskedPrune() {
    #expect(PromptModel.gemini35Flash.chatReplacement == .gemini37Flash)
    #expect(PromptModel.gemini36Flash.chatReplacement == .gemini37Flash)
    // Guard against the interleaved-latency decision being pre-empted: 3.8 was ~12% slower
    // in the 2026-09-03 probe, so 3.7 must stay selectable until that run.
    #expect(PromptModel.gemini37Flash.chatReplacement == nil)
    #expect(PromptModel.gemini38Flash.chatReplacement == nil)
    #expect(PromptModel.chatModels.contains(.gemini37Flash))
    #expect(PromptModel.chatModels.contains(.gemini38Flash))
    #expect(!PromptModel.chatModels.contains(.gemini35Flash))
    #expect(!PromptModel.chatModels.contains(.gemini36Flash))
  }

  @Test("Legacy 2.5-flash and 3-flash-preview land on a still-visible model")
  func nobodyMigratedOntoAHiddenModel() {
    for slug in ["gemini-2.5-flash", "gemini-3-flash-preview"] {
      let migrated = PromptModel.migrateLegacyPromptRawValue(slug)
      #expect(migrated == PromptModel.gemini37Flash.rawValue, "\(slug) → \(migrated)")
      let model = PromptModel(rawValue: migrated)
      #expect(model != nil, "\(slug) did not parse after migration")
      #expect(model?.chatReplacement == nil, "\(slug) landed on a hidden model")
    }
  }

  @Test("/model resolves 3.8, bare 3, and still distinguishes 3.7")
  func resolver() {
    let current = PromptModel.gemini37Flash
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
      ChatModelCommandResolver.resolve(argument: "3.7", currentSelection: current)
        == .applied(model: .gemini37Flash))
    #expect(
      ChatModelCommandResolver.resolve(argument: "3.1 flash lite", currentSelection: current)
        == .applied(model: .gemini31FlashLite))
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

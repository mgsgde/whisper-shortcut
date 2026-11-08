import Testing
@testable import WhisperShortcut_AppStore

@Suite("Gemini chat lineup after 3.8")
struct ChatModelLineupTests {

  struct Forward: Sendable {
    var note: String
    var raw: String
    var prompt: PromptModel? = nil
    var transcription: TranscriptionModel? = nil
    var slot: PromptModel? = nil
    var slotNil = false
    var removed = false
    var visible = false
    var stillCase: PromptModel? = nil
  }

  @Test(
    "Removed and legacy model ids forward to the model the loader would return",
    arguments: [
      // Legacy slugs forward through migrateLegacyPromptRawValue, which is what the loader persists.
      Forward(note: "gemini-3.5-flash", raw: "gemini-3.5-flash", prompt: .gemini38Flash, transcription: .gemini38Flash, slot: .gemini38Flash),
      Forward(note: "gemini-3.6-flash", raw: "gemini-3.6-flash", prompt: .gemini38Flash, transcription: .gemini38Flash, slot: .gemini38Flash),
      Forward(note: "gemini-3.7-flash", raw: "gemini-3.7-flash", prompt: .gemini38Flash, transcription: .gemini38Flash, slot: .gemini38Flash),
      Forward(note: "gemini-2.5-flash stays visible", raw: "gemini-2.5-flash", prompt: .gemini38Flash, transcription: .gemini38Flash, slot: .gemini38Flash, visible: true),
      Forward(note: "gemini-3-flash-preview stays visible", raw: "gemini-3-flash-preview", prompt: .gemini38Flash, transcription: .gemini38Flash, slot: .gemini38Flash, visible: true),
      // Already there, and unrelated picks, must not be swept up.
      Forward(note: "gemini-3.8-flash", raw: "gemini-3.8-flash", slot: .gemini38Flash),
      Forward(note: "grok-4.7", raw: "grok-4.7", slot: .grok47),
      Forward(note: "grok-4.20 non-reasoning", raw: "grok-4.20-0309-non-reasoning", prompt: .grok43, slot: .grok43, removed: true),
      Forward(note: "grok-4.20 reasoning", raw: "grok-4.20-0309-reasoning", prompt: .grok43, slot: .grok43, removed: true),
      Forward(note: "grok-4.5", raw: "grok-4.5", prompt: .grok47, slot: .grok47, removed: true),
      Forward(note: "grok-4.6", raw: "grok-4.6", prompt: .grok47, slot: .grok47, removed: true),
      Forward(note: "gpt-5", raw: "gpt-5", prompt: .openaiGPT6Sol, slot: .openaiGPT6Sol, removed: true),
      Forward(note: "gpt-5.4", raw: "gpt-5.4", prompt: .openaiGPT6Sol, slot: .openaiGPT6Sol, removed: true),
      Forward(note: "gpt-5.5", raw: "gpt-5.5", prompt: .openaiGPT6Sol, slot: .openaiGPT6Sol, removed: true),
      Forward(note: "gpt-5.6-sol", raw: "gpt-5.6-sol", prompt: .openaiGPT6Sol, slot: .openaiGPT6Sol, removed: true),
      Forward(note: "gpt-5.6-terra", raw: "gpt-5.6-terra", prompt: .openaiGPT6Sol, slot: .openaiGPT6Sol, removed: true),
      Forward(note: "gpt-5.6-luna", raw: "gpt-5.6-luna", prompt: .openaiGPT6Luna, slot: .openaiGPT6Luna, removed: true),
      Forward(note: "claude-opus-4-8", raw: "claude-opus-4-8", prompt: .claudeOpus55, slot: .claudeOpus55, removed: true),
      Forward(note: "claude-opus-5", raw: "claude-opus-5", prompt: .claudeOpus55, slot: .claudeOpus55, removed: true),
      Forward(note: "claude-fable-5", raw: "claude-fable-5", prompt: .claudeOpus55, slot: .claudeOpus55, removed: true),
      Forward(note: "claude-sonnet-5", raw: "claude-sonnet-5", prompt: .claudeSonnet55, slot: .claudeSonnet55, removed: true),
      Forward(note: "gpt-5.4-mini is still a case", raw: "gpt-5.4-mini", slot: .openaiGPT5Mini, stillCase: .openaiGPT5Mini),
      Forward(note: "not-a-model", raw: "not-a-model", slotNil: true),
    ])
  func removedModelsForward(_ row: Forward) {
    // Nothing is currently superseded: dominated models are removed outright.
    #expect(PromptModel.allCases.filter { $0.chatReplacement != nil }.isEmpty, "\(row.note)")
    if let prompt = row.prompt {
      let migrated = PromptModel.migrateLegacyPromptRawValue(row.raw)
      #expect(PromptModel(rawValue: migrated) == prompt, "\(row.note)")
      if row.visible {
        #expect(PromptModel(rawValue: migrated)?.chatReplacement == nil, "\(row.note)")
      }
    }
    if let transcription = row.transcription {
      #expect(
        TranscriptionModel(rawValue: TranscriptionModel.migrateLegacyTranscriptionRawValue(row.raw))
          == transcription, "\(row.note)")
    }
    if row.slotNil {
      #expect(PromptModel.resolvedChatSlotModel(forRawValue: row.raw) == nil, "\(row.note)")
    } else if let slot = row.slot {
      #expect(PromptModel.resolvedChatSlotModel(forRawValue: row.raw) == slot, "\(row.note)")
    }
    if row.removed {
      #expect(PromptModel(rawValue: row.raw) == nil, "\(row.note) should no longer be an enum case")
    }
    if let still = row.stillCase {
      #expect(PromptModel(rawValue: row.raw) == still, "\(row.note)")
    }
  }

  @Test("/model resolves current names; removed 3.7 lands on 3.8", arguments: [
    ("3.8", PromptModel.gemini38Flash),
    ("gemini 3.8 flash", PromptModel.gemini38Flash),
    ("gemini-3.8-flash", PromptModel.gemini38Flash),
    ("gemini 3", PromptModel.gemini38Flash),
    ("3.1 flash lite", PromptModel.gemini31FlashLite),
    ("/gemini argon", PromptModel.gemini4Argon),
    ("gemini 4", PromptModel.gemini4Argon),
    ("3.7", PromptModel.gemini38Flash),
  ])
  func resolver(argument: String, model: PromptModel) {
    #expect(
      ChatModelCommandResolver.resolve(argument: argument, currentSelection: .gemini38Flash)
        == .applied(model: model),
      "\(argument)")
  }

  @Test("Transcription MINIMAL effort on 3.8 Flash clamps to low")
  func transcriptionSide() {
    let clamped = TranscriptionModel.gemini38Flash.geminiTranscriptionGenerationConfig(
      temperature: 0.0, effort: .minimal)
    #expect(clamped.thinkingConfig?.thinkingLevel == TranscriptionThinkingEffort.low.geminiValue)
  }

  @Test("GPT-6.1 Terra is wired as an OpenAI chat model")
  func gpt61TerraIsWired() {
    let terra = PromptModel.openaiGPT61Terra
    #expect(terra.rawValue == "gpt-6.1-terra")
    #expect(terra.provider == .openai)
    #expect(terra.supportsTextChat)
    #expect(terra.supportsGrounding)
    #expect(!terra.supportsDictatePrompt)
    #expect(terra.asTranscriptionModel == nil)
    #expect(terra.chatReplacement == nil)
    #expect(terra.shortAlias == "gpt61terra")
    #expect(Set(PromptModel.allCases.map(\.shortAlias)).count == PromptModel.allCases.count)
    let previousOffline = OfflineMode.isEnabled
    defer { OfflineMode.setEnabled(previousOffline) }
    OfflineMode.setEnabled(false)
    #expect(PromptModel.chatModels.contains(.openaiGPT61Terra))
    #expect(PromptModel.chatModels.contains(.openaiGPT5Mini))
    #expect(
      ChatModelCommandResolver.resolve(argument: "terra", currentSelection: .openaiGPT6Sol)
        == .applied(model: .openaiGPT61Terra))
    #expect(
      ChatModelCommandResolver.resolve(argument: "gpt 6.1 terra", currentSelection: .openaiGPT6Sol)
        == .applied(model: .openaiGPT61Terra))
    #expect(
      ChatModelCommandResolver.resolve(argument: "5.6 terra", currentSelection: .openaiGPT6Sol)
        == .applied(model: .openaiGPT6Sol))
    #expect(
      OpenAIChatProvider.reasoningEffort(.default, model: "gpt-6.1-terra", useCustomEndpoint: false)
        == "low")
  }
}

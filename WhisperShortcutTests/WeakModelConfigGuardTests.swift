import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Weak model configuration guard")
struct WeakModelConfigGuardTests {

  @Test("Weak, strong and unknown models are classified")
  func weakClassification() {
    #expect(PromptModel.gemini38Flash.isWeakForConfiguration)
    #expect(PromptModel.gemini4Hydrogen.isWeakForConfiguration)
    #expect(!PromptModel.gemini4Neon.isWeakForConfiguration)
    #expect(!PromptModel.customOpenAIEndpoint.isWeakForConfiguration)
  }

  @Test("Suggestion prefers the same provider")
  func sameProvider() {
    #expect(
      PromptModel.strongConfigurationModel(for: .gemini38Flash, hasCredential: { $0 == .gemini })
        == .gemini4Neon)
  }

  @Test("Suggestion falls back to a provider with a credential")
  func fallbackProvider() {
    #expect(
      PromptModel.strongConfigurationModel(for: .claudeHaiku55, hasCredential: { $0 == .gemini })
        == .gemini4Neon)
  }

  @Test("No credentials means no suggestion")
  func noCredentials() {
    #expect(PromptModel.strongConfigurationModel(for: .localModel, hasCredential: { _ in false }) == nil)
  }

  @Test("A suggestion is never a weak model")
  func neverWeak() {
    for model in PromptModel.allCases {
      let suggestion = PromptModel.strongConfigurationModel(for: model, hasCredential: { _ in true })
      #expect(suggestion?.isWeakForConfiguration != true)
    }
  }

  @Test("Configuration tools are recognised")
  func configurationTools() {
    #expect(ChatToolRegistry.isConfigurationTool(ChatToolRegistry.updateInstructionsToolName))
    #expect(ChatToolRegistry.isConfigurationTool(AppSettingsChatTool.name))
    #expect(ChatToolRegistry.isConfigurationTool(ChatToolRegistry.readConfigHistoryToolName))
    #expect(ChatToolRegistry.isConfigurationTool("remember_dictation_term"))
    #expect(!ChatToolRegistry.isConfigurationTool("open_url"))
  }
}

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins the plan for moving an OpenRouter-pointed custom endpoint onto the OpenRouter provider.
@Suite("OpenRouter chat migration")
struct OpenRouterChatMigrationTests {

  private typealias Prefs = OpenRouterChatPreferences

  @Test("OpenRouter URL with a typed key and no account key adopts both key and slug")
  func adoptsKeyAndSlug() {
    let plan = Prefs.customEndpointMigration(
      customEndpointURL: "https://openrouter.ai/api/v1",
      customModelID: " anthropic/claude-sonnet ",
      proxyKey: " sk-or-v1-typed ",
      openRouterKey: nil)
    #expect(plan == Prefs.CustomEndpointMigration(modelID: "anthropic/claude-sonnet", keyToAdopt: "sk-or-v1-typed"))
  }

  @Test("An existing account key is never overwritten")
  func accountKeyWins() {
    let plan = Prefs.customEndpointMigration(
      customEndpointURL: "https://openrouter.ai/api/v1",
      customModelID: "openai/gpt-4o",
      proxyKey: "sk-or-v1-typed",
      openRouterKey: "sk-or-v1-account")
    #expect(plan?.keyToAdopt == nil)
    #expect(plan?.modelID == "openai/gpt-4o")
  }

  @Test("Other servers are not migrated")
  func otherServersAreLeftAlone() {
    for url in ["https://openinference.de/api/v1", "https://acme.openai.azure.com/openai/v1", "https://notopenrouter.ai/v1"] {
      #expect(
        Prefs.customEndpointMigration(
          customEndpointURL: url, customModelID: "x", proxyKey: "k", openRouterKey: nil) == nil)
    }
  }

  @Test("Empty or missing URL is not migrated")
  func emptyURL() {
    #expect(Prefs.customEndpointMigration(customEndpointURL: nil, customModelID: "x", proxyKey: "k", openRouterKey: nil) == nil)
    #expect(Prefs.customEndpointMigration(customEndpointURL: "  ", customModelID: "x", proxyKey: "k", openRouterKey: nil) == nil)
  }

  @Test("Subdomains and uppercase hosts migrate")
  func subdomainAndCase() {
    #expect(
      Prefs.customEndpointMigration(
        customEndpointURL: " https://EU.OpenRouter.AI/api/v1 ", customModelID: "x", proxyKey: nil, openRouterKey: nil) != nil)
  }

  @Test("An empty model id yields no slug")
  func emptyModelID() {
    let plan = Prefs.customEndpointMigration(
      customEndpointURL: "https://openrouter.ai/api/v1", customModelID: "  ", proxyKey: nil, openRouterKey: nil)
    #expect(plan == Prefs.CustomEndpointMigration(modelID: nil, keyToAdopt: nil))
  }

  @Test("Dictate Prompt is not rewritten to OpenRouter, which cannot run it")
  func dictatePromptSlotStaysCapable() {
    let custom = PromptModel.customOpenAIEndpoint.rawValue
    let replacement = PromptModel.gemini38Flash
    #expect(replacement.supportsDictatePrompt)
    #expect(!PromptModel.openRouterChat.supportsDictatePrompt)

    let migrated = Prefs.migratedSelections(
      [
        UserDefaultsKeys.selectedChatModel: custom,
        UserDefaultsKeys.selectedPromptModel: custom,
        UserDefaultsKeys.selectedImprovementModel: PromptModel.claudeHaiku55.rawValue,
      ],
      dictatePromptReplacement: replacement.rawValue)
    #expect(migrated[UserDefaultsKeys.selectedChatModel] == PromptModel.openRouterChat.rawValue)
    #expect(migrated[UserDefaultsKeys.selectedPromptModel] == replacement.rawValue)
    #expect(migrated[UserDefaultsKeys.selectedImprovementModel] == PromptModel.claudeHaiku55.rawValue)

    // No keyed Dictate-Prompt model: leave the slot alone rather than point it at OpenRouter.
    let excluded = Prefs.migratedSelections(
      [
        UserDefaultsKeys.selectedChatModel: custom,
        UserDefaultsKeys.selectedPromptModel: custom,
      ],
      dictatePromptReplacement: nil)
    #expect(excluded[UserDefaultsKeys.selectedChatModel] == PromptModel.openRouterChat.rawValue)
    #expect(excluded[UserDefaultsKeys.selectedPromptModel] == custom)

    // The snapshot uses the same map. An OpenRouter raw value is not an acceptable replacement.
    let snapshot = Prefs.migratedSelections(
      [UserDefaultsKeys.selectedPromptModel: custom],
      dictatePromptReplacement: PromptModel.openRouterChat.rawValue)
    #expect(snapshot[UserDefaultsKeys.selectedPromptModel] == custom)
  }

  @Test("/model openrouter resolves to the OpenRouter sentinel")
  func commandResolves() {
    for argument in ["openrouter", "open router", "OpenRouter"] {
      #expect(
        ChatModelCommandResolver.resolve(argument: argument, currentSelection: .gemini38Flash)
          == .applied(model: .openRouterChat),
        "\(argument)")
    }
  }
}

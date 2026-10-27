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

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins which credential the custom chat endpoint sends. The key field is one slot shared by every
/// custom endpoint and belongs to whatever server the URL names right now; the OpenAI key from
/// Settings → General is only a fallback. OpenRouter has its own provider and is not covered here.
@Suite("Custom endpoint credentials")
struct CustomEndpointCredentialTests {

  private typealias Prefs = OpenAIChatPreferences

  @Test("The key entered for the server wins over the OpenAI key")
  func proxyKeyWins() throws {
    let resolved = try #require(
      Prefs.resolveCredential(proxyKey: "sk-oi-openinference", openAIKey: "sk-openai"))

    #expect(resolved.key == "sk-oi-openinference")
    #expect(resolved.source == .proxyKey)
  }

  @Test("A proxy that accepts OpenAI keys still falls back to one")
  func openAIKeyRemainsTheGenericFallback() throws {
    let resolved = try #require(Prefs.resolveCredential(proxyKey: nil, openAIKey: "sk-openai"))

    #expect(resolved.key == "sk-openai")
    #expect(resolved.source == .openAIKey)
  }

  @Test("Whitespace-only keys count as absent rather than as a key")
  func blankKeysAreIgnored() throws {
    let resolved = try #require(
      Prefs.resolveCredential(proxyKey: "   ", openAIKey: "  sk-openai-padded \n"))

    #expect(resolved.key == "sk-openai-padded")
    #expect(resolved.source == .openAIKey)
  }

  @Test("Nothing configured resolves to nothing")
  func noKeysResolveToNil() {
    #expect(Prefs.resolveCredential(proxyKey: nil, openAIKey: nil) == nil)
    #expect(Prefs.resolveCredential(proxyKey: "", openAIKey: "") == nil)
  }
}

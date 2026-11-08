import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins which credential the custom chat endpoint sends. The key field is one slot shared by every
/// custom endpoint and belongs to whatever server the URL names right now; the OpenAI key from
/// Settings → General is only a fallback. OpenRouter has its own provider and is not covered here.
@Suite("Custom endpoint credentials")
struct CustomEndpointCredentialTests {

  private typealias Prefs = OpenAIChatPreferences

  struct CredentialCase: Sendable {
    let note: String
    let proxyKey: String?
    let openAIKey: String?
    let key: String?
    let source: OpenAIChatPreferences.ResolvedCredential?
  }

  @Test("The endpoint key wins, otherwise the OpenAI key, and blanks count as absent", arguments: [
    CredentialCase(
      note: "the key entered for the server wins",
      proxyKey: "sk-oi-openinference", openAIKey: "sk-openai",
      key: "sk-oi-openinference", source: .proxyKey),
    CredentialCase(
      note: "a proxy that accepts OpenAI keys still falls back to one",
      proxyKey: nil, openAIKey: "sk-openai",
      key: "sk-openai", source: .openAIKey),
    CredentialCase(
      note: "whitespace-only keys count as absent",
      proxyKey: "   ", openAIKey: "  sk-openai-padded \n",
      key: "sk-openai-padded", source: .openAIKey),
    CredentialCase(
      note: "nothing configured resolves to nothing",
      proxyKey: nil, openAIKey: nil, key: nil, source: nil),
    CredentialCase(
      note: "empty strings are absent",
      proxyKey: "", openAIKey: "", key: nil, source: nil),
  ])
  func resolveCredential(_ row: CredentialCase) throws {
    let resolved = Prefs.resolveCredential(proxyKey: row.proxyKey, openAIKey: row.openAIKey)
    #expect(resolved?.key == row.key, "\(row.note)")
    #expect(resolved?.source == row.source, "\(row.note)")
  }
}

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins which credential the custom chat endpoint sends.
///
/// This shipped wrong once and the symptom pointed at the wrong place: `customOpenAIChatAPIKey` is
/// a single slot shared by every custom endpoint, but the base URL it belongs to can change under
/// it. Switching an OpenInference setup over to OpenRouter kept sending the `sk-oi-…` key, and the
/// user saw "API key is invalid for the custom endpoint" immediately after a successful sign-in —
/// which reads as a broken OAuth flow, not as a stale key.
@Suite("Custom endpoint credentials")
struct CustomEndpointCredentialTests {

  private typealias Prefs = OpenAIChatPreferences

  @Test("On OpenRouter the connected account outranks a leftover proxy key")
  func openRouterAccountWinsOverStaleProxyKey() throws {
    let resolved = try #require(
      Prefs.resolveCredential(
        isOpenRouterEndpoint: true,
        proxyKey: "sk-oi-leftover-from-openinference",
        openRouterKey: "sk-or-v1-connected",
        openAIKey: "sk-openai"))

    #expect(resolved.key == "sk-or-v1-connected")
    #expect(resolved.source == .openRouterAccount)
  }

  @Test("A proxy key still works on OpenRouter when no account is connected")
  func proxyKeyIsTheFallbackOnOpenRouter() throws {
    let resolved = try #require(
      Prefs.resolveCredential(
        isOpenRouterEndpoint: true,
        proxyKey: "sk-or-v1-pasted-by-hand",
        openRouterKey: nil,
        openAIKey: "sk-openai"))

    #expect(resolved.key == "sk-or-v1-pasted-by-hand")
    #expect(resolved.source == .proxyKey)
  }

  /// An OpenAI key is never valid at openrouter.ai. Returning it would turn an honest
  /// "not configured" into a 401 that looks like a bug in the sign-in.
  @Test("The OpenAI key is never sent to OpenRouter")
  func openAIKeyIsNotAFallbackOnOpenRouter() {
    #expect(
      Prefs.resolveCredential(
        isOpenRouterEndpoint: true,
        proxyKey: nil,
        openRouterKey: nil,
        openAIKey: "sk-openai") == nil)
  }

  @Test("Other proxies keep their own key and never inherit the OpenRouter account")
  func otherProxiesAreUnaffected() throws {
    let resolved = try #require(
      Prefs.resolveCredential(
        isOpenRouterEndpoint: false,
        proxyKey: "sk-oi-openinference",
        openRouterKey: "sk-or-v1-connected",
        openAIKey: "sk-openai"))

    #expect(resolved.key == "sk-oi-openinference")
    #expect(resolved.source == .proxyKey)
  }

  @Test("A proxy that accepts OpenAI keys still falls back to one")
  func openAIKeyRemainsTheGenericFallback() throws {
    let resolved = try #require(
      Prefs.resolveCredential(
        isOpenRouterEndpoint: false,
        proxyKey: nil,
        openRouterKey: "sk-or-v1-connected",
        openAIKey: "sk-openai"))

    #expect(resolved.key == "sk-openai")
    #expect(resolved.source == .openAIKey)
  }

  @Test("Whitespace-only keys count as absent rather than as a key")
  func blankKeysAreIgnored() throws {
    let resolved = try #require(
      Prefs.resolveCredential(
        isOpenRouterEndpoint: true,
        proxyKey: "   ",
        openRouterKey: "  sk-or-v1-padded \n",
        openAIKey: nil))

    #expect(resolved.key == "sk-or-v1-padded")
    #expect(resolved.source == .openRouterAccount)
  }

  @Test("Nothing configured resolves to nothing")
  func noKeysResolveToNil() {
    #expect(
      Prefs.resolveCredential(
        isOpenRouterEndpoint: false, proxyKey: nil, openRouterKey: nil, openAIKey: nil) == nil)
    #expect(
      Prefs.resolveCredential(
        isOpenRouterEndpoint: true, proxyKey: "", openRouterKey: "", openAIKey: "") == nil)
  }
}

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins the URL shaping and auth-header choice for a bring-your-own-endpoint deployment.
///
/// Everything here is the kind of mistake that only shows up as a 401 or a 404 against a real
/// tenant, which is exactly the thing a user cannot debug and we cannot reproduce without their
/// subscription. So the decisions are made in pure code and asserted here instead.
@Suite("Custom endpoint auth and URL shaping")
struct CustomEndpointAuthTests {

  private typealias Auth = CustomEndpointAuth

  // MARK: - Flavor detection

  @Test(
    "Azure hosts authenticate with api-key",
    arguments: [
      "https://my-resource.openai.azure.com/openai/v1",
      "https://my-resource.services.ai.azure.com/openai/v1",
      "https://my-resource.cognitiveservices.azure.com/openai/v1",
      "https://contoso-gateway.azure-api.net/openai/v1",
    ])
  func azureHostsUseAPIKeyHeader(base: String) {
    #expect(Auth.flavor(forBaseURL: base) == .azure)
    // Only `api-key`. Azure reads `Authorization` as an Entra token on the classic surface and
    // rejects the request rather than falling back to the key, so sending both is not "safer".
    #expect(Auth.headers(baseURL: base, apiKey: "secret") == ["api-key": "secret"])
  }

  @Test(
    "Everything else stays on Authorization: Bearer",
    arguments: [
      "https://openrouter.ai/api/v1",
      "https://openinference.de/api/v1",
      "http://localhost:11434/v1",
      "https://europe-west4-aiplatform.googleapis.com/v1/projects/p/locations/europe-west4/endpoints/openapi",
    ])
  func nonAzureHostsUseBearer(base: String) {
    #expect(Auth.flavor(forBaseURL: base) == .bearer)
    #expect(Auth.headers(baseURL: base, apiKey: "secret") == ["Authorization": "Bearer secret"])
  }

  @Test("A host that merely mentions azure is not an Azure tenant")
  func lookalikeHostsAreNotAzure() {
    // Suffix match, not substring: `azure.com.evil.example` and a proxy that happens to be named
    // after Azure must not have the user's key rewritten into an Azure-shaped header.
    #expect(Auth.flavor(forBaseURL: "https://azure.com.evil.example/v1") == .bearer)
    #expect(Auth.flavor(forBaseURL: "https://my-azure-proxy.example.com/v1") == .bearer)
  }

  @Test("An unparseable base URL falls back to bearer rather than guessing")
  func garbageFallsBackToBearer() {
    #expect(Auth.flavor(forBaseURL: "") == .bearer)
    #expect(Auth.flavor(forBaseURL: "not a url") == .bearer)
  }

  // MARK: - URL shaping

  @Test("The generic case is unchanged: append the path, collapse a trailing slash")
  func genericAppendIsUnchanged() {
    #expect(
      Auth.endpointURL(appending: "chat/completions", to: "https://openrouter.ai/api/v1")
        == "https://openrouter.ai/api/v1/chat/completions")
    #expect(
      Auth.endpointURL(appending: "chat/completions", to: "https://openrouter.ai/api/v1/")
        == "https://openrouter.ai/api/v1/chat/completions")
  }

  @Test("A base URL that already carries the path is left alone")
  func alreadyFullPathIsNotDoubled() {
    let full = "https://openinference.de/api/v1/chat/completions"
    #expect(Auth.endpointURL(appending: "chat/completions", to: full) == full)
  }

  @Test("A pasted full endpoint is stripped before the other route is appended")
  func pastedFullEndpointIsRewritten() throws {
    // The bug: only `hasSuffix` was checked, so a chat URL became
    // `…/v1/chat/completions/audio/transcriptions`.
    #expect(
      Auth.endpointURL(
        appending: "audio/transcriptions",
        to: "http://localhost:4000/v1/chat/completions")
        == "http://localhost:4000/v1/audio/transcriptions")
    #expect(
      Auth.endpointURL(
        appending: "chat/completions",
        to: "http://localhost:4000/v1/audio/transcriptions")
        == "http://localhost:4000/v1/chat/completions")
    #expect(
      Auth.endpointURL(
        appending: "audio/transcriptions",
        to: "http://localhost:4000/v1/completions")
        == "http://localhost:4000/v1/audio/transcriptions")

    let shaped = try #require(
      Auth.endpointURL(
        appending: "audio/transcriptions",
        to: "https://my-resource.openai.azure.com/openai/deployments/d/chat/completions?api-version=2025-01-01-preview"))
    let components = try #require(URLComponents(string: shaped))
    #expect(components.path == "/openai/deployments/d/audio/transcriptions")
    #expect(components.queryItems?.first { $0.name == "api-version" }?.value == "2025-01-01-preview")
  }

  @Test("A bare Azure resource host expands to the /openai/v1 surface")
  func bareAzureHostExpands() {
    // This is the form Azure's own portal shows, so it is the form users paste.
    #expect(
      Auth.endpointURL(appending: "chat/completions", to: "https://my-resource.openai.azure.com")
        == "https://my-resource.openai.azure.com/openai/v1/chat/completions")
  }

  @Test("The Azure v1 surface needs no api-version and gets none")
  func azureV1GetsNoAPIVersion() {
    let shaped = Auth.endpointURL(
      appending: "chat/completions", to: "https://my-resource.openai.azure.com/openai/v1")
    #expect(shaped == "https://my-resource.openai.azure.com/openai/v1/chat/completions")
    #expect(shaped?.contains("api-version") == false)
  }

  @Test("A classic Azure deployment URL gets the api-version it cannot work without")
  func classicAzureDeploymentGetsAPIVersion() throws {
    let shaped = try #require(
      Auth.endpointURL(
        appending: "chat/completions",
        to: "https://my-resource.openai.azure.com/openai/deployments/my-gpt5"))
    #expect(shaped.hasPrefix("https://my-resource.openai.azure.com/openai/deployments/my-gpt5/chat/completions?"))
    #expect(shaped.contains("api-version=\(Auth.fallbackAzureAPIVersion)"))
  }

  @Test("A user-supplied api-version survives path appending and is never overwritten")
  func userAPIVersionSurvives() throws {
    // The bug this pins: string concatenation produced
    // `…/deployments/d?api-version=2025-01-01-preview/chat/completions` — a 404 that looks like a
    // wrong deployment name.
    let shaped = try #require(
      Auth.endpointURL(
        appending: "chat/completions",
        to: "https://my-resource.openai.azure.com/openai/deployments/d?api-version=2025-01-01-preview"))

    let components = try #require(URLComponents(string: shaped))
    #expect(components.path == "/openai/deployments/d/chat/completions")
    #expect(components.queryItems?.filter { $0.name == "api-version" }.count == 1)
    #expect(components.queryItems?.first { $0.name == "api-version" }?.value == "2025-01-01-preview")
  }

  @Test("Transcription shares the same shaping, so Dictate reaches an Azure tenant too")
  func transcriptionPathIsShapedTheSameWay() {
    #expect(
      Auth.endpointURL(appending: "audio/transcriptions", to: "https://my-resource.openai.azure.com")
        == "https://my-resource.openai.azure.com/openai/v1/audio/transcriptions")
  }

  @Test("Vertex AI's openapi base takes the path without special-casing")
  func vertexBaseAppendsCleanly() {
    let base =
      "https://europe-west4-aiplatform.googleapis.com/v1/projects/p/locations/europe-west4/endpoints/openapi"
    #expect(Auth.endpointURL(appending: "chat/completions", to: base) == base + "/chat/completions")
  }

  @Test("An unusable base URL yields nil instead of a mangled string to POST at")
  func unusableBaseIsNil() {
    #expect(Auth.endpointURL(appending: "chat/completions", to: "") == nil)
    #expect(Auth.endpointURL(appending: "chat/completions", to: "   ") == nil)
    // No host — nothing to send to.
    #expect(Auth.endpointURL(appending: "chat/completions", to: "/openai/v1") == nil)
  }

  // MARK: - OpenAI-key fallback

  @Test("A tenant endpoint never falls back to the user's OpenAI key")
  func tenantEndpointsRefuseTheOpenAIFallback() {
    // Not a convenience question — a leak one. The fallback exists for proxies that forward to
    // api.openai.com on the caller's key; at an Azure resource or a Google project that key cannot
    // work, so sending it only hands an OpenAI credential to someone else's endpoint.
    #expect(Auth.acceptsOpenAIAPIKey(baseURL: "https://my-resource.openai.azure.com/openai/v1") == false)
    #expect(Auth.acceptsOpenAIAPIKey(baseURL: "https://contoso.azure-api.net/openai/v1") == false)
    #expect(
      Auth.acceptsOpenAIAPIKey(
        baseURL: "https://europe-west4-aiplatform.googleapis.com/v1/projects/p/locations/europe-west4/endpoints/openapi")
        == false)
  }

  @Test("A generic https proxy keeps the OpenAI fallback it has always had")
  func proxiesKeepTheOpenAIFallback() {
    #expect(Auth.acceptsOpenAIAPIKey(baseURL: "https://openinference.de/api/v1"))
    #expect(Auth.acceptsOpenAIAPIKey(baseURL: "https://litellm.example/v1"))
    #expect(Auth.acceptsOpenAIAPIKey(baseURL: ""))
  }

  @Test("A plain-http LAN host never falls back to the user's OpenAI key")
  func httpHostsRefuseTheOpenAIFallback() {
    // Cleartext LAN Whisper box: the OpenAI key must not ride along.
    #expect(Auth.acceptsOpenAIAPIKey(baseURL: "http://192.168.1.5/v1") == false)
    #expect(Auth.acceptsOpenAIAPIKey(baseURL: "http://10.0.0.8/v1") == false)
    #expect(
      OpenAIChatPreferences.resolveCredential(
        proxyKey: nil, openAIKey: "sk-openai", allowsOpenAIKeyFallback: false) == nil)
    #expect(Auth.headers(baseURL: "http://192.168.1.5/v1", apiKey: "") == [:])
    #expect(Auth.headers(baseURL: "http://192.168.1.5/v1", apiKey: "   ") == [:])
  }

  @Test("Loopback may receive the OpenAI key over http")
  func loopbackAcceptsTheOpenAIKeyOverHTTP() {
    // The key stays on this Mac. A local LiteLLM forwards it to api.openai.com.
    #expect(Auth.acceptsOpenAIAPIKey(baseURL: "http://localhost:4000/v1"))
    #expect(Auth.acceptsOpenAIAPIKey(baseURL: "http://127.0.0.1:8080/v1"))
    #expect(Auth.acceptsOpenAIAPIKey(baseURL: "http://127.255.255.255/v1"))
    #expect(Auth.acceptsOpenAIAPIKey(baseURL: "http://[::1]:4000/v1"))
  }

  @Test("A local host can run Chat and Dictate Prompt without any key")
  func localHostsAllowKeylessRequests() {
    #expect(OpenAIChatPreferences.allowsKeylessRequests(baseURL: "http://192.168.1.5/v1"))
    #expect(OpenAIChatPreferences.allowsKeylessRequests(baseURL: "http://localhost:4000/v1"))
    #expect(OpenAIChatPreferences.allowsKeylessRequests(baseURL: "http://127.0.0.1:8080/v1"))
    #expect(!OpenAIChatPreferences.allowsKeylessRequests(baseURL: "https://litellm.example/v1"))
    #expect(!OpenAIChatPreferences.allowsKeylessRequests(baseURL: ""))
  }

  @Test("With the fallback denied, an OpenAI key alone is not a usable credential")
  func openAIKeyAloneResolvesToNothingOnATenant() {
    let resolved = OpenAIChatPreferences.resolveCredential(
      proxyKey: nil,
      openAIKey: "sk-openai-personal",
      allowsOpenAIKeyFallback: false)
    #expect(resolved == nil)

    // The endpoint-specific key is still what runs the request when one is set.
    let withProxyKey = OpenAIChatPreferences.resolveCredential(
      proxyKey: "azure-resource-key",
      openAIKey: "sk-openai-personal",
      allowsOpenAIKeyFallback: false)
    #expect(withProxyKey?.key == "azure-resource-key")
    #expect(withProxyKey?.source == .proxyKey)
  }

  // MARK: - Body shape

  @Test("Azure follows OpenAI's max_completion_tokens rule; generic proxies keep max_tokens")
  func maxTokensKeyDiffersForAzure() {
    #expect(
      Auth.maxTokensKey(forBaseURL: "https://my-resource.openai.azure.com/openai/v1")
        == "max_completion_tokens")
    #expect(Auth.maxTokensKey(forBaseURL: "https://openrouter.ai/api/v1") == "max_tokens")
    #expect(Auth.maxTokensKey(forBaseURL: "http://localhost:11434/v1") == "max_tokens")
  }
}

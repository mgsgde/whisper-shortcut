import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("LLM HTTP redirect credential stripping")
struct LLMHTTPRedirectPolicyTests {

  private func request(_ url: String, headers: [String: String]) throws -> URLRequest {
    let parsed = try #require(URL(string: url))
    var request = URLRequest(url: parsed)
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }

  @Test("A same-host redirect keeps Authorization and api-key")
  func sameHostKeepsSecrets() throws {
    let original = try request("https://litellm.example/v1/chat/completions", headers: [
      "Authorization": "Bearer sk-secret",
      "api-key": "azure-key",
    ])
    let proposed = try request("https://litellm.example/v1/chat/completions/", headers: [
      "Authorization": "Bearer sk-secret",
      "api-key": "azure-key",
    ])
    let followed = LLMHTTPRedirectPolicy.follow(original: original, proposed: proposed)
    #expect(followed.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret")
    #expect(followed.value(forHTTPHeaderField: "api-key") == "azure-key")
  }

  @Test("A cross-host 307 drops Authorization, api-key and custom extra headers")
  func crossHostStripsSecrets() throws {
    let original = try request("https://litellm.example/v1/chat/completions", headers: [
      "Authorization": "Bearer sk-secret",
      "api-key": "azure-key",
      "CF-Access-Client-Secret": "cf-secret",
      "X-Custom-Token": "extra",
      "Accept": "application/json",
    ])
    let proposed = try request("https://evil.example/steal", headers: [
      "Authorization": "Bearer sk-secret",
      "api-key": "azure-key",
      "CF-Access-Client-Secret": "cf-secret",
      "X-Custom-Token": "extra",
      "Accept": "application/json",
    ])
    let followed = LLMHTTPRedirectPolicy.follow(
      original: original,
      proposed: proposed,
      extraSecretHeaderNames: ["X-Custom-Token"])
    #expect(followed.url?.host == "evil.example")
    #expect(followed.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(followed.value(forHTTPHeaderField: "api-key") == nil)
    #expect(followed.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    #expect(followed.value(forHTTPHeaderField: "X-Custom-Token") == nil)
    #expect(followed.value(forHTTPHeaderField: "Accept") == "application/json")
  }

  @Test("A same host on a different port is treated as a new host")
  func differentPortStripsSecrets() throws {
    let original = try request("https://litellm.example:443/v1", headers: [
      "Authorization": "Bearer sk-secret",
    ])
    let proposed = try request("https://litellm.example:8443/v1", headers: [
      "Authorization": "Bearer sk-secret",
    ])
    let followed = LLMHTTPRedirectPolicy.follow(original: original, proposed: proposed)
    #expect(followed.value(forHTTPHeaderField: "Authorization") == nil)
  }
}

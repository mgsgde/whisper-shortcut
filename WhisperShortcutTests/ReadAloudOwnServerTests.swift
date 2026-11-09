import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Read Aloud's own-server option is the fourth route of the shared own-server section: same URL,
/// key and headers as Dictate and Chat, offered only once a base URL exists.
@Suite("Read Aloud own server", .serialized)
struct ReadAloudOwnServerTests {

  private let urlKey = UserDefaultsKeys.customOpenAIChatEndpointURL

  private func withBaseURL(_ value: String?, _ body: () -> Void) {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: urlKey)
    if let value { defaults.set(value, forKey: urlKey) } else { defaults.removeObject(forKey: urlKey) }
    defer {
      if let previous { defaults.set(previous, forKey: urlKey) } else { defaults.removeObject(forKey: urlKey) }
    }
    body()
  }

  @Test("The Read Aloud route shows neither the Dictate nor the Chat model field")
  func readAloudRouteFields() {
    typealias Route = OwnServerEndpointSection.Route
    #expect(!Route.readAloud.showsTranscriptionModel)
    #expect(!Route.readAloud.showsChatModel)
    #expect(Route.readAloud.showsSpeechFields)
    for route in [Route.dictate, .dictatePrompt, .chat] { #expect(!route.showsSpeechFields) }
    #expect(Route.dictate.showsTranscriptionModel && !Route.dictate.showsChatModel)
    #expect(!Route.chat.showsTranscriptionModel && Route.chat.showsChatModel)
    #expect(Route.dictatePrompt.showsTranscriptionModel && Route.dictatePrompt.showsChatModel)
  }

  @Test("Own-server TTS is unavailable without a base URL and available with one")
  func availabilityFollowsBaseURL() {
    withBaseURL(nil) {
      #expect(!TTSModel.ownServerTTS.hasRequiredCredential)
      #expect(CustomEndpointPreferences.ttsURL == nil)
    }
    withBaseURL("   ") { #expect(!TTSModel.ownServerTTS.hasRequiredCredential) }
    withBaseURL("http://localhost:4000/v1") { #expect(TTSModel.ownServerTTS.hasRequiredCredential) }
  }

  @Test("The own server is a server, not an on-device voice, and is listed after the cloud voices")
  func providerFlagsAndOrder() {
    #expect(!TTSProvider.custom.isOnDevice)
    let models = TTSModel.readAloudModels
    #expect(models.last == .ownServerTTS)
    #expect(models.firstIndex(of: .grokVoiceTTS)! < models.firstIndex(of: .ownServerTTS)!)
  }

  @Test("The speech URL is {base}/audio/speech for a plain and an Azure base URL")
  func speechURLShaping() {
    withBaseURL("http://localhost:4000/v1") {
      #expect(CustomEndpointPreferences.ttsURL == "http://localhost:4000/v1/audio/speech")
    }
    let azure = "https://res.openai.azure.com/openai/v1"
    withBaseURL(azure) {
      #expect(CustomEndpointPreferences.ttsURL == CustomEndpointAuth.endpointURL(appending: "audio/speech", to: azure))
      #expect(CustomEndpointPreferences.ttsURL?.contains("/audio/speech") == true)
    }
  }

  @Test("Key resolution falls back to the OpenAI key like Chat, never for a tenant host")
  func keyResolution() throws {
    let https = "https://litellm.example.com/v1"
    #expect(try SpeechService.customTTSCredential(baseURL: https, proxyKey: "proxy", openAIKey: "sk-open") == "proxy")
    #expect(try SpeechService.customTTSCredential(baseURL: https, proxyKey: nil, openAIKey: "sk-open") == "sk-open")
    #expect(throws: (any Error).self) {
      try SpeechService.customTTSCredential(baseURL: https, proxyKey: " ", openAIKey: nil)
    }
    // Azure never receives the OpenAI key.
    #expect(throws: (any Error).self) {
      try SpeechService.customTTSCredential(
        baseURL: "https://res.openai.azure.com/openai/v1", proxyKey: nil, openAIKey: "sk-open")
    }
    // A keyless local server is fine.
    #expect(try SpeechService.customTTSCredential(baseURL: "http://localhost:8000/v1", proxyKey: nil, openAIKey: nil) == "")
  }

  @Test("The request carries a bearer key plus extra headers; Azure gets only api-key")
  func requestHeaders() throws {
    let plainURL = URL(string: "https://litellm.example.com/v1/audio/speech")!
    let plain = try SpeechService.customTTSRequest(
      url: plainURL, baseURL: "https://litellm.example.com/v1", apiKey: "k",
      extraHeaders: ["X-Team": "a"], model: "tts-1", voice: "alloy", text: "Hallo")
    #expect(plain.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    #expect(plain.value(forHTTPHeaderField: "X-Team") == "a")
    #expect(plain.value(forHTTPHeaderField: "api-key") == nil)
    let bodyData = try #require(plain.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(body["model"] as? String == "tts-1")
    #expect(body["voice"] as? String == "alloy")
    #expect(body["input"] as? String == "Hallo")

    let azureURL = URL(string: "https://res.openai.azure.com/openai/v1/audio/speech")!
    let azure = try SpeechService.customTTSRequest(
      url: azureURL, baseURL: "https://res.openai.azure.com/openai/v1", apiKey: "k",
      extraHeaders: [:], model: "tts-1", voice: "alloy", text: "x")
    #expect(azure.value(forHTTPHeaderField: "api-key") == "k")
    #expect(azure.value(forHTTPHeaderField: "Authorization") == nil)

    let keyless = try SpeechService.customTTSRequest(
      url: plainURL, baseURL: "http://localhost:8000/v1", apiKey: "",
      extraHeaders: [:], model: "tts-1", voice: "alloy", text: "x")
    #expect(keyless.value(forHTTPHeaderField: "Authorization") == nil)
  }
}

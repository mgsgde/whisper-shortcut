import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@MainActor
@Suite("Improve model")
struct ImproveModelTests {
  @Test func capableCurrentWithKeyKeeps() {
    let c = ChatViewModel.improveModelChoice(current: .claudeOpus55, hasCredential: { _ in true })
    #expect(c == .keep)
  }

  @Test func customEndpointFallsToGemini() {
    let c = ChatViewModel.improveModelChoice(
      current: .customOpenAIEndpoint,
      hasCredential: { $0 == .gemini31Pro || $0 == .customOpenAIEndpoint })
    #expect(c == .use(.gemini31Pro))
  }

  @Test func noGeminiKeyFallsToClaude() {
    let c = ChatViewModel.improveModelChoice(
      current: .customOpenAIEndpoint, hasCredential: { $0 == .claudeSonnet55 })
    #expect(c == .use(.claudeSonnet55))
  }

  @Test func noKeysNoneAvailable() {
    let c = ChatViewModel.improveModelChoice(current: .customOpenAIEndpoint, hasCredential: { _ in false })
    #expect(c == .noneAvailable)
  }

  @Test func capableCurrentWithoutKeyFallsToPreferred() {
    let c = ChatViewModel.improveModelChoice(current: .grok47, hasCredential: { $0 == .claudeSonnet55 })
    #expect(c == .use(.claudeSonnet55))
  }

  @Test func effectiveModelNilIsGlobal() {
    let m = ChatViewModel.effectiveModel(override: nil, global: .grok47, hasCredential: { _ in true })
    #expect(m == .grok47)
  }

  @Test func effectiveModelValidOverride() {
    let m = ChatViewModel.effectiveModel(
      override: PromptModel.gemini31Pro.rawValue, global: .grok47, hasCredential: { _ in true })
    #expect(m == .gemini31Pro)
  }

  @Test func effectiveModelUnknownRawValueIsGlobal() {
    let m = ChatViewModel.effectiveModel(
      override: "no-such-model", global: .grok47, hasCredential: { _ in true })
    #expect(m == .grok47)
  }

  @Test func effectiveModelWithoutCredentialIsGlobal() {
    let m = ChatViewModel.effectiveModel(
      override: PromptModel.gemini31Pro.rawValue, global: .grok47, hasCredential: { _ in false })
    #expect(m == .grok47)
  }

  @Test func sessionDecodesOldJSONAndRoundTripsOverride() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let data = try encoder.encode(ChatSession())
    var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    obj.removeValue(forKey: "modelOverride")
    let stripped = try JSONSerialization.data(withJSONObject: obj)
    #expect(try decoder.decode(ChatSession.self, from: stripped).modelOverride == nil)

    var s = ChatSession()
    s.modelOverride = PromptModel.claudeSonnet55.rawValue
    let back = try decoder.decode(ChatSession.self, from: try encoder.encode(s))
    #expect(back.modelOverride == PromptModel.claudeSonnet55.rawValue)
  }
}

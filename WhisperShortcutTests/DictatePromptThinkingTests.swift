import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Dictate Prompt Gemini thinking")
struct DictatePromptThinkingTests {

  @Test("Chat high and medium become low; minimal stays; non-Gemini is nil")
  func thinkingLevel() {
    #expect(PromptModel.gemini38Flash.dictatePromptThinkingLevel == "low")
    #expect(PromptModel.gemini31Pro.dictatePromptThinkingLevel == "low")
    #expect(PromptModel.gemini4Argon.dictatePromptThinkingLevel == "low")
    #expect(PromptModel.gemini31FlashLite.dictatePromptThinkingLevel == "minimal")
    #expect(PromptModel.openaiGPT6Sol.dictatePromptThinkingLevel == nil)
  }

  @Test("Agent-path low thinking stays valid on every Gemini model")
  func agentPathLowThinking() throws {
    let client = GeminiAPIClient()
    let schema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]
    let contents: [[String: Any]] = [["role": "user", "parts": [["text": "x"]]]]
    let sendsLow: [PromptModel] = [
      .gemini4Argon, .gemini31Pro, .gemini38Flash, .gemini31FlashLite, .gemini35FlashLite,
    ]
    let sendsNone: [PromptModel] = [.geminiImage, .geminiImagePro]
    let gemini = PromptModel.allCases.filter { $0.provider == .gemini }
    #expect(Set(gemini) == Set(sendsLow + sendsNone))
    for model in sendsLow {
      let level = try thinkingLevel(client, model: model, contents: contents, schema: schema)
      #expect(level == "low", "\(model.rawValue)")
    }
    for model in sendsNone {
      let level = try thinkingLevel(client, model: model, contents: contents, schema: schema)
      #expect(level == nil, "\(model.rawValue)")
    }
  }

  private func thinkingLevel(
    _ client: GeminiAPIClient, model: PromptModel, contents: [[String: Any]], schema: [String: Any]
  ) throws -> String? {
    let body = client.structuredRequestBody(
      model: model.rawValue, contents: contents, systemInstruction: nil, schema: schema,
      thinkingLevel: .low)
    let generation = try #require(body["generationConfig"] as? [String: Any])
    let thinking = generation["thinkingConfig"] as? [String: Any]
    return thinking?["thinkingLevel"] as? String
  }

  @Test("Encoded request sends thinkingLevel and omits thinkingBudget")
  func encodedRequestOmitsBudget() throws {
    let config = try #require(SpeechService.dictatePromptGenerationConfig(for: .gemini38Flash))
    let request = GeminiChatRequest(
      contents: [GeminiChatRequest.GeminiChatContent(role: "user", parts: [])],
      systemInstruction: nil,
      tools: nil,
      generationConfig: config,
      model: nil)
    let json = try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))
    #expect(json.contains("\"thinkingConfig\":{\"thinkingLevel\":\"low\"}"))
    #expect(!json.contains("thinkingBudget"))
  }
}

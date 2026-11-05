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

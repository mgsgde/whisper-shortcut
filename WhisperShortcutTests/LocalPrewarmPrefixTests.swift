import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The local warm-up only helps if the server renders the same prefix as the real request. With
/// tools, that prefix is the tool preamble + the Dictate Prompt system prompt + the tool
/// definitions — the warm-up used to prime the prompt alone.
@Suite("Local prewarm prefix")
struct LocalPrewarmPrefixTests {

  private let tool = LLMToolDeclaration(
    name: "list_workspace_folders", description: "d", parameters: ["type": "object"])

  @Test("The warm-up body carries the same system message and tools as the agent request")
  func samePrefix() throws {
    let base = SpeechService.buildDictatePromptSystemPrompt(
      logPrefix: "TEST", usesScreenshotSelection: false)

    // What the agent path sends: system instruction → converter → messages, tools in the body.
    let agentSystem: [String: Any] = ["parts": [["text": DictatePromptAgent.systemPrompt(for: base)]]]
    let agentMessages = OpenAIChatCompletionsConverter.messages(
      from: [["role": "user", "parts": [["text": "x"]]]], systemInstruction: agentSystem)
    let agentBody = LocalLLMChatProvider.requestBody(
      model: "m", messages: agentMessages, stream: true, maxTokens: 10, tools: [tool])

    // What the warm-up sends with tools available.
    let warmBody = LocalLLMChatProvider.requestBody(
      model: "m",
      messages: [
        ["role": "system", "content": DictatePromptAgent.systemPrompt(for: base)],
        ["role": "user", "content": "hi"],
      ],
      stream: false, maxTokens: 1, tools: [tool])

    let agentFirst = try #require((agentBody["messages"] as? [[String: Any]])?.first)
    let warmFirst = try #require((warmBody["messages"] as? [[String: Any]])?.first)
    #expect(agentFirst["role"] as? String == "system")
    #expect(agentFirst["content"] as? String == warmFirst["content"] as? String)

    let agentTools = try JSONSerialization.data(withJSONObject: agentBody["tools"] ?? [], options: .sortedKeys)
    let warmTools = try JSONSerialization.data(withJSONObject: warmBody["tools"] ?? [], options: .sortedKeys)
    #expect(agentTools == warmTools)
    #expect((warmBody["tools"] as? [Any])?.count == 1)
  }

  @Test("Without tools the body has no tools key, as before")
  func noToolsNoKey() {
    let body = LocalLLMChatProvider.requestBody(
      model: "m", messages: [], stream: false, maxTokens: 1)
    #expect(body["tools"] == nil)
  }
}

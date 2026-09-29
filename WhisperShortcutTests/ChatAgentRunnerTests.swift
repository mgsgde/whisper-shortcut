import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Pins the agent loop now that it runs outside the chat window (`ChatAgentRunner`).
///
/// These are the behaviours the chat relied on while the loop lived inline in `performSend`:
/// tool results fed back to the model, records kept for history, the round cap ending in a
/// tool-less final round, and a denied approval never reaching the tool.
@MainActor
@Suite("Chat agent runner")
struct ChatAgentRunnerTests {

  /// Replays one scripted round per request and remembers what each request carried.
  final class ScriptedProvider: LLMChatProvider {
    var rounds: [[ChatStreamEvent]]
    /// When the script runs out, repeat the last round (to model a model that never stops).
    var repeatLast = false
    private(set) var requests: [(contents: [[String: Any]], toolCount: Int, disableBuiltIns: Bool)] = []

    init(_ rounds: [[ChatStreamEvent]]) { self.rounds = rounds }

    func sendChatStream(
      model: String, contents: [[String: Any]], systemInstruction: [String: Any]?,
      tools: [LLMToolDeclaration], options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
      requests.append((contents, tools.count, options.disableBuiltInTools))
      let events: [ChatStreamEvent]
      if !rounds.isEmpty && !(repeatLast && rounds.count == 1) {
        events = rounds.removeFirst()
      } else {
        events = rounds.first ?? []
      }
      return AsyncThrowingStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
      }
    }

    func generateStructured(
      model: String, contents: [[String: Any]], systemInstruction: [String: Any]?,
      schema: [String: Any], schemaName: String, thinkingLevel: ThinkingLevel
    ) async throws -> [String: Any] { [:] }
  }

  private let tool = LLMToolDeclaration(
    name: "fake_lookup", description: "test", parameters: ["type": "object", "properties": [:] as [String: Any]])

  private func makeRunner(
    _ provider: ScriptedProvider,
    maxToolRounds: Int = 16,
    handlers: [String: ChatToolContext.Handler] = [:],
    approve: @escaping (String, String, UUID) async -> Bool = { _, _, _ in true }
  ) -> ChatAgentRunner {
    ChatAgentRunner(
      provider: provider, model: "test-model", tools: [tool], maxToolRounds: maxToolRounds,
      steps: ToolStepsBuffer(),
      systemInstruction: { ["parts": [["text": "sys"]]] },
      options: { isFinal in ChatRequestOptions(disableBuiltInTools: isFinal) },
      toolContext: { ChatToolContext(sessionHandlers: handlers) },
      approve: approve,
      onDisplayText: { _, _ in })
  }

  @Test("A text-only turn returns the text and no tool records")
  func textOnly() async throws {
    let provider = ScriptedProvider([[.textDelta("Hello"), .textDelta(" there")]])
    let result = try await makeRunner(provider).run(contents: [["role": "user", "parts": [["text": "hi"]]]])
    #expect(result.text == "Hello there")
    #expect(result.records.isEmpty)
    #expect(result.executedToolCalls == 0)
    #expect(provider.requests.count == 1)
  }

  @Test("A tool call's result goes back to the model and is recorded")
  func toolRoundTrip() async throws {
    let provider = ScriptedProvider([
      [.functionCall(name: "fake_lookup", args: ["q": "x"], thoughtSignature: nil)],
      [.textDelta("Found it: C42")],
    ])
    let runner = makeRunner(provider, handlers: [
      "fake_lookup": { _ in ChatToolOutcome(response: ["id": "C42"]) }
    ])
    let result = try await runner.run(contents: [["role": "user", "parts": [["text": "find"]]]])

    #expect(result.text == "Found it: C42")
    #expect(result.executedToolCalls == 1)
    #expect(result.records.map(\.name) == ["fake_lookup"])
    #expect(result.records.first?.resultJSON.contains("C42") == true)
    // Second request carries the model's call turn and the tool response turn.
    let second = provider.requests[1].contents
    #expect(second.count == 3)
    let responsePart = (second[2]["parts"] as? [[String: Any]])?.first
    #expect(responsePart?["functionResponse"] != nil)
  }

  @Test("The round cap ends with a tool-less final round and reports exhaustion")
  func roundCap() async throws {
    let provider = ScriptedProvider([
      [.functionCall(name: "fake_lookup", args: [:], thoughtSignature: nil)]
    ])
    provider.repeatLast = true
    let runner = makeRunner(provider, maxToolRounds: 2, handlers: [
      "fake_lookup": { _ in ChatToolOutcome(response: ["ok": true]) }
    ])
    let result = try await runner.run(contents: [["role": "user", "parts": [["text": "loop"]]]])

    #expect(result.toolLoopExhausted)
    #expect(result.executedToolCalls == 2)
    #expect(provider.requests.count == 3)
    #expect(provider.requests.last?.toolCount == 0)
    #expect(provider.requests.last?.disableBuiltIns == true)
  }

  @Test("A denied approval never runs the tool and tells the model")
  func deniedApproval() async throws {
    let provider = ScriptedProvider([
      [.functionCall(name: "remember_about_user", args: ["fact": "x"], thoughtSignature: nil)],
      [.textDelta("Okay, not saved.")],
    ])
    var ran = false
    let runner = makeRunner(
      provider,
      handlers: ["remember_about_user": { _ in ran = true; return ChatToolOutcome(response: ["ok": true]) }],
      approve: { _, _, _ in false })
    let result = try await runner.run(contents: [["role": "user", "parts": [["text": "remember"]]]])

    #expect(!ran)
    #expect(result.records.first?.resultJSON.contains("denied") == true)
    #expect(result.text == "Okay, not saved.")
  }
}

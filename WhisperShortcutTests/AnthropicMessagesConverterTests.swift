import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Opus 5.5 / Sonnet 5.5 think on every request and reject a tool loop whose assistant turn comes
/// back without its thinking blocks (HTTP 400). These pin the round trip through the opaque
/// `thoughtSignature` string that the chat loop carries.
@Suite("Anthropic thinking round-trip")
struct AnthropicMessagesConverterTests {

  private let thinking: [[String: Any]] = [
    ["type": "thinking", "thinking": "", "signature": "sig-abc"],
    ["type": "redacted_thinking", "data": "opaque"],
  ]

  @Test("Envelope round-trips id and thinking; a bare id still decodes")
  func envelopeRoundTrip() {
    let encoded = AnthropicToolCallEnvelope.encode(toolUseId: "toolu_1", thinking: thinking)
    let decoded = AnthropicToolCallEnvelope.decode(encoded)
    #expect(decoded.toolUseId == "toolu_1")
    #expect(decoded.thinking.count == 2)
    #expect(decoded.thinking[0]["signature"] as? String == "sig-abc")

    #expect(AnthropicToolCallEnvelope.encode(toolUseId: "toolu_2", thinking: []) == "toolu_2")
    let legacy = AnthropicToolCallEnvelope.decode("toolu_3")
    #expect(legacy.toolUseId == "toolu_3")
    #expect(legacy.thinking.isEmpty)
  }

  private func toolTurn(signature: String) -> [String: Any] {
    [
      "role": "model",
      "parts": [
        ["text": "Looking that up."],
        ["functionCall": ["name": "get_time", "args": [:] as [String: Any]], "thoughtSignature": signature],
      ],
    ]
  }

  private let toolResult: [String: Any] = [
    "role": "user",
    "parts": [["functionResponse": ["name": "get_time", "response": ["time": "08:00"]]]],
  ]

  @Test("Open tool loop: thinking leads the assistant turn, ids pair with tool_result")
  func openLoopKeepsThinking() {
    let sig = AnthropicToolCallEnvelope.encode(toolUseId: "toolu_1", thinking: thinking)
    let messages = AnthropicMessagesConverter.messages(from: [
      ["role": "user", "parts": [["text": "What time is it?"]]],
      toolTurn(signature: sig),
      toolResult,
    ])
    #expect(messages.count == 3)
    let blocks = messages[1]["content"] as? [[String: Any]] ?? []
    #expect(blocks.map { $0["type"] as? String } == ["thinking", "redacted_thinking", "text", "tool_use"])
    #expect(blocks[3]["id"] as? String == "toolu_1")
    let results = messages[2]["content"] as? [[String: Any]] ?? []
    #expect(results.first?["tool_use_id"] as? String == "toolu_1")
  }

  @Test("Interleaved thinking keeps its position between parallel tool calls")
  func interleavedThinkingKeepsOrder() {
    let layout = [
      AnthropicToolCallEnvelope.thinkingSlot(0), AnthropicToolCallEnvelope.textSlot,
      AnthropicToolCallEnvelope.toolUseSlot("toolu_1"), AnthropicToolCallEnvelope.thinkingSlot(1),
      AnthropicToolCallEnvelope.toolUseSlot("toolu_2"),
    ]
    let sig = AnthropicToolCallEnvelope.encode(toolUseId: "toolu_1", thinking: thinking, layout: layout)
    let turn: [String: Any] = [
      "role": "model",
      "parts": [
        ["text": "Checking both."],
        ["functionCall": ["name": "a", "args": [:] as [String: Any]], "thoughtSignature": sig],
        ["functionCall": ["name": "b", "args": [:] as [String: Any]], "thoughtSignature": "toolu_2"],
      ],
    ]
    let messages = AnthropicMessagesConverter.messages(from: [
      ["role": "user", "parts": [["text": "Go"]]], turn,
    ])
    let blocks = messages[1]["content"] as? [[String: Any]] ?? []
    #expect(blocks.map { $0["type"] as? String }
      == ["thinking", "text", "tool_use", "redacted_thinking", "tool_use"])
    #expect(blocks[4]["id"] as? String == "toolu_2")
  }

  @Test("A web search before a client tool call is replayed in place, verbatim")
  func webSearchBlocksKeepPosition() {
    let preserved: [[String: Any]] = [
      ["type": "thinking", "thinking": "", "signature": "sig-abc"],
      ["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": ["query": "q"]],
      ["type": "web_search_tool_result", "tool_use_id": "srvtoolu_1",
       "content": [["type": "web_search_result", "url": "https://a.example", "encrypted_content": "enc"]]],
    ]
    let layout = [
      AnthropicToolCallEnvelope.thinkingSlot(0), AnthropicToolCallEnvelope.textSlot,
      AnthropicToolCallEnvelope.thinkingSlot(1), AnthropicToolCallEnvelope.thinkingSlot(2),
      AnthropicToolCallEnvelope.toolUseSlot("toolu_1"),
    ]
    let sig = AnthropicToolCallEnvelope.encode(toolUseId: "toolu_1", thinking: preserved, layout: layout)
    let messages = AnthropicMessagesConverter.messages(from: [
      ["role": "user", "parts": [["text": "What time is it?"]]],
      toolTurn(signature: sig),
      toolResult,
    ])
    let blocks = messages[1]["content"] as? [[String: Any]] ?? []
    #expect(blocks.map { $0["type"] as? String }
      == ["thinking", "text", "server_tool_use", "web_search_tool_result", "tool_use"])
    let result = blocks[3]["content"] as? [[String: Any]]
    #expect(result?.first?["encrypted_content"] as? String == "enc")
  }

  @Test("Closed tool loop from an earlier question drops its thinking")
  func closedLoopDropsThinking() {
    let sig = AnthropicToolCallEnvelope.encode(toolUseId: "toolu_1", thinking: thinking)
    let messages = AnthropicMessagesConverter.messages(from: [
      ["role": "user", "parts": [["text": "What time is it?"]]],
      toolTurn(signature: sig),
      toolResult,
      ["role": "model", "parts": [["text": "It is 08:00."]]],
      ["role": "user", "parts": [["text": "Thanks. And the date?"]]],
    ])
    let blocks = messages[1]["content"] as? [[String: Any]] ?? []
    #expect(blocks.map { $0["type"] as? String } == ["text", "tool_use"])
    #expect(blocks[1]["id"] as? String == "toolu_1")
  }
}

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

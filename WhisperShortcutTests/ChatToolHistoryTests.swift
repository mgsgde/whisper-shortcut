import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Pins the chat's memory of its own tool calls.
///
/// The failure this guards against: a follow-up like "move that card" arriving with no card ID,
/// because only the reply text survived the turn. The records must survive a restart (Codable),
/// be replayed as text (so a `/model` switch cannot break provider call-ID pairing), and stay
/// small enough that a 100 KB file read does not ride along on every later turn.
@MainActor
@Suite("Chat tool history")
struct ChatToolHistoryTests {

  @Test("Records pair calls with responses and cap large results")
  func recordsCapLargeResults() {
    let big = String(repeating: "x", count: ChatToolHistory.maxResultChars * 3)
    let records = ChatToolHistory.records(
      calls: [("trello_list_cards", ["list_id": "L1"]), ("read_text_file", ["path": "/a.md"])],
      responses: [["cards": [["id": "C42", "name": "Ship it"]]], ["content": big]])

    #expect(records.count == 2)
    #expect(records[0].name == "trello_list_cards")
    #expect(records[0].resultJSON.contains("C42"))
    #expect(records[1].resultJSON.count < ChatToolHistory.maxResultChars + 100)
    #expect(records[1].resultJSON.hasSuffix("call the tool again for the full result]"))
  }

  @Test("History text carries IDs and is bounded per message")
  func historyTextIsBounded() {
    let one = ChatToolCallRecord(name: "google_tasks_create", argsJSON: #"{"title":"Dentist"}"#, resultJSON: #"{"id":"T7"}"#)
    let text = ChatToolHistory.historyText(for: [one])
    #expect(text?.contains("T7") == true)
    #expect(text?.hasPrefix(ChatToolHistory.blockHeader) == true)
    #expect(ChatToolHistory.historyText(for: []) == nil)

    let filler = String(repeating: "y", count: ChatToolHistory.maxResultChars)
    let many = (0..<20).map { ChatToolCallRecord(name: "t\($0)", argsJSON: "{}", resultJSON: filler) }
    let capped = ChatToolHistory.historyText(for: many) ?? ""
    #expect(capped.count < ChatToolHistory.maxBlockChars + 500)
    #expect(capped.contains("more tool call(s) omitted"))
  }

  @Test("Only the newest assistant messages replay their tool calls")
  func replayWindow() {
    let record = ChatToolCallRecord(name: "t", argsJSON: "{}", resultJSON: "{}")
    let limit = ChatToolHistory.replayedMessageLimit
    let messages = (0..<(limit + 3)).map { _ in
      ChatMessage(role: .model, content: "ok", toolCalls: [record])
    } + [ChatMessage(role: .model, content: "no tools")]

    let replayed = ChatToolHistory.replayedMessageIDs(in: messages)
    #expect(replayed.count == limit)
    #expect(replayed.contains(messages[limit + 2].id))
    #expect(!replayed.contains(messages[0].id))
  }

  @Test("Tool calls survive encode/decode, and old messages without them still decode")
  func codableRoundTrip() throws {
    let record = ChatToolCallRecord(name: "t", argsJSON: #"{"a":1}"#, resultJSON: #"{"ok":true}"#)
    let message = ChatMessage(role: .model, content: "done", toolCalls: [record])
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
    #expect(decoded.toolCalls == [record])

    let legacy = ChatMessage(role: .model, content: "old")
    let legacyData = try JSONEncoder().encode(legacy)
    #expect(String(data: legacyData, encoding: .utf8)?.contains("toolCalls") == false)
    #expect(try JSONDecoder().decode(ChatMessage.self, from: legacyData).toolCalls.isEmpty)
  }

  @Test("Memory, instruction and file-write tools need approval; reading instructions does not")
  func injectionSensitiveToolsAreGated() {
    for name in ["remember_about_user", "write_text_file", "append_to_file", "edit_text_file"] {
      #expect(ChatToolRegistry.requiresUserApproval(name))
    }
    let instructions = ChatToolRegistry.updateInstructionsToolName
    #expect(!ChatToolRegistry.requiresUserApproval(instructions, args: ["action": "read"]))
    #expect(ChatToolRegistry.requiresUserApproval(instructions, args: ["action": "append", "text": "x"]))
    #expect(!ChatToolRegistry.requiresUserApproval("read_text_file"))

    let summary = ChatToolRegistry.approvalSummary(
      name: "remember_about_user", args: ["fact": "Prefers German replies"])
    #expect(summary.contains("Prefers German replies"))
  }
}

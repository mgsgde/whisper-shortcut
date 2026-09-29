import Foundation

/// One tool call the model made while producing an assistant message, kept so later turns still
/// know what happened: event/task/card IDs, what was created, what a search returned.
///
/// Before this, only the final reply text was persisted, so a follow-up like "move that card"
/// arrived with no card ID — even though the tool descriptions demand IDs "returned earlier in
/// THIS conversation". The record is stored per message (`ChatMessage.toolCalls`) and replayed as
/// a compact text block by `ChatToolHistory.historyText`, never as structured function-call turns:
/// provider call IDs (OpenAI `fc_…` items that need their reasoning item, Anthropic `toolu_…`,
/// Gemini signatures bound to one model) do not survive a `/model` switch, text does.
struct ChatToolCallRecord: Codable, Equatable {
  let name: String
  /// Arguments as compact JSON.
  let argsJSON: String
  /// Tool response as compact JSON, already capped at `ChatToolHistory.maxResultChars`.
  let resultJSON: String

  // Display-only fields for the transcript's tool-step rows (plans/active/chat-tool-steps.md,
  // Slice 2). Optional: records written before them decode with nil and are derived from
  // `resultJSON` instead (`ChatToolStepDisplay`). Not part of the model replay.
  enum Status: String, Codable { case done, failed, denied }
  var status: Status? = nil
  /// "3 results", or the error text for `.failed`.
  var summary: String? = nil
  var durationMs: Int? = nil
}

enum ChatToolHistory {
  /// Per-result cap when persisting. Enough for IDs, titles and a handful of list rows; a
  /// 100 KB file read is not worth re-sending on every later turn — the model can call again.
  static let maxResultChars = 3_000
  /// Per-message cap for the replayed block, so one batch-heavy turn cannot dominate history.
  static let maxBlockChars = 12_000
  /// Only the newest assistant messages with tool calls replay them; older records stay on disk
  /// but are not sent, which bounds the token cost of long sessions.
  static let replayedMessageLimit = 10

  static let blockHeader = "[Tool calls made while writing this reply — private context, not shown to the user]"
  static let blockFooter = "[End of tool calls]"

  /// Builds persistable records from one round's calls and their responses (same order).
  /// `steps`, when given, is the live step of each call (same order) and supplies the display fields.
  static func records(
    calls: [(name: String, args: [String: Any])],
    responses: [[String: Any]],
    steps: [ChatToolStep?] = []
  ) -> [ChatToolCallRecord] {
    zip(calls, responses).enumerated().map { index, pair in
      let (call, response) = pair
      var record = ChatToolCallRecord(
        name: call.name,
        argsJSON: compactJSON(call.args),
        resultJSON: capped(compactJSON(response), limit: maxResultChars))
      if index < steps.count, let step = steps[index] {
        switch step.phase {
        case .done: record.status = .done
        case .failed: record.status = .failed
        case .denied: record.status = .denied
        case .running, .awaitingApproval: break
        }
        record.summary = step.resultSummary
        record.durationMs = step.finishedAt.map { Int($0.timeIntervalSince(step.startedAt) * 1000) }
      }
      return record
    }
  }

  /// The text block prepended to an assistant turn in the request history. Nil when empty.
  static func historyText(for records: [ChatToolCallRecord]) -> String? {
    guard !records.isEmpty else { return nil }
    var lines: [String] = []
    var used = 0
    for (index, record) in records.enumerated() {
      let line = "- \(record.name)(\(record.argsJSON)) → \(record.resultJSON)"
      if used + line.count > maxBlockChars {
        lines.append("- …\(records.count - index) more tool call(s) omitted")
        break
      }
      lines.append(line)
      used += line.count
    }
    return ([blockHeader] + lines + [blockFooter]).joined(separator: "\n")
  }

  /// IDs of the assistant messages whose records are replayed: the newest `replayedMessageLimit`
  /// that have any.
  static func replayedMessageIDs(in messages: [ChatMessage]) -> Set<UUID> {
    Set(messages.reversed()
      .filter { $0.role == .model && !$0.toolCalls.isEmpty }
      .prefix(replayedMessageLimit)
      .map(\.id))
  }

  private static func compactJSON(_ object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }

  private static func capped(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "…[truncated; call the tool again for the full result]"
  }
}

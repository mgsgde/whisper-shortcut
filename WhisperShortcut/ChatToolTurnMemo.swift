import Foundation

/// Per-turn memory of the read-only tool calls a chat turn has already made.
///
/// Models re-issue the same fruitless lookup round after round, and nothing in the tool loop used
/// to notice. Observed on a single Grok turn: six rounds of `search_files` for "Mac-Session" /
/// "max session" / "Grok Bot", every one matching 0 files, each costing a full request/response
/// round trip (one of them 54 s) while the local work itself took ~70 ms. The model had no signal
/// that it was repeating itself, so it kept going until the round cap.
///
/// Two mechanisms, both at the tool layer so every provider benefits:
/// - An exact repeat of a read-only call is answered from the first call's result, with a note
///   saying so — the model sees that the round bought it nothing.
/// - A `search_files` query that already came up empty is flagged even when the *path* differs,
///   because re-running the same words against the next folder is the loop actually observed.
///
/// Any call that is not read-only clears the memory: a model that creates a task and then lists
/// tasks must see the new state, not the snapshot from before its own write.
@MainActor
final class ChatToolTurnMemo {

  /// Tools that only read state, so a second identical call inside one turn cannot produce a
  /// different answer. Anything absent from this set is treated as a mutation — a new tool is
  /// therefore safe by default, at the cost of dropping the cache when it runs.
  ///
  /// `read_clipboard` counts as read-only here: within one turn the user has no chance to copy
  /// something else, and `copy_to_clipboard` is a mutation and clears the memory anyway.
  private static let cacheableTools: Set<String> = [
    "search_files",
    "list_directory",
    "read_text_file",
    "list_workspace_folders",
    "list_whisper_shortcut_docs",
    "read_whisper_shortcut_doc",
    "read_clipboard",
    "gmail_search",
    "gmail_read",
    "google_calendar_list_events",
    "google_tasks_list",
    "google_tasks_list_tasklists",
    "trello_list_boards",
    "trello_list_lists",
    "trello_list_cards",
  ]

  private static let repeatNote =
    "You already made this exact call earlier in this turn — this is the stored result, not a fresh lookup. Repeating it cannot produce anything new: use what you already have, try a genuinely different approach, or tell the user what you could not find."

  /// Keyed by tool name + canonical arguments.
  private var responses: [String: [String: Any]] = [:]
  /// Normalized `search_files` queries that matched nothing, with the scopes already tried.
  private var emptyQueries: [String: [String]] = [:]

  /// The stored result for an identical earlier call, or `nil` when the call has to run.
  func cachedResponse(name: String, args: [String: Any]) -> [String: Any]? {
    guard Self.cacheableTools.contains(name),
          let stored = responses[Self.key(name: name, args: args)]
    else { return nil }
    return Self.adding(note: Self.repeatNote, to: stored)
  }

  /// Files a freshly executed call away and returns the response to hand back to the model —
  /// annotated when it was a search whose words already came up empty this turn.
  @discardableResult
  func record(name: String, args: [String: Any], response: [String: Any]) -> [String: Any] {
    guard Self.cacheableTools.contains(name) else {
      // A mutation may have invalidated anything read so far.
      responses.removeAll()
      emptyQueries.removeAll()
      return response
    }
    let annotated = noteForRepeatedEmptySearch(name: name, args: args, response: response)
      .map { Self.adding(note: $0, to: response) } ?? response
    rememberEmptySearch(name: name, args: args, response: response)
    responses[Self.key(name: name, args: args)] = annotated
    return annotated
  }

  /// Drops everything. Call between turns if a memo is ever reused.
  func reset() {
    responses.removeAll()
    emptyQueries.removeAll()
  }

  // MARK: - Empty-search tracking

  private func noteForRepeatedEmptySearch(
    name: String, args: [String: Any], response: [String: Any]
  ) -> String? {
    guard name == "search_files",
          let query = Self.normalizedQuery(args),
          Self.isEmptyResult(response),
          let triedScopes = emptyQueries[query], !triedScopes.isEmpty
    else { return nil }
    return
      "'\(query)' already returned 0 results this turn (searched: \(triedScopes.joined(separator: ", "))). The same words will not start matching in another folder — stop searching for this term and answer from what you have, or ask the user where to look."
  }

  private func rememberEmptySearch(name: String, args: [String: Any], response: [String: Any]) {
    guard name == "search_files",
          let query = Self.normalizedQuery(args),
          Self.isEmptyResult(response)
    else { return }
    let scope = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let label = (scope?.isEmpty ?? true) ? "all shared folders" : scope!
    var scopes = emptyQueries[query] ?? []
    if !scopes.contains(label) { scopes.append(label) }
    emptyQueries[query] = scopes
  }

  private static func isEmptyResult(_ response: [String: Any]) -> Bool {
    response["error"] == nil && (response["count"] as? Int) == 0
  }

  private static func normalizedQuery(_ args: [String: Any]) -> String? {
    guard let raw = args["query"] as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return trimmed.isEmpty ? nil : trimmed
  }

  // MARK: - Helpers

  /// Merges into any note the tool already set (`search_files` uses `note` for truncation) rather
  /// than overwriting it — both hints matter to the model.
  private static func adding(note: String, to response: [String: Any]) -> [String: Any] {
    var merged = response
    if let existing = response["note"] as? String, !existing.isEmpty {
      merged["note"] = existing + " " + note
    } else {
      merged["note"] = note
    }
    return merged
  }

  private static func key(name: String, args: [String: Any]) -> String {
    let encoded: String
    if JSONSerialization.isValidJSONObject(args),
       let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
      encoded = text
    } else {
      // Non-JSON argument values are not expected (they arrive as decoded JSON), but a stable
      // fallback beats colliding every such call onto one key.
      encoded = args.keys.sorted().map { "\($0)=\(String(describing: args[$0]))" }
        .joined(separator: "&")
    }
    return name + "\u{1}" + encoded
  }
}

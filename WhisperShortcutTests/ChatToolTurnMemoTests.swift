import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Pins the loop-breaker the chat tool layer relies on.
///
/// The failure this guards against is not a wrong answer but a slow one: a model that re-issues
/// the same empty `search_files` every round pays a full provider round trip per repeat. The
/// caching must never outlive a mutation, though — a stale list after a write would be a wrong
/// answer, which is worse than a slow one.
@MainActor
@Suite("Chat tool turn memo")
struct ChatToolTurnMemoTests {

  private func emptySearch(_ query: String) -> [String: Any] {
    ["query": query, "matches": [], "count": 0, "files_scanned": 1587]
  }

  @Test("An identical read-only call is answered from the cache with a repeat note")
  func exactRepeatIsCached() {
    let memo = ChatToolTurnMemo()
    let args: [String: Any] = ["path": "/Users/x/notes", "max_bytes": 8000]

    #expect(memo.cachedResponse(name: "read_text_file", args: args) == nil)
    memo.record(name: "read_text_file", args: args, response: ["content": "hello"])

    let cached = memo.cachedResponse(name: "read_text_file", args: args)
    #expect(cached?["content"] as? String == "hello")
    #expect((cached?["note"] as? String)?.contains("already made this exact call") == true)
  }

  @Test("Argument order does not defeat the cache")
  func argumentOrderIsIrrelevant() {
    let memo = ChatToolTurnMemo()
    memo.record(
      name: "search_files", args: ["query": "grok", "path": "/Users/x"],
      response: emptySearch("grok"))

    #expect(memo.cachedResponse(name: "search_files", args: ["path": "/Users/x", "query": "grok"]) != nil)
  }

  @Test("Different arguments still run")
  func differentArgumentsAreNotCached() {
    let memo = ChatToolTurnMemo()
    memo.record(
      name: "read_text_file", args: ["path": "/a"], response: ["content": "a"])

    #expect(memo.cachedResponse(name: "read_text_file", args: ["path": "/b"]) == nil)
  }

  @Test("A query that came up empty is flagged when it is retried against another folder")
  func repeatedEmptyQueryIsFlagged() {
    let memo = ChatToolTurnMemo()
    let first = memo.record(
      name: "search_files", args: ["query": "Mac-Session", "path": "/Users/x/notes"],
      response: emptySearch("Mac-Session"))
    #expect(first["note"] == nil)

    let second = memo.record(
      name: "search_files", args: ["query": "mac-session", "path": "/Users/x/code"],
      response: emptySearch("mac-session"))
    let note = second["note"] as? String
    #expect(note?.contains("already returned 0 results this turn") == true)
    #expect(note?.contains("/Users/x/notes") == true)
  }

  @Test("A query that found something is never flagged")
  func productiveQueryIsNotFlagged() {
    let memo = ChatToolTurnMemo()
    memo.record(
      name: "search_files", args: ["query": "session", "path": "/a"],
      response: emptySearch("session"))

    let hit: [String: Any] = ["query": "session", "matches": [["name": "x.swift"]], "count": 1]
    let second = memo.record(name: "search_files", args: ["query": "session", "path": "/b"], response: hit)
    #expect(second["note"] == nil)
  }

  @Test("A mutation drops the cache so the model sees its own write")
  func mutationInvalidatesCache() {
    let memo = ChatToolTurnMemo()
    let args: [String: Any] = ["path": "/Users/x"]
    memo.record(name: "list_directory", args: args, response: ["count": 2])
    #expect(memo.cachedResponse(name: "list_directory", args: args) != nil)

    memo.record(
      name: "write_text_file", args: ["path": "/Users/x/new.md", "content": "hi"],
      response: ["ok": true])

    #expect(memo.cachedResponse(name: "list_directory", args: args) == nil)
  }

  @Test("Mutating tools are never served from the cache")
  func mutatingToolsAreNotCached() {
    let memo = ChatToolTurnMemo()
    let args: [String: Any] = ["path": "/a", "content": "x"]
    memo.record(name: "write_text_file", args: args, response: ["ok": true])

    #expect(memo.cachedResponse(name: "write_text_file", args: args) == nil)
  }

  @Test("An existing note from the tool survives alongside the repeat note")
  func existingNoteIsPreserved() {
    let memo = ChatToolTurnMemo()
    let args: [String: Any] = ["query": "swift", "max_results": 50]
    var truncated = emptySearch("swift")
    truncated["count"] = 50
    truncated["truncated"] = true
    truncated["note"] = "Stopped at max_results=50."
    memo.record(name: "search_files", args: args, response: truncated)

    let note = memo.cachedResponse(name: "search_files", args: args)?["note"] as? String
    #expect(note?.contains("Stopped at max_results=50.") == true)
    #expect(note?.contains("already made this exact call") == true)
  }
}

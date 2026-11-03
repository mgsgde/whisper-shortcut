import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Chat search ranking and snippeting.
///
/// These rules lived inside `ChatViewModel` and had never been tested — reaching them meant
/// standing up a 2,700-line view model. Pulling `ChatSearch` out (R3, slice 1) is what made them
/// reachable, so the behaviour is pinned here before anything else moves.
@Suite("Chat search")
struct ChatSearchTests {

  // MARK: - Ranking

  @Test("Every occurrence of a term counts toward the score")
  func scoreCountsOccurrences() {
    #expect(ChatSearch.score(haystack: "alpha", title: "", terms: ["alpha"]) == 1)
    #expect(ChatSearch.score(haystack: "alpha alpha alpha", title: "", terms: ["alpha"]) == 3)
  }

  /// A title match is what makes "the chat actually about X" outrank "the chat that mentioned X
  /// once in passing", so the bonus has to dominate a single body hit.
  @Test("A title match outweighs a lone body mention")
  func titleMatchOutranksBodyMention() {
    let bodyOnly = ChatSearch.score(haystack: "we discussed budgets", title: "random chat", terms: ["budgets"])
    let titled = ChatSearch.score(haystack: "we discussed budgets", title: "budgets", terms: ["budgets"])
    #expect(titled > bodyOnly)
    #expect(titled - bodyOnly == 5)
  }

  @Test("Multi-term queries accumulate across terms")
  func multipleTermsAccumulate() {
    let score = ChatSearch.score(haystack: "alpha beta", title: "", terms: ["alpha", "beta"])
    #expect(score == 2)
  }

  @Test("A term that appears nowhere adds nothing")
  func absentTermScoresZero() {
    #expect(ChatSearch.score(haystack: "alpha", title: "alpha", terms: ["zeta"]) == 0)
  }

  // MARK: - Snippets

  @Test("The snippet centres on the first matching term")
  func snippetCentresOnMatch() {
    let body = String(repeating: "x ", count: 60) + "needle " + String(repeating: "y ", count: 60)
    let snippet = ChatSearch.snippet(from: [body], terms: ["needle"], fallback: "fallback")
    #expect(snippet.contains("needle"))
    #expect(snippet.hasPrefix("…"), "elided leading context should be marked")
    #expect(snippet.hasSuffix("…"), "elided trailing context should be marked")
  }

  @Test("No ellipsis when nothing was elided")
  func shortSnippetHasNoEllipsis() {
    let snippet = ChatSearch.snippet(from: ["needle here"], terms: ["needle"], fallback: "fallback")
    #expect(!snippet.hasPrefix("…"))
    #expect(!snippet.hasSuffix("…"))
  }

  /// The score is computed on a lowercased haystack, but the snippet runs against the raw text —
  /// so it has to match case-insensitively or a capitalised hit would fall back to the title.
  @Test("Snippet matching ignores case")
  func snippetIsCaseInsensitive() {
    let snippet = ChatSearch.snippet(from: ["The Needle is here"], terms: ["needle"], fallback: "fallback")
    #expect(snippet.contains("Needle"))
    #expect(snippet != "fallback")
  }

  @Test("A query that matches no text falls back to the title")
  func snippetFallsBackToTitle() {
    let snippet = ChatSearch.snippet(from: ["nothing relevant"], terms: ["zeta"], fallback: "My chat title")
    #expect(snippet == "My chat title")
  }

  @Test("Newlines never survive into a one-line snippet")
  func snippetIsSingleLine() {
    let snippet = ChatSearch.snippet(from: ["line one\nneedle\r\nline three"], terms: ["needle"], fallback: "f")
    #expect(!snippet.contains("\n"))
    #expect(!snippet.contains("\r"))
  }

  @Test("The fallback is capped so a long title can't become the whole row")
  func fallbackIsCapped() {
    let longTitle = String(repeating: "z", count: 500)
    let snippet = ChatSearch.snippet(from: ["irrelevant"], terms: ["zeta"], fallback: longTitle)
    #expect(snippet.count == 100)
  }

  // MARK: - Wrapper tags

  /// Indexing the raw stored message made every chat match "user", "typed", "pasted", and
  /// "content", because those words are the wrapper tags around typed and pasted text.
  @Test("Wrapper tags are not part of the searchable text")
  func wrapperTagsAreNotSearchable() {
    let typed = ChatSearch.searchableText(of: "<typed_by_user>\nhello\n</typed_by_user>").lowercased()
    #expect(typed.contains("hello"))
    #expect(!typed.contains("typed"))
    #expect(!typed.contains("user"))
    #expect(!typed.contains("<"))

    let pasted = ChatSearch.searchableText(of: "<pasted_content>\nlogs\n</pasted_content>").lowercased()
    #expect(pasted.contains("logs"))
    #expect(!pasted.contains("pasted"))
    #expect(!pasted.contains("content"))

    let selection = ChatSearch.searchableText(of: "<pasted_selection>\nquote\n</pasted_selection>").lowercased()
    #expect(selection.contains("quote"))
    #expect(!selection.contains("pasted"))
  }

  /// `parseUserMessagePastedXML` keeps only a trailing typed block. A typed block that comes
  /// first would disappear from search if we indexed the parser output alone.
  @Test("Typed text that precedes a paste stays searchable, still without the tags")
  func typedTextBeforeAPasteStaysSearchable() {
    let raw = "<typed_by_user>\nbudget\n</typed_by_user>\n\n<pasted_content>\nlogs\n</pasted_content>"
    let text = ChatSearch.searchableText(of: raw).lowercased()
    #expect(text.contains("budget"))
    #expect(text.contains("logs"))
    #expect(!text.contains("typed"))
    #expect(!text.contains("user"))
    #expect(!text.contains("pasted"))
    #expect(!text.contains("content"))
  }

  @MainActor
  @Test("Searching for a wrapper word does not hit a chat that only uses the tags")
  func searchDoesNotMatchWrapperWords() {
    let scope = "searchtags-\(UUID().uuidString)"
    let store = ChatSessionStore(scope: scope)
    let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("gemini-sessions-\(scope).json")
    defer {
      store.flushToDisk()
      try? FileManager.default.removeItem(at: url)
    }

    var session = store.load()
    session.title = "Notes"
    session.messages = [
      ChatMessage(
        role: .user,
        content: "<pasted_content>\nxylophone\n</pasted_content>\n\n<typed_by_user>\nhello\n</typed_by_user>")
    ]
    store.save(session)

    for term in ["user", "typed", "pasted", "content"] {
      let hits = ChatSearch.run(term, store: store).filter { $0.sessionId == session.id }
      #expect(hits.isEmpty, "\(term) matched the wrapper tags")
    }

    let real = ChatSearch.run("xylophone", store: store).filter { $0.sessionId == session.id }
    #expect(real.count == 1)
    #expect(real.first?.snippet.lowercased().contains("xylophone") == true)
    #expect(real.first?.snippet.contains("<") == false)
    #expect(real.first?.snippet.lowercased().contains("pasted_content") == false)
  }
}

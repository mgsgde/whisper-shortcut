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
}

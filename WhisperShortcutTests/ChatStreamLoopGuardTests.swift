import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Chat stream loop guard")
struct ChatStreamLoopGuardTests {

  // MARK: - Cumulative merge

  struct MergeCase: Sendable {
    let note: String
    let streamed: String
    let delta: String
    let expected: String
    /// Set when the original case asserted `merge().kind`. Otherwise only `mergeDelta` is checked.
    var kind: String? = nil
  }

  @Test("Cumulative prefixes replace; a true increment appends; empty and identical deltas do not grow", arguments: [
    MergeCase(note: "cumulative A", streamed: "", delta: "A", expected: "A"),
    // A then AB replaces, does not append to AAB.
    MergeCase(note: "cumulative AB replaces", streamed: "A", delta: "AB", expected: "AB"),
    MergeCase(note: "true incremental deltas still append", streamed: "Hello", delta: " world", expected: "Hello world", kind: "appended"),
    MergeCase(note: "a shorter prefix does not shrink the accumulated text", streamed: "AB", delta: "A", expected: "AB", kind: "replaced"),
    MergeCase(note: "identical cumulative chunk does not double", streamed: "Hello", delta: "Hello", expected: "Hello"),
    MergeCase(note: "empty delta is a no-op", streamed: "Hello", delta: "", expected: "Hello"),
  ])
  func mergeDeltas(_ row: MergeCase) {
    if let kind = row.kind {
      let outcome = ChatStreamLoopGuard.merge(streamed: row.streamed, delta: row.delta)
      #expect(outcome.text == row.expected, "\(row.note)")
      switch kind {
      case "appended": #expect(outcome.kind == .appended, "\(row.note)")
      case "replaced": #expect(outcome.kind == .replaced, "\(row.note)")
      default: Issue.record("unexpected kind \(kind)")
      }
    } else {
      #expect(ChatStreamLoopGuard.mergeDelta(streamed: row.streamed, delta: row.delta) == row.expected, "\(row.note)")
    }
  }

  @Test("Duplicate trailing status sentence is ignored in place")
  func inPlaceStatusIgnored() {
    let streamed = "Intro.\nKurze Faktenprüfung zu Hitze."
    let outcome = ChatStreamLoopGuard.merge(
      streamed: streamed, delta: "Kurze Faktenprüfung zu Hitze.")
    #expect(outcome.text == streamed)
    #expect(outcome.kind == .ignored)
  }

  // MARK: - Repeat detection

  struct LoopCase: Sendable {
    let note: String
    let text: String
    let isLoop: Bool
    var streak2DoesNotStop = false
    var assertUnitLength = false
  }

  /// 40 characters, no sentence breaks.
  private static let ngramUnit = String(repeating: "abcdefghij", count: 4)
  private static let phraseBlock = "Kurze Faktenprüfung zu Hitze. Labornotiz umziehen. "

  @Test("Trailing repeats are loops only past the threshold, including behind a long prefix", arguments: [
    LoopCase(
      note: "three identical trailing sentences",
      text: "Gute Antwort. Kurze Faktenprüfung zu Hitze. Kurze Faktenprüfung zu Hitze. Kurze Faktenprüfung zu Hitze.",
      isLoop: true),
    LoopCase(
      note: "two identical trailing sentences is not a loop",
      text: "Gute Antwort. Kurze Faktenprüfung zu Hitze. Kurze Faktenprüfung zu Hitze.",
      isLoop: false, streak2DoesNotStop: true),
    LoopCase(note: "short tokens: ok", text: "ok. ok. ok.", isLoop: false),
    LoopCase(note: "short tokens: yes", text: "yes yes yes", isLoop: false),
    LoopCase(note: "short tokens: Ja", text: "Ja. Ja. Ja.", isLoop: false),
    LoopCase(note: "a heading restated once is not a loop", text: "## Summary\n## Summary\nBody starts here.", isLoop: false),
    LoopCase(note: "40-char n-gram repeating 3x", text: Self.ngramUnit + Self.ngramUnit + Self.ngramUnit, isLoop: true, assertUnitLength: true),
    LoopCase(note: "40-char n-gram repeating 2x is not a loop", text: Self.ngramUnit + Self.ngramUnit, isLoop: false, assertUnitLength: true),
    LoopCase(note: "two-phrase status block repeating 3x", text: String(repeating: Self.phraseBlock, count: 3), isLoop: true),
    LoopCase(note: "two-phrase status block repeating 2x is not a loop", text: String(repeating: Self.phraseBlock, count: 2), isLoop: false),
    LoopCase(
      note: "a long unique prefix does not hide a trailing n-gram loop",
      text: String(repeating: "unique text that never repeats. ", count: 400) + Self.ngramUnit + Self.ngramUnit + Self.ngramUnit,
      isLoop: true, assertUnitLength: true),
    LoopCase(
      note: "a long unique prefix with only two n-grams is not a loop",
      text: String(repeating: "unique text that never repeats. ", count: 400) + Self.ngramUnit + Self.ngramUnit,
      isLoop: false),
    LoopCase(
      note: "a long unique prefix does not hide a trailing sentence loop",
      text: String(repeating: "Different sentence number. ", count: 400)
        + "Kurze Faktenprüfung zu Hitze. Kurze Faktenprüfung zu Hitze. Kurze Faktenprüfung zu Hitze.",
      isLoop: true),
  ])
  func trailingRepeats(_ row: LoopCase) {
    if row.assertUnitLength { #expect(Self.ngramUnit.count == 40, "\(row.note)") }
    #expect(ChatStreamLoopGuard.isRepeatingLoop(row.text) == row.isLoop, "\(row.note)")
    if row.streak2DoesNotStop {
      #expect(!ChatStreamLoopGuard.shouldStop(streamed: row.text, ignoredStreak: 2), "\(row.note)")
    }
  }

  @Test("Three consecutive in-place ignores stop even though streamed stayed at one copy")
  func ignoredStreakStopsWithoutGrowingStreamed() {
    let once = "Kurze Faktenprüfung zu Hitze."
    #expect(!ChatStreamLoopGuard.isRepeatingLoop(once))
    #expect(!ChatStreamLoopGuard.shouldStop(streamed: once, ignoredStreak: 2))
    #expect(ChatStreamLoopGuard.shouldStop(streamed: once, ignoredStreak: 3))
  }

  @Test("Stop notice is appended once")
  func stopNoticeAppendedOnce() {
    let once = ChatStreamLoopGuard.appendStopNotice(to: "Gute Antwort.")
    #expect(once.contains(ChatStreamLoopGuard.stopNotice))
    let twice = ChatStreamLoopGuard.appendStopNotice(to: once)
    let count = twice.components(separatedBy: ChatStreamLoopGuard.stopNotice).count - 1
    #expect(count == 1)
  }

  @Test("shouldStop skips the n-gram scan on non-cadence deltas unless the ignore streak is high")
  func cadenceSkipsExpensiveScan() {
    let unit = String(repeating: "abcdefghij", count: 4)
    let loop = unit + unit + unit
    #expect(!ChatStreamLoopGuard.shouldStop(streamed: loop, ignoredStreak: 0, deltaIndex: 1))
    #expect(ChatStreamLoopGuard.shouldStop(streamed: loop, ignoredStreak: 0, deltaIndex: 8))
    #expect(ChatStreamLoopGuard.shouldStop(streamed: "x", ignoredStreak: 3, deltaIndex: 1))
  }
}

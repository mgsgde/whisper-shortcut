import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Chat stream loop guard")
struct ChatStreamLoopGuardTests {

  // MARK: - Cumulative merge

  @Test("Cumulative A then AB replaces, does not append to AAB")
  func cumulativeAThenAB() {
    let a = ChatStreamLoopGuard.mergeDelta(streamed: "", delta: "A")
    #expect(a == "A")
    let ab = ChatStreamLoopGuard.mergeDelta(streamed: a, delta: "AB")
    #expect(ab == "AB")
  }

  @Test("True incremental deltas still append")
  func incrementalAppend() {
    let outcome = ChatStreamLoopGuard.merge(streamed: "Hello", delta: " world")
    #expect(outcome.text == "Hello world")
    #expect(outcome.kind == .appended)
  }

  @Test("A shorter prefix does not shrink the accumulated text")
  func shorterPrefixKeepsLonger() {
    let outcome = ChatStreamLoopGuard.merge(streamed: "AB", delta: "A")
    #expect(outcome.text == "AB")
    #expect(outcome.kind == .replaced)
  }

  @Test("Identical cumulative chunk replaces rather than doubling")
  func identicalChunkDoesNotDouble() {
    #expect(ChatStreamLoopGuard.mergeDelta(streamed: "Hello", delta: "Hello") == "Hello")
  }

  @Test("Duplicate trailing status sentence is ignored in place")
  func inPlaceStatusIgnored() {
    let streamed = "Intro.\nKurze Faktenprüfung zu Hitze."
    let outcome = ChatStreamLoopGuard.merge(
      streamed: streamed, delta: "Kurze Faktenprüfung zu Hitze.")
    #expect(outcome.text == streamed)
    #expect(outcome.kind == .ignored)
  }

  @Test("Empty delta is a no-op")
  func emptyDeltaNoOp() {
    #expect(ChatStreamLoopGuard.mergeDelta(streamed: "Hello", delta: "") == "Hello")
  }

  // MARK: - Repeat detection

  @Test("Three identical trailing sentences is a loop")
  func threeTrailingSentencesIsLoop() {
    let s = "Gute Antwort. Kurze Faktenprüfung zu Hitze. Kurze Faktenprüfung zu Hitze. Kurze Faktenprüfung zu Hitze."
    #expect(ChatStreamLoopGuard.isRepeatingLoop(s))
  }

  @Test("Two identical trailing sentences is not a loop")
  func twoTrailingSentencesIsNotLoop() {
    let s = "Gute Antwort. Kurze Faktenprüfung zu Hitze. Kurze Faktenprüfung zu Hitze."
    #expect(!ChatStreamLoopGuard.isRepeatingLoop(s))
    #expect(!ChatStreamLoopGuard.shouldStop(streamed: s, ignoredStreak: 2))
  }

  @Test("Short tokens do not trip the loop detector")
  func shortTokensDoNotTrip() {
    #expect(!ChatStreamLoopGuard.isRepeatingLoop("ok. ok. ok."))
    #expect(!ChatStreamLoopGuard.isRepeatingLoop("yes yes yes"))
    #expect(!ChatStreamLoopGuard.isRepeatingLoop("Ja. Ja. Ja."))
  }

  @Test("A heading restated once is not a loop")
  func headingOnceIsNotLoop() {
    #expect(!ChatStreamLoopGuard.isRepeatingLoop("## Summary\n## Summary\nBody starts here."))
  }

  @Test("40+ char trailing n-gram repeating 3x is a loop; 2x is not")
  func trailingNgramThreshold() {
    let unit = String(repeating: "abcdefghij", count: 4)  // 40 chars, no sentence breaks
    #expect(unit.count == 40)
    #expect(ChatStreamLoopGuard.isRepeatingLoop(unit + unit + unit))
    #expect(!ChatStreamLoopGuard.isRepeatingLoop(unit + unit))
  }

  @Test("Two-phrase status block repeating 3x is a loop")
  func twoPhraseStatusBlockIsLoop() {
    let block = "Kurze Faktenprüfung zu Hitze. Labornotiz umziehen. "
    #expect(ChatStreamLoopGuard.isRepeatingLoop(String(repeating: block, count: 3)))
    #expect(!ChatStreamLoopGuard.isRepeatingLoop(String(repeating: block, count: 2)))
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

  @Test("A long unique prefix does not hide a trailing n-gram loop")
  func windowedScanDetectsTrailingLoop() {
    let prefix = String(repeating: "unique text that never repeats. ", count: 400)
    let unit = String(repeating: "abcdefghij", count: 4)
    #expect(unit.count == 40)
    #expect(ChatStreamLoopGuard.isRepeatingLoop(prefix + unit + unit + unit))
    #expect(!ChatStreamLoopGuard.isRepeatingLoop(prefix + unit + unit))
  }

  @Test("A long unique prefix does not hide a trailing sentence loop")
  func windowedScanDetectsTrailingSentences() {
    let prefix = String(repeating: "Different sentence number. ", count: 400)
    let loop = "Kurze Faktenprüfung zu Hitze. Kurze Faktenprüfung zu Hitze. Kurze Faktenprüfung zu Hitze."
    #expect(ChatStreamLoopGuard.isRepeatingLoop(prefix + loop))
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

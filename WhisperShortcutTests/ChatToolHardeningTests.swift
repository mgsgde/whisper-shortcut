import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Hardening of the chat tools (whole-word transcript fixes, approval gating, argument parsing).
@MainActor
@Suite("Chat tool hardening")
struct ChatToolHardeningTests {

  // MARK: correct_transcript_term

  @Test func wholeTermLeavesSubstringsAlone() {
    let (out, n) = ChatViewModel.replacingWholeTerm("Ana met Banana", from: "Ana", to: "Anna")
    #expect(out == "Anna met Banana")
    #expect(n == 1)
  }

  @Test func wholeTermReplacesBeforePunctuation() {
    let (out, n) = ChatViewModel.replacingWholeTerm("Hi Ana. Then Ana, and (Ana)", from: "Ana", to: "Anna")
    #expect(out == "Hi Anna. Then Anna, and (Anna)")
    #expect(n == 3)
  }

  @Test func wholeTermIsCaseSensitive() {
    let (out, n) = ChatViewModel.replacingWholeTerm("ana Ana", from: "Ana", to: "Anna")
    #expect(out == "ana Anna")
    #expect(n == 1)
  }

  @Test func wholeTermMultiWordPhrase() {
    let (out, n) = ChatViewModel.replacingWholeTerm(
      "Park Depot and Park Depots", from: "Park Depot", to: "ParkDepot")
    #expect(out == "ParkDepot and Park Depots")
    #expect(n == 1)
  }

  @Test func wholeTermRespectsUnicodeBoundaries() {
    let (out, n) = ChatViewModel.replacingWholeTerm("Ärger und rger", from: "rger", to: "X")
    #expect(out == "Ärger und X")
    #expect(n == 1)
  }

  @Test func wholeTermTreatsReplacementLiterally() {
    let (out, _) = ChatViewModel.replacingWholeTerm("cost A", from: "A", to: "$1 \\n")
    #expect(out == "cost $1 \\n")
  }
}

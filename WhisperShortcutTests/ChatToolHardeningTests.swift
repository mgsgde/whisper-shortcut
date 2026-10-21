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

  // MARK: persistent-write tools are gated

  @Test func rememberToolsNeedApprovalAndNeverChatWide() {
    for name in ["remember_file_location", "remember_dictation_term"] {
      #expect(ChatToolRegistry.requiresUserApproval(name))
      #expect(!ChatToolRegistry.allowsChatWideApproval(name))
    }
    let folder = ChatToolRegistry.approvalSummary(
      name: "remember_file_location", args: ["path": "~/Invoices", "note": "PDFs by year"])
    #expect(folder == "Remember folder: ~/Invoices — PDFs by year")
    let term = ChatToolRegistry.approvalSummary(name: "remember_dictation_term", args: ["term": "Nebius"])
    #expect(term == "Add to dictation glossary: Nebius")
  }

  @Test func sanitizedStoredTextFlattensCapsAndRejectsEmpty() {
    #expect(ChatToolRegistry.sanitizedStoredText("a\nb\r\nc", limit: 100) == "a b  c")
    #expect(ChatToolRegistry.sanitizedStoredText(String(repeating: "x", count: 500), limit: 300)?.count == 300)
    #expect(ChatToolRegistry.sanitizedStoredText(" \n ", limit: 100) == nil)
  }

  @Test func forgetAboutUserRefusesShortNeedles() {
    for needle in ["a", "  ab ", "a b"] {
      let result = ChatMemoryTools.executeForgetAboutUserTool(args: ["matching": needle])
      #expect(result["error"] != nil, "\(needle)")
    }
  }

  // MARK: approval card matches execution

  @Test func writeCardUsesTheSameBoolParsingAsExecution() {
    for value: Any in [true, "true", "yes", "1"] {
      let card = ChatToolRegistry.approvalSummary(
        name: "write_text_file", args: ["path": "a.txt", "content": "x", "overwrite": value])
      #expect(card.hasPrefix("Overwrite file"), "\(value)")
    }
    let create = ChatToolRegistry.approvalSummary(
      name: "write_text_file", args: ["path": "a.txt", "content": "x", "overwrite": "no"])
    #expect(create.hasPrefix("Create file"))
  }

  @Test func editCardMentionsReplaceAll() {
    let all = ChatToolRegistry.approvalSummary(
      name: "edit_text_file", args: ["path": "a.txt", "find": "a", "replace": "b", "replace_all": "true"])
    #expect(all.contains("all occurrences"))
    let one = ChatToolRegistry.approvalSummary(
      name: "edit_text_file", args: ["path": "a.txt", "find": "a", "replace": "b"])
    #expect(!one.contains("all occurrences"))
  }
}

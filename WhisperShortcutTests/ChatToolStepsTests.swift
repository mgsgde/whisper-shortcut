import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Tool-step labels and the live step buffer behind the chat's typing indicator
/// (plans/active/chat-tool-steps.md, Slice 1).
@MainActor
@Suite("Chat tool steps")
struct ChatToolStepsTests {

  /// Every declaration the chat can offer, composed directly: `allDeclarations` returns nothing
  /// when the local MLX provider is selected, which would make these tests depend on the machine.
  private var allToolNames: [String] {
    let groups: [[[String: Any]]] = [
      ChatToolRegistry.functionDeclarations, ChatToolRegistry.appDocsFunctionDeclarations,
      ChatToolRegistry.memoryFunctionDeclarations, ChatToolRegistry.instructionsFunctionDeclarations,
      ChatToolRegistry.workspaceFunctionDeclarations, ChatToolRegistry.workspaceWriteFunctionDeclarations,
      ChatToolRegistry.imageFunctionDeclarations, ChatToolRegistry.calendarFunctionDeclarations,
      ChatToolRegistry.tasksFunctionDeclarations, ChatToolRegistry.gmailFunctionDeclarations,
      ChatToolRegistry.trelloFunctionDeclarations, ChatToolRegistry.meetingFunctionDeclarations,
    ]
    return groups.flatMap { $0 }.compactMap { $0["name"] as? String }
  }

  @Test func everyDeclaredToolHasWording() {
    #expect(allToolNames.count > 20)
    let missing = allToolNames.filter { !ChatToolRegistry.hasStepWording($0) }
    #expect(missing.isEmpty, "Tools without a step label: \(missing)")
  }

  @Test func labelsNeverShowRawIds() {
    for name in allToolNames {
      for done in [false, true] {
        let label = ChatToolRegistry.stepLabel(name: name, args: [:], done: done)
        #expect(!label.isEmpty)
        #expect(!label.contains("_"), "\(name) → \(label)")
      }
    }
  }

  /// Without its argument a label must still read as a sentence, not "Searching Gmail for…".
  @Test func labelsWithoutArgumentsDoNotDangle() {
    let dangling = [" for", " to", " find", " of"]
    let danglingAlone = ["Opening", "Opened", "Reading", "Read", "Listing", "Listed", "Writing", "Wrote",
      "Editing", "Edited"]
    for name in allToolNames {
      for done in [false, true] {
        var label = ChatToolRegistry.stepLabel(name: name, args: [:], done: done)
        if label.hasSuffix("…") { label.removeLast() }
        #expect(!dangling.contains { label.hasSuffix($0) }, "\(name) → \(label)")
        #expect(!danglingAlone.contains(label), "\(name) → \(label)")
      }
    }
  }

  @Test func labelsCarryTheirObject() {
    #expect(ChatToolRegistry.stepLabel(name: "gmail_search", args: ["query": "invoice"], done: false)
      == "Searching Gmail for \"invoice\"…")
    #expect(ChatToolRegistry.stepLabel(name: "read_text_file", args: ["path": "/a/b/notes.md"], done: true)
      == "Read notes.md")
    #expect(ChatToolRegistry.stepLabel(
      name: ChatToolRegistry.updateInstructionsToolName, args: ["action": "read"], done: false)
      == "Reading app instructions…")
  }

  @Test func longArgumentsAreTruncated() {
    let label = ChatToolRegistry.stepLabel(
      name: "gmail_search", args: ["query": String(repeating: "x", count: 200)], done: false)
    #expect(label.count < 70)
  }

  @Test func unknownToolFallsBackReadably() {
    #expect(ChatToolRegistry.stepLabel(name: "brand_new_tool", args: [:], done: false) == "Running brand new tool…")
  }

  @Test func resultCountPrefersKnownKeysThenSingleArray() {
    #expect(ChatToolRegistry.resultCount(["messages": [1, 2, 3], "next": "x"]) == 3)
    #expect(ChatToolRegistry.resultCount(["whatever": [1, 2]]) == 2)
    #expect(ChatToolRegistry.resultCount(["a": [1], "b": [2]]) == nil)
    #expect(ChatToolRegistry.resultCount(["ok": true]) == nil)
    #expect(ChatToolRegistry.resultCount(["error": "nope", "results": [1]]) == nil)
    #expect(ChatToolRegistry.resultSummary(name: "gmail_search", response: ["messages": [1, 2]]) == "2 results")
    #expect(ChatToolRegistry.resultSummary(name: "read_text_file", response: ["lines": [1]]) == nil)
  }

  @Test func bufferTracksActiveStepAndNumbering() {
    let buffer = ToolStepsBuffer()
    #expect(buffer.indicatorLabel == nil)
    let first = buffer.begin(name: "gmail_search", args: ["query": "a"])
    #expect(buffer.indicatorLabel == "Searching Gmail for \"a\"…")
    buffer.finish(first, phase: .done, summary: "2 results")
    #expect(buffer.indicatorLabel == nil)
    let second = buffer.begin(name: "google_calendar_create_event", args: [:], phase: .awaitingApproval)
    #expect(buffer.indicatorLabel == "Step 2 · Waiting for your approval…")
    buffer.setPhase(second, .running)
    #expect(buffer.indicatorLabel == "Step 2 · Creating event…")
  }

  @Test func webSearchStepFinishesByName() {
    let buffer = ToolStepsBuffer()
    buffer.begin(name: ChatToolRegistry.webSearchStepName, args: [:])
    #expect(buffer.activeStep?.name == ChatToolRegistry.webSearchStepName)
    buffer.finishActive(named: ChatToolRegistry.webSearchStepName)
    #expect(buffer.activeStep == nil)
    #expect(buffer.steps.first?.phase == .done)
  }
}

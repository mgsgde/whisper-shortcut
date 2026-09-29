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

  // MARK: - Slice 2: persisted display

  @Test func recordsCarryStepOutcome() {
    let buffer = ToolStepsBuffer()
    let ok = buffer.begin(name: "gmail_search", args: ["query": "a"])
    buffer.finish(ok, phase: .done, summary: "2 results")
    let denied = buffer.begin(name: "google_tasks_delete", args: [:], phase: .awaitingApproval)
    buffer.finish(denied, phase: .denied)
    let records = ChatToolHistory.records(
      calls: [("gmail_search", ["query": "a"]), ("google_tasks_delete", [:])],
      responses: [["messages": [1, 2]], ["error": "The user denied this google_tasks_delete call."]],
      steps: [buffer.step(ok), buffer.step(denied)])
    #expect(records.map(\.status) == [.done, .denied])
    #expect(records[0].summary == "2 results")
    #expect(records[0].durationMs != nil)
  }

  @Test func legacyRecordWithoutDisplayFieldsIsDerived() throws {
    let json = #"{"name":"gmail_search","argsJSON":"{\"query\":\"invoice\"}","resultJSON":"{\"messages\":[1,2,3]}"}"#
    let record = try JSONDecoder().decode(ChatToolCallRecord.self, from: Data(json.utf8))
    #expect(record.status == nil)
    let display = ChatToolStepDisplay.from(record: record, index: 0)
    #expect(display.label == "Searched Gmail for \"invoice\"")
    #expect(display.status == .done)
    #expect(display.summary == "3 results")

    let deniedJSON = #"{"name":"google_tasks_delete","argsJSON":"{}","resultJSON":"{\"error\":\"The user denied this google_tasks_delete call.\"}"}"#
    let denied = try JSONDecoder().decode(ChatToolCallRecord.self, from: Data(deniedJSON.utf8))
    #expect(ChatToolStepDisplay.from(record: denied, index: 1).status == .denied)
  }

  @Test func displayFieldsRoundTripAndStayOptional() throws {
    var record = ChatToolCallRecord(name: "gmail_read", argsJSON: "{}", resultJSON: "{}")
    let bare = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    #expect(!bare.contains("status"))
    record.status = .failed
    record.summary = "Not found"
    record.durationMs = 120
    let decoded = try JSONDecoder().decode(ChatToolCallRecord.self, from: JSONEncoder().encode(record))
    #expect(decoded == record)
  }

  @Test func groupHeader() {
    func step(_ label: String, _ status: ChatToolStepDisplay.Status, _ summary: String? = nil) -> ChatToolStepDisplay {
      ChatToolStepDisplay(
        id: label, label: label, status: status, summary: summary, argsJSON: nil, resultJSON: nil)
    }
    #expect(ChatToolStepsSummary.header(for: [step("Searched Gmail", .done, "3 results")])
      == "Searched Gmail · 3 results")
    #expect(ChatToolStepsSummary.header(for: [step("a", .done), step("b", .failed), step("c", .denied)])
      == "Used 3 tools · 1 failed · 1 denied")
    #expect(ChatToolStepsSummary.header(for: [step("a", .done), step("Creating task…", .running)])
      == "Creating task…")
  }

  @Test func failedStepsShowTheirError() throws {
    let json = #"{"name":"gmail_read","argsJSON":"{}","resultJSON":"{\"error\":\"Message not found\"}"}"#
    let record = try JSONDecoder().decode(ChatToolCallRecord.self, from: Data(json.utf8))
    let display = ChatToolStepDisplay.from(record: record, index: 0)
    #expect(display.status == .failed)
    #expect(ChatToolStepsSummary.statusSuffix(display) == "Failed: Message not found")
  }

  @Test func unknownStatusDecodesInsteadOfFailing() throws {
    let json = #"{"name":"gmail_read","argsJSON":"{}","resultJSON":"{}","status":"cancelled"}"#
    let record = try JSONDecoder().decode(ChatToolCallRecord.self, from: Data(json.utf8))
    #expect(record.status == .done)
  }

  // MARK: - Slice 3: inline approval

  /// The decision for every approval-gated tool, spelled out. A new gated tool fails this test
  /// until someone decides on purpose whether a blanket "Allow for this chat" is safe for it.
  private static let chatWideDecision: [String: Bool] = [
    // Prompt-injection gated or able to exfiltrate: always ask.
    ChatToolRegistry.rememberAboutUserToolName: false,
    ChatToolRegistry.updateInstructionsToolName: false,
    "open_url": false,
    "write_text_file": false, "append_to_file": false, "edit_text_file": false,
    // Destructive: always ask.
    "google_calendar_delete_event": false, "google_tasks_delete": false, "trello_archive_card": false,
    // Create/update/move: may be allowed for the chat.
    "google_calendar_create_event": true, "google_calendar_update_event": true,
    "google_tasks_create": true, "google_tasks_update": true, "google_tasks_complete": true,
    "trello_create_card": true, "trello_move_card": true, "trello_update_card": true,
  ]

  @Test func everyApprovalGatedToolHasAnExplicitChatWideDecision() {
    let gated = allToolNames.filter { ChatToolRegistry.requiresUserApproval($0, args: ["action": "write"]) }
    for name in gated {
      guard let expected = Self.chatWideDecision[name] else {
        Issue.record("No chat-wide approval decision for \(name)")
        continue
      }
      #expect(ChatToolRegistry.allowsChatWideApproval(name) == expected, "\(name)")
    }
  }
}

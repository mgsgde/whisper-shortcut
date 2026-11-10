import AppKit
import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Hardening of the chat tools (whole-word transcript fixes, approval gating, argument parsing).
@MainActor
@Suite("Chat tool hardening")
struct ChatToolHardeningTests {

  // MARK: correct_transcript_term

  struct WholeTerm: Sendable {
    let note: String
    let text: String
    let from: String
    let to: String
    let expected: String
    var count: Int? = nil
  }

  @Test("Whole-term replacement leaves substrings, case and template characters alone", arguments: [
    WholeTerm(note: "substrings stay", text: "Ana met Banana", from: "Ana", to: "Anna", expected: "Anna met Banana", count: 1),
    WholeTerm(note: "punctuation is a boundary", text: "Hi Ana. Then Ana, and (Ana)", from: "Ana", to: "Anna", expected: "Hi Anna. Then Anna, and (Anna)", count: 3),
    WholeTerm(note: "case sensitive", text: "ana Ana", from: "Ana", to: "Anna", expected: "ana Anna", count: 1),
    WholeTerm(note: "multi-word phrase", text: "Park Depot and Park Depots", from: "Park Depot", to: "ParkDepot", expected: "ParkDepot and Park Depots", count: 1),
    WholeTerm(note: "unicode boundaries", text: "Ärger und rger", from: "rger", to: "X", expected: "Ärger und X", count: 1),
    WholeTerm(note: "replacement is literal, not a template", text: "cost A", from: "A", to: "$1 \\n", expected: "cost $1 \\n"),
  ])
  func wholeTerm(_ row: WholeTerm) {
    let (out, n) = ChatViewModel.replacingWholeTerm(row.text, from: row.from, to: row.to)
    #expect(out == row.expected, "\(row.note)")
    if let count = row.count { #expect(n == count, "\(row.note)") }
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

  // MARK: read_text_file truncation

  @Test func truncationDropsSplitUTF8Sequence() {
    let full = Data("aä€😀".utf8)  // 1 + 2 + 3 + 4 bytes
    for cut in 1..<full.count {
      let trimmed = WorkspaceFileTools.droppingIncompleteUTF8Tail(Data(full.prefix(cut)))
      #expect(String(data: trimmed, encoding: .utf8) != nil, "cut at \(cut)")
    }
    #expect(WorkspaceFileTools.droppingIncompleteUTF8Tail(Data(full.prefix(2))) == Data("a".utf8))
    #expect(WorkspaceFileTools.droppingIncompleteUTF8Tail(Data(full.prefix(3))) == Data("aä".utf8))
    #expect(WorkspaceFileTools.droppingIncompleteUTF8Tail(full) == full)
    #expect(WorkspaceFileTools.droppingIncompleteUTF8Tail(Data()).isEmpty)
  }

  // MARK: intArgument

  @Test func intArgumentNeverTraps() {
    let f = { (v: Any) in ChatToolRegistry.intArgument(["k": v], "k", default: 7) }
    #expect(f(1e20) == 1_000_000_000)
    #expect(f(-1e20) == -1_000_000_000)
    #expect(f(Double.nan) == 7)
    #expect(f(Double.infinity) == 7)
    #expect(f("12") == 12)
    #expect(f(3.7) == 3)
    #expect(f(-3.7) == -3)
    #expect(f(Int.max) == 1_000_000_000)
    #expect(ChatToolRegistry.intArgument([:], "k", default: 7) == 7)
  }

  // MARK: chat reply links

  @Test func chatReplyLinksOpenOnlyHttpHttpsMailto() throws {
    let http = try #require(URL(string: "https://example.com/doc"))
    let mail = try #require(URL(string: "mailto:user@example.com"))
    let file = try #require(URL(string: "file:///etc/passwd"))
    let custom = try #require(URL(string: "shortcuts://run-shortcut?name=x"))
    let js = try #require(URL(string: "javascript:alert(1)"))
    #expect(ChatLinkPolicy.isSafeToOpen(http))
    #expect(ChatLinkPolicy.isSafeToOpen(mail))
    #expect(!ChatLinkPolicy.isSafeToOpen(file))
    #expect(!ChatLinkPolicy.isSafeToOpen(custom))
    #expect(!ChatLinkPolicy.isSafeToOpen(js))
  }

  @Test func chatSettingsLinkResolvesOnlyKnownTabs() throws {
    let accounts = try #require(URL(string: "whispershortcut://settings/accounts"))
    let upper = try #require(URL(string: "WhisperShortcut://Settings/Accounts"))
    let unknown = try #require(URL(string: "whispershortcut://settings/nope"))
    let otherHost = try #require(URL(string: "whispershortcut://other/accounts"))
    let https = try #require(URL(string: "https://settings/accounts"))
    #expect(ChatSettingsLink.tab(for: accounts) == .accounts)
    #expect(ChatSettingsLink.tab(for: upper) == .accounts)
    #expect(ChatSettingsLink.tab(for: unknown) == nil)
    #expect(ChatSettingsLink.tab(for: otherHost) == nil)
    #expect(ChatSettingsLink.tab(for: https) == nil)
    #expect(!ChatLinkPolicy.isSafeToOpen(accounts))
  }

  @Test func chatReplyLinkDelegateSwallowsBlockedSchemes() throws {
    let textView = NSTextView()
    var opened: [URL] = []
    let delegate = ChatReplyLinkDelegate { opened.append($0) }
    let https = try #require(URL(string: "https://example.com/doc"))
    let mail = try #require(URL(string: "mailto:user@example.com"))
    let file = try #require(URL(string: "file:///etc/passwd"))
    let custom = try #require(URL(string: "shortcuts://run-shortcut?name=x"))

    #expect(delegate.textView(textView, clickedOnLink: https, at: 0))
    #expect(delegate.textView(textView, clickedOnLink: "mailto:user@example.com", at: 0))
    #expect(opened == [https, mail])

    #expect(delegate.textView(textView, clickedOnLink: file, at: 0))
    #expect(delegate.textView(textView, clickedOnLink: custom, at: 0))
    #expect(delegate.textView(textView, clickedOnLink: "javascript:alert(1)", at: 0))
    #expect(delegate.textView(textView, clickedOnLink: "not a url", at: 4))
    #expect(opened == [https, mail])
  }

  @Test func gmailToolsWarnThatContentIsUntrusted() {
    for decl in ChatToolRegistry.gmailFunctionDeclarations {
      let desc = decl["description"] as? String ?? ""
      #expect(desc.contains("untrusted third-party text"), "\(decl["name"] ?? "?")")
    }
  }

  @Test func gmailMessageIdsArePathEncoded() {
    #expect(GmailAPIClient.encodedPathComponent("18c5f3a1b2") == "18c5f3a1b2")
    #expect(GmailAPIClient.encodedPathComponent("abc/../x") == "abc%2F..%2Fx")
    #expect(GmailAPIClient.encodedPathComponent("id?x=1#frag") == "id%3Fx%3D1%23frag")
  }

  @Test func googleTasksErrorLogKeepsKeysNotTitles() throws {
    let body = try JSONSerialization.data(withJSONObject: ["title": "Secret meeting", "notes": "private"])
    let keys = GoogleTasksAPIClient.loggedBodyKeys(body)
    #expect(keys == "notes,title")
    #expect(!keys.contains("Secret"))
    #expect(!keys.contains("private"))
    #expect(GoogleTasksAPIClient.loggedBodyKeys(nil) == "none")
    #expect(GoogleTasksAPIClient.loggedBodyKeys(Data("not-json".utf8)) == "none")
  }

  @Test func trelloLogStripsKeyAndTokenButKeepsTheError() {
    let key = String(repeating: "ab", count: 16)
    let card = String(repeating: "cd", count: 12)
    let body = """
      card missing https://api.trello.com/1/cards/\(card)?key=abc123secret&token=tok_value&name=Q3%20plan \
      {"message":"invalid idList","token":"short-tok"} leaked \(key)
      """
    let logged = TrelloAPIClient.redactingSecretsForLog(body)
    #expect(logged.contains("invalid idList"))
    #expect(logged.contains("name=Q3%20plan"))
    #expect(logged.contains(card))
    #expect(logged.contains("key=REDACTED"))
    #expect(logged.contains("token=REDACTED"))
    #expect(!logged.contains("abc123secret"))
    #expect(!logged.contains("tok_value"))
    #expect(!logged.contains("short-tok"))
    #expect(!logged.contains(key))
    #expect(TrelloAPIClient.redactingSecretsForLog("key%3Dsupersecret&ok=1") == "key%3DREDACTED&ok=1")
  }

  // MARK: write tools size check

  @Test func existingFileSizeReadsAttributesOnly() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ct-size-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(WorkspaceWriteTools.existingFileSize(url) == nil)
    try Data(repeating: 0x61, count: 1234).write(to: url)
    #expect(WorkspaceWriteTools.existingFileSize(url) == 1234)
  }

  // MARK: section limit relative to the default

  @Test("Section limit leaves 2,000 characters of headroom over every shipped default")
  func sectionLimitHasHeadroom() {
    for section in [SystemPromptSection.promptMode, .chat, .dictation] {
      let limit = ChatToolRegistry.instructionsSectionLimit(for: section)
      #expect(limit >= MCPProposalWindows.defaultText(for: section).count + 2_000)
      #expect(limit >= 5_000)
    }
  }

  @Test("A default plus one 40-character rule fits the limit for Dictate Prompt and Chat")
  func defaultPlusRuleFits() {
    let rule = String(repeating: "r", count: 40)
    for section in [SystemPromptSection.promptMode, .chat] {
      let updated = MCPProposalWindows.defaultText(for: section) + "\n" + rule
      #expect(updated.count <= ChatToolRegistry.instructionsSectionLimit(for: section))
    }
  }

  // MARK: approval preview

  /// What the executor treats as the section's current text (blank falls back to the default).
  /// The append test uses `dictation`, the section with the shortest default, so a stored user
  /// prompt near its limit is the least likely to make the append refuse and the preview vanish.
  private func currentDictationText() -> String {
    let stored = SystemPromptsStore.shared.loadSection(.dictation) ?? ""
    return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? MCPProposalWindows.defaultText(for: .dictation) : stored
  }

  @Test func approvalPreviewShowsBeforeAndAfterForAppend() {
    let current = currentDictationText()
    let rule = "Always answer in formal German."
    let preview = ChatToolRegistry.approvalPreview(
      name: ChatToolRegistry.updateInstructionsToolName,
      args: ["section": "dictation", "action": "append", "text": rule])
    #expect(preview != nil)
    #expect(!(preview?.title.isEmpty ?? true))
    #expect(preview?.before == current)
    #expect(preview?.after == current + "\n" + rule)
  }

  @Test func approvalPreviewIsNilForReadUnknownSectionAndOtherTools() {
    let name = ChatToolRegistry.updateInstructionsToolName
    #expect(ChatToolRegistry.approvalPreview(
      name: name, args: ["section": "dictate_prompt", "action": "read"]) == nil)
    #expect(ChatToolRegistry.approvalPreview(
      name: name, args: ["section": "nope", "action": "append", "text": "x"]) == nil)
    #expect(ChatToolRegistry.approvalPreview(
      name: "open_url", args: ["url": "https://example.com"]) == nil)
  }

  @Test func approvalPreviewIsNilWhenRemoveMatchesNoLine() {
    let preview = ChatToolRegistry.approvalPreview(
      name: ChatToolRegistry.updateInstructionsToolName,
      args: ["section": "dictate_prompt", "action": "remove",
             "text": "zzz-no-such-line-\(UUID().uuidString)"])
    #expect(preview == nil)
  }
}

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("MCP proposals and change log")
struct MCPProposalAndChangeLogTests {

  private func obj(_ r: MCPToolResult) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any]) ?? [:]
  }

  private func propose(_ env: MCPTestEnv, section: String = "dictation", content: String = "Proposed text") -> String {
    let r = env.tools().call(name: "update_system_prompt",
      arguments: ["section": section, "content": content, "rationale": "because"], access: .write)
    return obj(r)["id"] as? String ?? ""
  }

  @Test("Accepting applies the proposal and logs the change; status becomes accepted")
  func accept() {
    let env = MCPTestEnv(level: .apply)
    let id = propose(env)
    #expect(env.proposals.status(of: id)?.status == .pending)
    guard case .success(let changeID) = env.proposals.accept(id) else { Issue.record("accept failed"); return }
    #expect(env.systemPrompts.loadSection(.dictation) == "Proposed text")
    #expect(env.proposals.status(of: id)?.status == .accepted)
    #expect(env.proposals.status(of: id)?.edited == false)
    #expect(env.proposals.pending.isEmpty)
    #expect(env.changeLog.changes.first?.id == changeID)
    #expect(env.changeLog.changes.first?.viaProposal == true)
    let status = env.tools().call(name: "get_proposal_status", arguments: ["id": id], access: .write)
    #expect(obj(status)["status"] as? String == "accepted")
  }

  @Test("Accepting with edited content applies the edit and marks it edited")
  func acceptEdited() {
    let env = MCPTestEnv()
    let id = propose(env, section: "chat")
    guard case .success = env.proposals.accept(id, editedContent: "My edit") else { Issue.record("accept failed"); return }
    #expect(env.systemPrompts.loadSection(.chat) == "My edit")
    #expect(env.proposals.status(of: id)?.edited == true)
  }

  @Test("Declining leaves the file alone")
  func decline() {
    let env = MCPTestEnv()
    let before = env.systemPrompts.loadFullContent()
    let id = propose(env)
    env.proposals.decline(id)
    #expect(env.systemPrompts.loadFullContent() == before)
    #expect(env.proposals.status(of: id)?.status == .declined)
    #expect(env.proposals.pending.isEmpty)
    if case .success = env.proposals.accept(id) { Issue.record("declined proposal must not be accepted") }
  }

  @Test("Proposals persist across a new store on the same directory")
  func persistence() {
    let env = MCPTestEnv()
    let a = propose(env)
    let b = propose(env, section: "chat")
    env.proposals.decline(b)
    let reopened = MCPProposalStore(directory: env.dir)
    #expect(reopened.pending.map(\.id) == [a])
    #expect(reopened.status(of: b)?.status == .declined)
    #expect(reopened.status(of: a)?.proposedContent == "Proposed text")
  }

  @Test("Command proposals apply on accept")
  func commandProposals() {
    let env = MCPTestEnv(level: .propose)
    let r = env.tools().call(name: "save_command",
      arguments: ["name": "recap", "text": "Recap it.", "scope": "meeting", "rationale": "r"], access: .write)
    let id = obj(r)["id"] as? String ?? ""
    #expect(env.commands.command(named: "recap") == nil)
    guard case .success = env.proposals.accept(id) else { Issue.record("accept failed"); return }
    #expect(env.commands.command(named: "recap")?.body == "Recap it.")
    let d = env.tools().call(name: "delete_command", arguments: ["name": "recap", "rationale": "r"], access: .write)
    guard case .success = env.proposals.accept(obj(d)["id"] as? String ?? "") else { Issue.record("delete failed"); return }
    #expect(!FileManager.default.fileExists(atPath: env.commands.fileURL(forName: "recap").path))
  }

  // MARK: undo

  @Test("Undo restores the previous content and logs mcp-undo")
  func undoRestores() {
    let env = MCPTestEnv(level: .apply)
    env.systemPrompts.updateSection(.promptMode, content: "Old rule.")
    let r = env.tools().call(name: "update_system_prompt",
      arguments: ["section": "dictate_prompt", "content": "New rule.", "rationale": "r"], access: .write)
    let id = obj(r)["change_id"] as? String ?? ""
    #expect(env.changeLog.undo(id) == .undone)
    #expect(env.systemPrompts.loadSection(.promptMode) == "Old rule.")
    #expect(env.changeLog.changes.first?.undoneAt != nil)
    #expect(env.history.contains { $0.hasSuffix("|mcp-undo") })
    #expect(env.changeLog.undo(id) == .notFound)
  }

  @Test("Undo after a later manual edit is a conflict and writes nothing")
  func undoConflict() {
    let env = MCPTestEnv(level: .apply)
    env.systemPrompts.updateSection(.promptMode, content: "Old rule.")
    let r = env.tools().call(name: "update_system_prompt",
      arguments: ["section": "dictate_prompt", "content": "New rule.", "rationale": "r"], access: .write)
    let id = obj(r)["change_id"] as? String ?? ""
    env.systemPrompts.updateSection(.promptMode, content: "Manual edit.")
    #expect(env.changeLog.undo(id) == .conflict(current: "Manual edit."))
    #expect(env.systemPrompts.loadSection(.promptMode) == "Manual edit.")
    #expect(env.changeLog.changes.first?.undoneAt == nil)
  }

  @Test("Undo of a glossary add restores the glossary")
  func undoGlossary() {
    let env = MCPTestEnv()
    env.systemPrompts.updateSection(.whisperGlossary, content: "Smikale")
    let r = env.tools().call(name: "add_glossary_terms", arguments: ["terms": ["Wianco"], "rationale": "r"], access: .write)
    #expect(env.changeLog.undo(obj(r)["change_id"] as? String ?? "") == .undone)
    #expect(env.systemPrompts.loadSection(.whisperGlossary) == "Smikale")
  }

  @Test("Undo of a new command trashes it; undo of a delete restores it")
  func undoCommands() throws {
    let env = MCPTestEnv(level: .apply)
    let t = env.tools()
    let save = t.call(name: "save_command", arguments: ["name": "fresh", "text": "Do it.", "scope": "chat", "rationale": "r"], access: .write)
    let file = env.commands.fileURL(forName: "fresh")
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(env.changeLog.undo(obj(save)["change_id"] as? String ?? "") == .undone)
    #expect(!FileManager.default.fileExists(atPath: file.path))

    _ = try env.commands.save(name: "keep", text: "Keep me.", scope: .both)
    let original = try String(contentsOf: env.commands.fileURL(forName: "keep"), encoding: .utf8)
    let del = t.call(name: "delete_command", arguments: ["name": "keep", "rationale": "r"], access: .write)
    #expect(!FileManager.default.fileExists(atPath: env.commands.fileURL(forName: "keep").path))
    #expect(env.changeLog.undo(obj(del)["change_id"] as? String ?? "") == .undone)
    #expect(try String(contentsOf: env.commands.fileURL(forName: "keep"), encoding: .utf8) == original)
  }

  @Test("Change log persists and is newest first")
  func changeLogPersistence() {
    let env = MCPTestEnv()
    let t = env.tools()
    _ = t.call(name: "add_glossary_terms", arguments: ["terms": ["Alpha"], "rationale": "r"], access: .write)
    _ = t.call(name: "add_glossary_terms", arguments: ["terms": ["Beta"], "rationale": "r"], access: .write)
    let reopened = MCPChangeLog(directory: env.dir, targets: env.changeLog.targets, recordHistory: { _, _, _, _, _ in })
    #expect(reopened.changes.count == 2)
    #expect(reopened.changes.first?.newContent?.contains("Beta") == true)
  }
}

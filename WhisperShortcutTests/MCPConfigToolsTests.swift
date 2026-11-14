import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Scratch stores + fake settings for the MCP configuration tools. Nothing touches the real
/// Application Support directory.
final class MCPTestEnv: @unchecked Sendable {
  let dir: URL
  let systemPrompts: SystemPromptsStore
  let writingStyle: WritingStyleStore
  let commands: UserCommandStore
  let changeLog: MCPChangeLog
  let proposals: MCPProposalStore
  var level: MCPConfigAccessLevel
  var logging = true
  var sharing = true
  /// Oldest first, as the log files hold them.
  var interactions: [InteractionLogEntry] = []
  var signals: [SignalLogEntry] = []
  var settings: [String: String] = ["transcription_model": "whisper-base", "chat_model": "gemini-x"]
  /// "section|content|source" per history row the store appended, oldest first.
  var history: [String] {
    UserContextLog.decodeLines([systemPrompts.historyFileURL], as: UnifiedSystemPromptHistoryEntry.self)
      .map { "\($0.section)|\($0.content)|\($0.source)" }
  }

  // MARK: - Settings catalog fakes (never touch the real UserDefaults, Keychain or SMAppService)
  let testDefaults: UserDefaults
  let settingsCatalog: [MCPSetting]
  /// Mutable backing for the fakes above, boxed so closures built in `init` (before `self` fully
  /// exists) and the test's later assertions share the same state.
  final class Box {
    var hasAccessibility = true
    var hasScreenRecording = true
    var hasScreenshotFolder = true
    var launchAtLogin = false
    var shortcutConfig: ShortcutConfig = .default
    var notifications: [(Notification.Name, Any?)] = []
    var writingStyleToggles: [Bool] = []
  }
  let box: Box

  init(level: MCPConfigAccessLevel = .apply) {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-cfg-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    systemPrompts = SystemPromptsStore(contextDirectoryURL: dir)
    testDefaults = UserDefaults(suiteName: "mcp-settings-test-\(UUID().uuidString)")!
    writingStyle = WritingStyleStore(
      directory: dir.appendingPathComponent("ws"), isEnabled: { true }, defaults: testDefaults)
    commands = UserCommandStore(directoryURL: dir.appendingPathComponent("commands"), reservedNames: { ["help"] })
    let targets = MCPConfigTargets(systemPrompts: systemPrompts, writingStyle: writingStyle, commands: commands)
    let box = Box()
    self.box = box
    let deps = MCPSettingsCatalog.Dependencies(
      defaults: testDefaults,
      hasAccessibilityPermission: { box.hasAccessibility },
      hasScreenRecordingPermission: { box.hasScreenRecording },
      hasScreenshotFolder: { box.hasScreenshotFolder },
      isLaunchAtLoginEnabled: { box.launchAtLogin },
      setLaunchAtLogin: { box.launchAtLogin = $0 },
      loadShortcutConfig: { box.shortcutConfig },
      saveShortcutConfig: { box.shortcutConfig = $0 },
      postNotification: { name, object in box.notifications.append((name, object)) },
      // The live hook posts into the user's app. Record the call on the same notification list
      // the catalog tests already read.
      postSelectionsChanged: { box.notifications.append((.modelSelectionsReconciled, nil)) },
      // The live hook runs a real Gmail import and Gemini derive and shows the review panel.
      writingStyleToggled: { box.writingStyleToggles.append($0) })
    self.settingsCatalog = MCPSettingsCatalog.build(deps)
    changeLog = MCPChangeLog(directory: dir, targets: targets, settingsCatalog: settingsCatalog)
    proposals = MCPProposalStore(
      directory: dir, applier: MCPConfigApplier(targets: targets, changeLog: changeLog),
      settingsCatalog: settingsCatalog)
    self.level = level
  }

  func tools() -> MCPConfigTools {
    MCPConfigTools(env: MCPConfigEnvironment(
      targets: changeLog.targets, proposals: proposals, changeLog: changeLog,
      accessLevel: { self.level },
      contextLoggingEnabled: { self.logging },
      shareRecentInteractions: { self.sharing },
      interactionLog: { _ in (self.interactions, self.signals) },
      settings: { self.settings },
      shortcuts: { [["action": "Dictate", "shortcut": "F5", "enabled": true]] },
      writingStyleEnabled: { true },
      appVersion: "9.9", settingsCatalog: settingsCatalog))
  }

  func dispatcher() -> MCPDispatcher {
    let meetings = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-mt-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
    try? "[00:05] Speaker A: Hi there\n".write(
      to: meetings.appendingPathComponent("Meeting-2026-10-19-110109.txt"), atomically: true, encoding: .utf8)
    return MCPDispatcher(
      meetingTools: MCPMeetingTools(meetingsDirectory: meetings, liveStem: { "Meeting-2026-10-19-110109" }),
      configTools: tools())
  }

  static func entry(_ json: String) -> InteractionLogEntry {
    try! JSONDecoder().decode(InteractionLogEntry.self, from: Data(json.utf8))
  }
}

@Suite("MCP config tools")
struct MCPConfigToolsTests {

  private let writeTools: Set<String> = [
    "add_glossary_terms", "update_system_prompt", "update_writing_style_profile", "save_command",
    "delete_command", "report_problem",
  ]

  private func obj(_ r: MCPToolResult) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any]) ?? [:]
  }

  private func glossary(_ env: MCPTestEnv) -> String { env.systemPrompts.loadWhisperGlossary() }

  // MARK: access

  @Test("Read token: write tools are never listed, and a write call is an error", arguments: [
    (MCPConfigAccessLevel.read, false, "level read"),
    (.propose, false, "level propose"),
    (.apply, true, "level apply rejects the call"),
  ])
  func readTokenCannotWrite(level: MCPConfigAccessLevel, rejectsCall: Bool, label: String) {
    let env = MCPTestEnv(level: level)
    let t = env.tools()
    let names = Set(t.toolDefinitions(access: .read).compactMap { $0["name"] as? String })
    #expect(names.isDisjoint(with: writeTools), "\(label)")
    #expect(names.contains("get_proposal_status"), "\(label)")
    let status = t.call(name: "get_proposal_status", arguments: ["id": "none"], access: .read)
    #expect(status.text.contains("No proposal"), "\(label)")
    #expect(!status.text.contains("can only read"), "\(label)")
    guard rejectsCall else { return }
    let r = t.call(name: "add_glossary_terms", arguments: ["terms": ["Wianco"], "rationale": "x"], access: .read)
    #expect(r.isError, "\(label)")
    #expect(r.text.contains("can only read"), "\(label)")
    #expect(!glossary(env).contains("Wianco"), "\(label)")
    #expect(env.changeLog.changes.isEmpty, "\(label)")
  }

  @Test("Write token at level read: list is still stable (write tools listed), but the call is rejected")
  func writeTokenLevelRead() {
    let env = MCPTestEnv(level: .read)
    let t = env.tools()
    // tools/list must not vary with the configured access level — clients cache it per session.
    let names = Set(t.toolDefinitions(access: .write).compactMap { $0["name"] as? String })
    #expect(names.isSuperset(of: writeTools))
    // Enforcement still happens at call time.
    let r = t.call(name: "add_glossary_terms", arguments: ["terms": ["Wianco"], "rationale": "x"], access: .write)
    #expect(r.isError)
    #expect(r.text.contains("is off"))
    #expect(!glossary(env).contains("Wianco"))
  }

  @Test("Write token at every access level: write tools listed the same way, each requiring user interaction")
  func writeToolsListed() {
    for level in [MCPConfigAccessLevel.read, .propose, .apply] {
      let env = MCPTestEnv(level: level)
      let defs = env.tools().toolDefinitions(access: .write)
      let write = defs.filter { writeTools.contains($0["name"] as? String ?? "") }
      #expect(Set(write.compactMap { $0["name"] as? String }) == writeTools)
      for d in write {
        let meta = d["_meta"] as? [String: Any]
        #expect(meta?["anthropic/requiresUserInteraction"] as? Bool == true)
      }
    }
  }

  @Test("Every listed tool has an annotations object with a title")
  func everyToolHasAnnotationsTitle() {
    let env = MCPTestEnv(level: .apply)
    let d = env.dispatcher()
    let all = MCPMeetingTools.toolDefinitions + d.configTools.toolDefinitions(access: .write)
    #expect(!all.isEmpty)
    for tool in all {
      let annotations = tool["annotations"] as? [String: Any]
      let name = tool["name"] as? String ?? "?"
      #expect(annotations != nil, "\(name) has no annotations")
      #expect(((annotations?["title"] as? String)?.isEmpty == false), "\(name) has no annotations.title")
    }
  }

  @Test("Rationale is required and capped")
  func rationale() {
    let env = MCPTestEnv()
    let t = env.tools()
    #expect(t.call(name: "add_glossary_terms", arguments: ["terms": ["A"]], access: .write).isError)
    let long = String(repeating: "x", count: 301)
    #expect(t.call(name: "add_glossary_terms", arguments: ["terms": ["A"], "rationale": long], access: .write).isError)
  }

  // MARK: system prompts

  @Test("Every system-prompt section at level apply becomes a proposal; file unchanged")
  func guardedSections() {
    let env = MCPTestEnv(level: .apply)
    let t = env.tools()
    let before = env.systemPrompts.loadFullContent()
    for section in ["dictation", "chat", "whisper_glossary", "dictate_prompt", "read_aloud_rewrite"] {
      let r = t.call(name: "update_system_prompt",
        arguments: ["section": section, "content": "New rule for \(section)", "rationale": "r"], access: .write)
      #expect(!r.isError)
      #expect(obj(r)["status"] as? String == "pending_review")
      #expect(obj(r)["id"] as? String != nil)
    }
    #expect(env.systemPrompts.loadFullContent() == before)
    #expect(env.proposals.pending.count == 5)
    #expect(env.changeLog.changes.isEmpty)
  }

  @Test("dictate_prompt and read_aloud_rewrite are proposals even at apply")
  func dictatePromptLevels() {
    let env = MCPTestEnv(level: .apply)
    let t = env.tools()
    let beforePrompt = env.systemPrompts.loadSection(.promptMode)
    let beforeRead = env.systemPrompts.loadSection(.readAloudRewrite)
    let r = t.call(name: "update_system_prompt",
      arguments: ["section": "dictate_prompt", "content": "Always be brief.", "rationale": "r"], access: .write)
    #expect(obj(r)["status"] as? String == "pending_review")
    #expect(env.systemPrompts.loadSection(.promptMode) == beforePrompt)
    #expect(env.changeLog.changes.isEmpty)

    let p = t.call(name: "update_system_prompt",
      arguments: ["section": "read_aloud_rewrite", "content": "Read it slowly.", "rationale": "r"], access: .write)
    #expect(obj(p)["status"] as? String == "pending_review")
    #expect(env.systemPrompts.loadSection(.readAloudRewrite) == beforeRead)
  }

  @Test("Section over its limit and writing profile over maxChars are rejected")
  func caps() {
    let env = MCPTestEnv()
    let t = env.tools()
    let big = String(repeating: "a", count: ChatToolRegistry.instructionsSectionLimit(for: .promptModeAdditions) + 1)
    let r = t.call(name: "update_system_prompt",
      arguments: ["section": "dictate_prompt", "content": big, "rationale": "r"], access: .write)
    #expect(r.isError)
    #expect(env.systemPrompts.loadSection(.promptModeAdditions) != big)
    let bigProfile = String(repeating: "a", count: WritingStyleStore.maxChars + 1)
    let w = t.call(name: "update_writing_style_profile", arguments: ["content": bigProfile, "rationale": "r"], access: .write)
    #expect(w.isError)
    #expect(env.writingStyle.loadProfile() != bigProfile)
    let bad = t.call(name: "update_system_prompt",
      arguments: ["section": "nope", "content": "x", "rationale": "r"], access: .write)
    #expect(bad.isError)
  }

  @Test("Writing style: applied at apply, proposal at propose, apply stamps the profile")
  func writingStyle() {
    let env = MCPTestEnv(level: .apply)
    env.testDefaults.set(4, forKey: UserDefaultsKeys.writingStyleSamplesSinceProfile)
    env.testDefaults.set(Date(timeIntervalSince1970: 50), forKey: UserDefaultsKeys.writingStyleProfileDismissedAt)
    let t = env.tools()
    let r = t.call(name: "update_writing_style_profile", arguments: ["content": "Short and direct.", "rationale": "r"], access: .write)
    #expect(obj(r)["status"] as? String == "applied")
    #expect(env.writingStyle.loadProfile() == "Short and direct.")
    #expect(env.testDefaults.object(forKey: UserDefaultsKeys.writingStyleProfileUpdatedAt) != nil)
    #expect(env.testDefaults.integer(forKey: UserDefaultsKeys.writingStyleSamplesSinceProfile) == 0)
    #expect(env.testDefaults.object(forKey: UserDefaultsKeys.writingStyleProfileDismissedAt) == nil)
    env.level = .propose
    let p = t.call(name: "update_writing_style_profile", arguments: ["content": "Other.", "rationale": "r"], access: .write)
    #expect(obj(p)["status"] as? String == "pending_review")
    #expect(env.writingStyle.loadProfile() == "Short and direct.")
  }

  // MARK: glossary

  @Test("add_glossary_terms is additive, keeps (not ...) lines, dedupes case-insensitively")
  func glossaryAdditive() {
    let env = MCPTestEnv()
    env.systemPrompts.updateSection(.whisperGlossary, content: "Wianco (not \"Vianco\")\nSmikale", source: .settings)
    let t = env.tools()
    let r = t.call(name: "add_glossary_terms",
      arguments: ["terms": ["wianco", "SMIKALE", "Michelbach (not \"Mickelbach\", \"Michelbag\")", "sabaki.dance"], "rationale": "names"],
      access: .write)
    #expect(!r.isError)
    #expect(obj(r)["status"] as? String == "applied")
    let g = glossary(env)
    #expect(g.contains("Wianco (not \"Vianco\")"))
    #expect(g.contains("Smikale"))
    #expect(!g.contains("wianco"))
    #expect(!g.contains("SMIKALE"))
    #expect(g.contains("Michelbach (not \"Mickelbach\", \"Michelbag\")"))
    #expect(g.contains("sabaki.dance"))
    #expect(env.changeLog.changes.first?.kind == .glossaryAdd)

    let again = t.call(name: "add_glossary_terms", arguments: ["terms": ["sabaki.dance"], "rationale": "r"], access: .write)
    #expect(obj(again)["status"] as? String == "no_change")
  }

  @Test("add_glossary_terms at level propose creates a reviewable proposal instead of writing; apply still writes directly")
  func glossaryProposeVsApply() {
    let proposeEnv = MCPTestEnv(level: .propose)
    let pt = proposeEnv.tools()
    let p = pt.call(name: "add_glossary_terms", arguments: ["terms": ["Wianco"], "rationale": "names"], access: .write)
    #expect(!p.isError)
    #expect(obj(p)["status"] as? String == "pending_review")
    #expect(!glossary(proposeEnv).contains("Wianco"))
    #expect(proposeEnv.proposals.pending.count == 1)
    #expect(proposeEnv.proposals.pending[0].section == SystemPromptSection.whisperGlossary.rawValue)

    let applyEnv = MCPTestEnv(level: .apply)
    let at = applyEnv.tools()
    let a = at.call(name: "add_glossary_terms", arguments: ["terms": ["Wianco"], "rationale": "names"], access: .write)
    #expect(!a.isError)
    #expect(obj(a)["status"] as? String == "applied")
    #expect(glossary(applyEnv).contains("Wianco"))
    #expect(applyEnv.proposals.pending.isEmpty)
  }

  @Test("add_glossary_terms rejects over budget with nothing written")
  func glossaryBudget() {
    let env = MCPTestEnv()
    let filler = (0..<110).map { "Filler\($0)xyz" }.joined(separator: "\n")  // ~1,300 chars
    let base = String(filler.prefix(SystemPromptsStore.glossaryCharBudget - 10)).trimmingCharacters(in: .whitespacesAndNewlines)
    env.systemPrompts.updateSection(.whisperGlossary, content: base, source: .settings)
    let t = env.tools()
    let r = t.call(name: "add_glossary_terms", arguments: ["terms": ["Newterm here"], "rationale": "r"], access: .write)
    #expect(r.isError)
    #expect(r.text.contains("\(SystemPromptsStore.glossaryCharBudget)"))
    #expect(glossary(env) == base)
    #expect(env.changeLog.changes.isEmpty)
  }

  @Test("add_glossary_terms rejects a term over 60 characters or 5 words")
  func glossaryTermLimits() {
    let env = MCPTestEnv()
    let t = env.tools()
    let before = glossary(env)
    let long = String(repeating: "a", count: 61)
    #expect(t.call(name: "add_glossary_terms", arguments: ["terms": [long], "rationale": "r"], access: .write).isError)
    #expect(t.call(name: "add_glossary_terms", arguments: ["terms": ["one two three four five six"], "rationale": "r"], access: .write).isError)
    #expect(t.call(name: "add_glossary_terms", arguments: ["terms": ["Good", "a, b"], "rationale": "r"], access: .write).isError)
    #expect(glossary(env) == before)
  }

  @Test("20 concurrent add_glossary_terms calls all land")
  func concurrentGlossary() async {
    let env = MCPTestEnv()
    let t = env.tools()
    nonisolated(unsafe) let tools = t
    await Task.detached {
      DispatchQueue.concurrentPerform(iterations: 20) { i in
        let r = tools.call(name: "add_glossary_terms", arguments: ["terms": ["Term\(i)"], "rationale": "r"], access: .write)
        if r.isError { Issue.record("call \(i) failed: \(r.text)") }
      }
    }.value
    let g = glossary(env)
    for i in 0..<20 { #expect(g.contains("Term\(i)")) }
    #expect(env.changeLog.changes.count == 20)
  }

  // MARK: commands

  @Test("save_command and delete_command follow the level; names validated")
  func commands() {
    let env = MCPTestEnv(level: .apply)
    let t = env.tools()
    let ok = t.call(name: "save_command",
      arguments: ["name": "weekly-note", "text": "Summarize the week.", "scope": "chat", "label": "Weekly", "rationale": "r"],
      access: .write)
    #expect(obj(ok)["status"] as? String == "applied")
    #expect(env.commands.command(named: "weekly-note")?.scope == .chat)
    #expect(t.call(name: "save_command", arguments: ["name": "Bad Name", "text": "x", "scope": "chat", "rationale": "r"], access: .write).isError)
    #expect(t.call(name: "save_command", arguments: ["name": "help", "text": "x", "scope": "chat", "rationale": "r"], access: .write).isError)
    env.level = .propose
    let del = t.call(name: "delete_command", arguments: ["name": "weekly-note", "rationale": "r"], access: .write)
    #expect(obj(del)["status"] as? String == "pending_review")
    #expect(FileManager.default.fileExists(atPath: env.commands.fileURL(forName: "weekly-note").path))
  }

  @Test("UserCommandStore.save round-trips through the parser; invalid and reserved names rejected")
  func saveRoundTrip() throws {
    let env = MCPTestEnv()
    let url = try env.commands.save(name: "mail-reply", text: "Write a short reply.\n\nBe polite.", scope: .meeting, label: "Reply", description: "Short reply")
    let text = try String(contentsOf: url, encoding: .utf8)
    let parsed = UserCommandParser.parse(fileName: "mail-reply.md", contents: text, reservedNames: [], fileURL: url)
    #expect(parsed.command?.scope == .meeting)
    #expect(parsed.command?.label == "Reply")
    #expect(parsed.command?.description == "Short reply")
    #expect(parsed.command?.body == "Write a short reply.\n\nBe polite.")
    // overwrite allowed
    _ = try env.commands.save(name: "mail-reply", text: "Changed.", scope: .both)
    #expect(env.commands.command(named: "mail-reply")?.body == "Changed.")
    #expect(throws: (any Error).self) { try env.commands.save(name: "Bad", text: "x", scope: .both) }
    #expect(throws: (any Error).self) { try env.commands.save(name: "help", text: "x", scope: .both) }
    #expect(throws: (any Error).self) { try env.commands.save(name: "empty", text: "  ", scope: .both) }
  }

  // MARK: reads

  @Test("get_recent_interactions needs both toggles and caps fields")
  func recentInteractions() {
    let env = MCPTestEnv()
    let t = env.tools()
    let big = String(repeating: "z", count: 5_000)
    env.interactions = [MCPTestEnv.entry(#"{"ts":"2026-10-20T10:00:00Z","mode":"transcription","result":"\#(big)","userInstruction":"fix"}"#)]
    env.logging = false
    let a = t.call(name: "get_recent_interactions", arguments: [:], access: .read)
    #expect(a.isError)
    #expect(a.text.contains("Save usage data"))
    env.logging = true; env.sharing = false
    let b = t.call(name: "get_recent_interactions", arguments: [:], access: .read)
    #expect(b.isError)
    #expect(b.text.contains("recent dictations"))
    env.sharing = true
    let c = t.call(name: "get_recent_interactions", arguments: [:], access: .read)
    #expect(!c.isError)
    let items = obj(c)["interactions"] as? [[String: Any]]
    #expect(items?.count == 1)
    let result = items?.first?["result"] as? String
    #expect((result?.count ?? 0) <= MCPConfigTools.maxFieldCharacters + 1)
    #expect(items?.first?["userInstruction"] as? String == "fix")
    #expect(obj(c)["total_available"] as? Int == 1)
    #expect(obj(c)["next_offset"] is NSNull)
  }

  @Test("get_recent_interactions pages newest first and reports total_available / next_offset")
  func recentInteractionsPaging() {
    let env = MCPTestEnv()
    env.interactions = (1...5).map { i in
      MCPTestEnv.entry(#"{"ts":"2026-10-2\#(i)T10:00:00Z","mode":"transcription","result":"r\#(i)"}"#)
    }
    let t = env.tools()
    let first = obj(t.call(name: "get_recent_interactions", arguments: ["limit": 2], access: .read))
    let firstItems = first["interactions"] as? [[String: Any]]
    #expect(firstItems?.map { $0["result"] as? String } == ["r5", "r4"])
    #expect(first["total_available"] as? Int == 5)
    #expect(first["next_offset"] as? Int == 2)
    let last = obj(t.call(name: "get_recent_interactions", arguments: ["limit": 2, "offset": 4], access: .read))
    #expect((last["interactions"] as? [[String: Any]])?.map { $0["result"] as? String } == ["r1"])
    #expect(last["next_offset"] is NSNull)
  }

  @Test("get_recent_interactions filters by query, mode and since")
  func recentInteractionsFilters() {
    let env = MCPTestEnv()
    env.interactions = [
      MCPTestEnv.entry(#"{"ts":"2026-10-01T10:00:00Z","mode":"transcription","result":"Termin mit Wianco"}"#),
      MCPTestEnv.entry(#"{"ts":"2026-10-20T10:00:00Z","mode":"transcription","result":"Vianco hat angerufen"}"#),
      MCPTestEnv.entry(#"{"ts":"2026-10-21T10:00:00Z","mode":"prompt","userInstruction":"Mail an vianco"}"#),
    ]
    let t = env.tools()
    let q = obj(t.call(name: "get_recent_interactions", arguments: ["query": "VIANCO"], access: .read))
    #expect(q["total_available"] as? Int == 2)
    let m = obj(t.call(name: "get_recent_interactions", arguments: ["query": "vianco", "mode": "prompt"], access: .read))
    #expect(m["total_available"] as? Int == 1)
    let s = obj(t.call(name: "get_recent_interactions", arguments: ["since": "2026-10-15T00:00:00Z"], access: .read))
    #expect(s["total_available"] as? Int == 2)
    let bad = t.call(name: "get_recent_interactions", arguments: ["since": "last tuesday"], access: .read)
    #expect(bad.isError)
    let badMode = t.call(name: "get_recent_interactions", arguments: ["mode": "meetings"], access: .read)
    #expect(badMode.isError)
  }

  @Test("get_recent_interactions attaches the outcome signals and the new context fields")
  func recentInteractionsSignalsAndContext() {
    let env = MCPTestEnv()
    env.interactions = [
      MCPTestEnv.entry(
        #"{"ts":"2026-10-20T10:00:00.000Z","mode":"transcription","result":"hallo","appName":"Mail","appBundleId":"com.apple.mail","durationMs":2300,"language":"de","promptVersion":"default","audioRef":"old.wav"}"#)
    ]
    env.signals = [
      SignalLogEntry(ts: "2026-10-20T10:00:01.000Z", kind: "pasted", refTs: "2026-10-20T10:00:00.000Z", mode: "transcription", gapMs: 900, detail: nil),
      SignalLogEntry(ts: "2026-10-20T10:00:09.000Z", kind: "dictationRestart", refTs: "2026-10-20T10:00:00.000Z", mode: "transcription", gapMs: 9000, detail: ["autoPasteAvailable": "true"]),
      SignalLogEntry(ts: "2026-10-20T10:00:09.000Z", kind: "chatRetry", refTs: "2026-10-19T10:00:00.000Z", mode: "geminiChat", gapMs: 1, detail: nil),
    ]
    let item = (obj(env.tools().call(name: "get_recent_interactions", arguments: [:], access: .read))["interactions"]
      as? [[String: Any]])?.first
    #expect(item?["appName"] as? String == "Mail")
    #expect(item?["durationMs"] as? Int == 2300)
    #expect(item?["language"] as? String == "de")
    #expect(item?["promptVersion"] as? String == "default")
    #expect(item?["audioRef"] == nil)
    let kinds = (item?["signals"] as? [[String: Any]])?.compactMap { $0["kind"] as? String }
    #expect(kinds == ["pasted", "dictationRestart"])
  }

  @Test("get_configuration reports state, recipe and inline texts")
  func configuration() {
    let env = MCPTestEnv(level: .propose)
    env.systemPrompts.updateSection(.promptModeAdditions, content: "Custom rule.", source: .settings)
    _ = try? env.commands.save(name: "a-cmd", text: "Do it.", scope: .both)
    let r = env.tools().call(name: "get_configuration", arguments: ["include": ["system_prompts", "writing_style", "commands"]], access: .read)
    let o = obj(r)
    #expect(!r.isError)
    #expect(o["app_version"] as? String == "9.9")
    #expect((o["models"] as? [String: String])?["transcription_model"] == "whisper-base")
    let prompts = o["system_prompts"] as? [String: Any]
    #expect((prompts?["dictate_prompt"] as? [String: Any])?["customized"] as? Bool == true)
    #expect((prompts?["dictate_prompt"] as? [String: Any])?["purpose"] as? String != nil)
    #expect((prompts?["dictate_prompt"] as? [String: Any])?["warnings"] is [String])
    #expect((prompts?["dictation"] as? [String: Any])?["legacy_full_prompt"] == nil)
    #expect((prompts?["chat"] as? [String: Any])?["replaces_built_in"] == nil)
    #expect(
      (prompts?["dictate_prompt"] as? [String: Any])?["default_length"] as? Int
        == AppConstants.defaultPromptModeAdditions.count)
    #expect((o["ai_app_access"] as? [String: Any])?["level"] as? String == "propose")
    #expect((o["tune_recipe"] as? String)?.contains("get_configuration") == true)
    #expect((o["system_prompt_texts"] as? [String: String])?["dictate_prompt"] == "Custom rule.")
    #expect(((o["command_texts"] as? [[String: Any]])?.first?["name"]) as? String == "a-cmd")
    #expect(o["quick_prompts"] is [[String: Any]])
  }

  @Test("get_configuration shares quick-prompt usage only when recent dictations are shared")
  func configurationQuickPrompts() {
    let deniedMessage =
      "Turn on Save usage data and Let AI apps read my recent dictations to see how often each quick prompt is used."
    let description = MCPTestEnv().tools().toolDefinitions(access: .read)
      .first { $0["name"] as? String == "get_configuration" }?["description"] as? String
    #expect(description?.contains("quick prompts with how often each was used in 30 days") == true)

    let shared = obj(MCPTestEnv().tools().call(name: "get_configuration", arguments: [:], access: .read))
    #expect(shared["quick_prompts"] is [[String: Any]])

    let loggingOff = MCPTestEnv()
    loggingOff.logging = false
    let noLog = obj(loggingOff.tools().call(name: "get_configuration", arguments: [:], access: .read))
    #expect(noLog["quick_prompts"] as? String == deniedMessage)

    let sharingOff = MCPTestEnv()
    sharingOff.sharing = false
    let noShare = obj(sharingOff.tools().call(name: "get_configuration", arguments: [:], access: .read))
    #expect(noShare["quick_prompts"] as? String == deniedMessage)
  }

  @Test("No token leaks through any read output")
  func noSecrets() {
    let env = MCPTestEnv(level: .apply)
    let readTok = "READTOKEN-1234567890abcdef", writeTok = "WRITETOKEN-fedcba0987654321"
    env.settings = ["transcription_model": "whisper-base", "mcpToken": readTok, "mcp_write": writeTok, "api_key": "sk-secret"]
    env.interactions = [MCPTestEnv.entry(#"{"ts":"t","mode":"transcription","result":"hello"}"#)]
    let t = env.tools()
    var outputs: [String] = []
    outputs.append(t.call(name: "get_configuration", arguments: ["include": ["system_prompts", "writing_style", "commands"]], access: .write).text)
    outputs.append(t.call(name: "get_recent_interactions", arguments: [:], access: .read).text)
    outputs.append(MCPTuneRecipe.text(focus: "all"))
    outputs.append(MCPDispatcher.instructions)
    for res in t.resourceList() { outputs.append(t.resourceRead(uri: res["uri"] as! String) ?? "") }
    outputs.append(String(describing: t.resourceList()))
    for o in outputs {
      #expect(!o.contains(readTok))
      #expect(!o.contains(writeTok))
      #expect(!o.contains("sk-secret"))
    }
  }

  // MARK: report_problem

  @Test("report_problem saves a pending problem report whose body has every section")
  func reportProblem() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(name: "report_problem", arguments: [
      "title": "Glossary appended",
      "what_happens": "The glossary is appended after the dictation.",
      "examples": ["gesperrt werden. Name Product"],
      "suspected_cause": "The model echoes the glossary.",
      "why_not_settings": "The prompt already forbids it.",
    ], access: .write)
    #expect(!r.isError)
    #expect(r.text.contains("Saved as a problem report"))
    #expect(env.proposals.pending.count == 1)
    #expect(env.changeLog.changes.isEmpty)
    let proposal = env.proposals.pending[0]
    #expect(proposal.kind == .problemReport)
    #expect(proposal.title == "Glossary appended")
    let body = proposal.proposedContent ?? ""
    #expect(body.contains("## What happens\nThe glossary is appended after the dictation."))
    #expect(body.contains("## Examples\n- gesperrt werden. Name Product"))
    #expect(body.contains("## Suspected cause\nThe model echoes the glossary."))
    #expect(body.contains("## Why settings can't fix it\nThe prompt already forbids it."))
    #expect(body.contains("Reported by an AI app via WhisperShortcut's MCP server."))
    #expect(r.text.contains(proposal.id))
  }

  private struct RejectedReport: Sendable {
    let note: String
    let includeWhy: Bool
    let examples: [String]
    let messageFragment: String?
  }

  private static let rejectedReports: [RejectedReport] = [
    .init(note: "missing why_not_settings", includeWhy: false, examples: [], messageFragment: "why_not_settings"),
    .init(note: "more than three examples", includeWhy: true, examples: ["one", "two", "three", "four"],
          messageFragment: nil),
  ]

  @Test("report_problem rejects a missing why or too many examples", arguments: rejectedReports)
  private func reportProblemRejected(_ row: RejectedReport) {
    let env = MCPTestEnv()
    var arguments: [String: Any] = [
      "title": "Glossary appended",
      "what_happens": "The glossary is appended after the dictation.",
    ]
    if row.includeWhy { arguments["why_not_settings"] = "The prompt already forbids it." }
    if !row.examples.isEmpty { arguments["examples"] = row.examples }
    let r = env.tools().call(name: "report_problem", arguments: arguments, access: .write)
    #expect(r.isError, "\(row.note)")
    if let messageFragment = row.messageFragment {
      #expect(r.text.contains(messageFragment), "\(row.note)")
    }
    #expect(env.proposals.pending.isEmpty, "\(row.note)")
  }

  // MARK: prompts and resources

  @Test("prompts/list and prompts/get with focus")
  func prompts() throws {
    let d = MCPTestEnv().dispatcher()
    let list = d.dispatch(["jsonrpc": "2.0", "id": 1, "method": "prompts/list"], access: .read)
    let prompts = (list?["result"] as? [String: Any])?["prompts"] as? [[String: Any]]
    #expect(prompts?.first?["name"] as? String == "tune_whisper_shortcut")
    let get = d.dispatch(["jsonrpc": "2.0", "id": 2, "method": "prompts/get",
      "params": ["name": "tune_whisper_shortcut", "arguments": ["focus": "emails"]]], access: .read)
    let messages = (get?["result"] as? [String: Any])?["messages"] as? [[String: Any]]
    let text = (messages?.first?["content"] as? [String: Any])?["text"] as? String
    #expect(text?.contains("Focus: emails") == true)
    #expect(text?.contains("get_configuration") == true)
    let bad = d.dispatch(["jsonrpc": "2.0", "id": 3, "method": "prompts/get", "params": ["name": "x"]], access: .read)
    #expect(bad?["error"] != nil)
  }

  @Test("resources/list and resources/read")
  func resources() throws {
    let env = MCPTestEnv()
    env.systemPrompts.updateSection(.promptModeAdditions, content: "Be brief.", source: .settings)
    env.writingStyle.saveProfile("Direct.")
    _ = try env.commands.save(name: "daily", text: "Plan my day.", scope: .chat)
    let d = env.dispatcher()
    let list = d.dispatch(["jsonrpc": "2.0", "id": 1, "method": "resources/list"], access: .read)
    let uris = ((list?["result"] as? [String: Any])?["resources"] as? [[String: Any]])?.compactMap { $0["uri"] as? String } ?? []
    #expect(uris.contains("whisper-shortcut://system-prompt/dictate_prompt"))
    #expect(uris.contains("whisper-shortcut://writing-style/profile"))
    #expect(uris.contains("whisper-shortcut://commands/daily"))
    func read(_ uri: String) -> [String: Any]? {
      d.dispatch(["jsonrpc": "2.0", "id": 2, "method": "resources/read", "params": ["uri": uri]], access: .read)
    }
    let c = (read("whisper-shortcut://system-prompt/dictate_prompt")?["result"] as? [String: Any])?["contents"] as? [[String: Any]]
    #expect(c?.first?["text"] as? String == "Be brief.")
    #expect(c?.first?["mimeType"] as? String == "text/markdown")
    let w = (read("whisper-shortcut://writing-style/profile")?["result"] as? [String: Any])?["contents"] as? [[String: Any]]
    #expect(w?.first?["text"] as? String == "Direct.")
    #expect(read("whisper-shortcut://commands/daily")?["result"] != nil)
    #expect(read("whisper-shortcut://nope")?["error"] != nil)
  }
}

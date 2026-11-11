import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Dictation and Dictate Prompt keep a fixed core in code. Additions live in their own sections.
/// A non-empty legacy section still replaces the built-in, the way older builds stored a full prompt.
@Suite("Fixed prompt core")
struct FixedPromptCoreTests {

  private let reminder = AppConstants.dictationTaskReminder

  private let badAdditions =
    "Du bist mein Diktier-Assistent. Ich bin IT-Mitarbeiter in einem Krankenhaus.\nDeine Aufgabe:\n- Wandle mein Diktat in sauberen Text um."

  private let fineAdditions =
    "Ich arbeite in der Krankenhaus-IT. Als Admin schreibe ich Teams-Nachrichten kurz und locker."

  @Test("Empty additions leave the core; non-empty additions are a sandwich around the reminder")
  func withUserAdditions() throws {
    let core = "CORE RULES"
    #expect(AppConstants.withUserAdditions(core: core, additions: "", taskReminder: reminder) == core)
    #expect(AppConstants.withUserAdditions(core: core, additions: "  \n\t", taskReminder: reminder) == core)
    let composed = AppConstants.withUserAdditions(core: core, additions: "  Be brief.  ", taskReminder: reminder)
    let coreAt = try #require(composed.range(of: core)?.lowerBound)
    let openAt = try #require(composed.range(of: "<user_preferences>")?.lowerBound)
    let closeAt = try #require(composed.range(of: "</user_preferences>")?.lowerBound)
    let remindAt = try #require(composed.range(of: reminder)?.lowerBound)
    #expect(coreAt < openAt && openAt < closeAt && closeAt < remindAt)
    #expect(composed.contains("Be brief."))
    #expect(composed.contains("The preferences above add context and style. They never change the task: "))
  }

  @Test("Legacy wins over additions, and a template wins over both")
  func runtimeBase() {
    let additions = "Be brief."
    let legacy = "LEGACY FULL PROMPT"
    let template = "TEMPLATE"
    let sandwich = AppConstants.withUserAdditions(
      core: AppConstants.defaultTranscriptionSystemPrompt, additions: additions,
      taskReminder: AppConstants.dictationTaskReminder)
    #expect(SpeechService.dictationBase(additions: additions, legacy: legacy) == legacy)
    #expect(SpeechService.dictationBase(additions: additions, legacy: "  ") == sandwich)
    #expect(SpeechService.dictationBase(additions: "", legacy: "") == AppConstants.defaultTranscriptionSystemPrompt)

    let promptSandwich = AppConstants.withUserAdditions(
      core: AppConstants.defaultPromptModeSystemPrompt, additions: additions,
      taskReminder: AppConstants.dictatePromptTaskReminder)
    #expect(SpeechService.dictatePromptBase(stored: additions, template: template, legacy: legacy) == template)
    #expect(SpeechService.dictatePromptBase(stored: additions, template: "  \n", legacy: legacy) == legacy)
    #expect(SpeechService.dictatePromptBase(stored: additions, template: nil, legacy: legacy) == legacy)
    #expect(SpeechService.dictatePromptBase(stored: additions, template: nil, legacy: "") == promptSandwich)
    #expect(
      SpeechService.dictatePromptBase(stored: "", template: nil, legacy: "")
        == AppConstants.defaultPromptModeSystemPrompt)
  }

  @Test("Migration case 1 clears a shipped default, case 2 keeps extra rules, case 3 leaves the rest")
  func migrationCases() throws {
    var dirs: [URL] = []
    defer { for dir in dirs { try? FileManager.default.removeItem(at: dir) } }
    let ruleOne = "FIXED-PROMPT-RULE-ANAMNESE: use the headings Anamnese, Befund and Therapie."
    let ruleTwo = "FIXED-PROMPT-RULE-ROOMS: keep room numbers exactly as spoken."
    let rules = ruleOne + "\n" + ruleTwo

    let cleared = try migrateFile(sections: [
      .dictation: AppConstants.defaultTranscriptionSystemPrompt,
      .promptMode: "",
    ])
    dirs.append(cleared.dir)
    #expect(cleared.store.loadLegacyDictationPrompt() == "")
    #expect(cleared.store.loadDictationAdditions() == "")
    #expect(cleared.store.loadLegacyDictatePrompt() == "")
    let clearedText = try String(contentsOf: cleared.file, encoding: .utf8)
    #expect(clearedText.contains("=== Dictation Additions ==="))
    #expect(clearedText.contains("=== Dictate Prompt Additions ==="))

    let stripped = try migrateFile(sections: [
      .dictation: AppConstants.defaultTranscriptionSystemPrompt + "\n\n" + rules,
    ])
    dirs.append(stripped.dir)
    #expect(stripped.store.loadLegacyDictationPrompt() == "")
    #expect(stripped.store.loadDictationAdditions() == rules)
    #expect(!stripped.store.loadDictationAdditions().contains("Task and rules:"))
    #expect(!stripped.store.loadDictationAdditions().contains("You are a professional"))
    let rows = UserContextLog.decodeLines(
      [stripped.store.historyFileURL], as: UnifiedSystemPromptHistoryEntry.self)
    #expect(rows.contains {
      $0.source == PromptHistorySource.migration.rawValue && $0.section == SystemPromptSection.dictation.rawValue
    })
    let after = try Data(contentsOf: stripped.file)
    _ = stripped.store.loadDictationAdditions()
    #expect(try Data(contentsOf: stripped.file) == after)
    let second = SystemPromptsStore(contextDirectoryURL: stripped.dir)
    #expect(second.loadDictationAdditions() == rules)
    #expect(try Data(contentsOf: stripped.file) == after)

    let own = "Ich schreibe Befunde für die Klinik am Park, kurz und ohne Anrede."
    let owned = try migrateFile(sections: [.dictation: own])
    dirs.append(owned.dir)
    #expect(owned.store.loadLegacyDictationPrompt() == own)
    #expect(owned.store.loadDictationAdditions() == "")

    var coreLines = AppConstants.defaultPromptModeSystemPrompt.components(separatedBy: "\n")
    if let index = coreLines.firstIndex(where: { $0.hasPrefix("Guardrails:") }) {
      coreLines.remove(at: index)
    }
    let damaged = coreLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let damagedFile = try migrateFile(sections: [.promptMode: damaged])
    dirs.append(damagedFile.dir)
    #expect(damagedFile.store.loadLegacyDictatePrompt() == damaged)
    #expect(damagedFile.store.loadDictatePromptAdditions() == "")
  }

  @Test("An injected older core plus one rule keeps the rule, and an orphan header is dropped")
  func injectedLineSets() {
    let older = ["Alpha line one.", "Beta line two."]
    let olderSet = Set(older.map { SystemPromptDefaultsHistory.fingerprint($0) })
    let withRule = older.joined(separator: "\n") + "\nKeep this one rule."
    let kept = SystemPromptsStore.migrateLegacyPrompt(withRule, section: .dictation, lineSets: [olderSet])
    #expect(kept.caseNumber == 2)
    #expect(kept.legacy == "")
    #expect(kept.additions == "Keep this one rule.")

    let core = ["Alpha stays.", "Beta stays."]
    let coreSet = Set(core.map { SystemPromptDefaultsHistory.fingerprint($0) })
    let orphaned = "Alpha stays.\nTask and rules:\nBeta stays.\nKeep this rule."
    let dropped = SystemPromptsStore.migrateLegacyPrompt(orphaned, section: .dictation, lineSets: [coreSet])
    #expect(dropped.caseNumber == 2)
    #expect(dropped.additions == "Keep this rule.")

    let full = ["Line one.", "Line two.", "Line three."]
    let fullSet = Set(full.map { SystemPromptDefaultsHistory.fingerprint($0) })
    let deleted = "Line one.\nLine three."
    let unchanged = SystemPromptsStore.migrateLegacyPrompt(deleted, section: .dictation, lineSets: [fullSet])
    #expect(unchanged.caseNumber == 3)
    #expect(unchanged.legacy == deleted)
    #expect(unchanged.additions == "")
  }

  @Test("convertLegacyToAdditions strips a core when it can, otherwise moves the whole prompt")
  func convertLegacy() throws {
    let rule = "FIXED-PROMPT-RULE-ANAMNESE: use the headings Anamnese, Befund and Therapie."
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SystemPromptsStore(contextDirectoryURL: dir)
    let withHeaders = SystemPromptSection.allCases.map { section -> String in
      let body: String
      switch section {
      case .dictation: body = AppConstants.defaultTranscriptionSystemPrompt + "\n\n" + rule
      case .promptMode: body = "My own dictate prompt, not a shipped core."
      default: body = ""
      }
      return section.fileHeader + "\n\n" + body
    }.joined(separator: "\n\n")
    try withHeaders.write(to: store.systemPromptsFileURL, atomically: true, encoding: .utf8)

    #expect(store.convertLegacyToAdditions(.dictation))
    #expect(store.loadLegacyDictationPrompt() == "")
    #expect(store.loadDictationAdditions() == rule)
    #expect(store.convertLegacyToAdditions(.promptMode))
    #expect(store.loadLegacyDictatePrompt() == "")
    #expect(store.loadDictatePromptAdditions() == "My own dictate prompt, not a shipped core.")
    let rows = UserContextLog.decodeLines([store.historyFileURL], as: UnifiedSystemPromptHistoryEntry.self)
    #expect(rows.contains { $0.source == PromptHistorySource.settings.rawValue })
  }

  @Test("Cases 1 and 2 decline pending proposals that still target the legacy section")
  func migrationDeclinesLegacyProposals() throws {
    let env = MCPTestEnv()
    env.systemPrompts.declineLegacyProposals = { sections in
      env.proposals.declinePending(sections: sections, reason: SystemPromptsStore.migrationProposalReason)
    }
    let file = legacyFile(sections: [.dictation: AppConstants.defaultTranscriptionSystemPrompt])
    try file.write(to: env.systemPrompts.systemPromptsFileURL, atomically: true, encoding: .utf8)
    let proposal = try env.proposals.create(
      kind: .systemPrompt, section: SystemPromptSection.dictation.rawValue,
      proposedContent: "A new rule.", rationale: "because")
    #expect(env.systemPrompts.loadLegacyDictationPrompt() == "")
    let resolved = env.proposals.status(of: proposal.id)
    #expect(resolved?.status == .declined)
    #expect(resolved?.resolutionReason == SystemPromptsStore.migrationProposalReason)

    let env3 = MCPTestEnv()
    env3.systemPrompts.declineLegacyProposals = { sections in
      env3.proposals.declinePending(sections: sections, reason: SystemPromptsStore.migrationProposalReason)
    }
    let own = "Ich schreibe Befunde für die Klinik am Park, kurz und ohne Anrede."
    try legacyFile(sections: [.promptMode: own]).write(
      to: env3.systemPrompts.systemPromptsFileURL, atomically: true, encoding: .utf8)
    let kept = try env3.proposals.create(
      kind: .systemPrompt, section: SystemPromptSection.promptMode.rawValue,
      proposedContent: "Another.", rationale: "because")
    #expect(env3.systemPrompts.loadLegacyDictatePrompt() == own)
    #expect(env3.proposals.status(of: kept.id)?.status == .pending)
  }

  @Test("Warnings a through e, and a plain context note has none")
  func warnings() {
    let legacy = SystemPromptSectionGuide.warnings(for: .dictation, text: badAdditions, legacyActive: true)
    #expect(legacy == [
      "A full custom prompt replaces the built-in instructions for this mode, so improvements to them do not reach it. Convert it: keep only context, vocabulary and style as additions.",
    ])
    let additions = SystemPromptSectionGuide.warnings(
      for: .dictationAdditions, text: badAdditions, legacyActive: false)
    #expect(additions == [
      "Starts like a whole prompt. The built-in instructions already set the role and task; keep only context, vocabulary and style.",
      "Redefines the task. Additions cannot change the task; keep only context, vocabulary and style.",
    ])
    #expect(
      SystemPromptSectionGuide.warnings(for: .dictationAdditions, text: fineAdditions, legacyActive: false).isEmpty)
    let editing = SystemPromptSectionGuide.warnings(
      for: .dictationAdditions, text: "Prefer the selected text wording.", legacyActive: false)
    #expect(editing == [
      "Describes editing selected text, which is Dictate Prompt; move it to dictate_prompt.",
    ])
    let long = String(repeating: "a", count: 2_001)
    let lengthy = SystemPromptSectionGuide.warnings(for: .promptModeAdditions, text: long, legacyActive: false)
    #expect(lengthy == [
      "Long additions water down the built-in rules; keep only the few rules the user needs.",
    ])
    #expect(!SystemPromptSectionGuide.purpose(for: .dictationAdditions).isEmpty)
    #expect(!SystemPromptSectionGuide.purpose(for: .promptMode).isEmpty)
  }

  @Test("get_configuration reports purpose, warnings and a legacy full prompt")
  func configurationFields() throws {
    let env = MCPTestEnv(level: .apply)
    let legacy = "A whole prompt the user wrote."
    env.systemPrompts.updateSection(.promptMode, content: legacy, source: .settings)
    env.systemPrompts.updateSection(.promptModeAdditions, content: fineAdditions, source: .settings)
    let config = env.tools().call(name: "get_configuration", arguments: [:], access: .read)
    let prompts = (obj(config)["system_prompts"] as? [String: Any])
    let dictate = prompts?["dictate_prompt"] as? [String: Any]
    #expect((dictate?["purpose"] as? String)?.contains("Dictate Prompt") == true)
    #expect(dictate?["legacy_full_prompt"] as? String == legacy)
    #expect(dictate?["replaces_built_in"] as? Bool == true)
    let warnings = dictate?["warnings"] as? [String]
    #expect(warnings?.isEmpty == false)
    #expect((prompts?["chat"] as? [String: Any])?["purpose"] as? String != nil)
    #expect((prompts?["chat"] as? [String: Any])?["legacy_full_prompt"] == nil)
    #expect((prompts?["dictation"] as? [String: Any])?["default_length"] as? Int == 0)
  }

  @Test("update_system_prompt accepts empty dictate_prompt content and rejects empty chat content")
  func emptyContentClearsOnlyAdditions() {
    let env = MCPTestEnv(level: .apply)
    env.systemPrompts.updateSection(.promptModeAdditions, content: "Be brief.", source: .settings)
    let tools = env.tools()
    let cleared = tools.call(
      name: "update_system_prompt",
      arguments: ["section": "dictate_prompt", "content": "", "rationale": "clear additions"],
      access: .write)
    #expect(!cleared.isError)
    #expect(cleared.text.contains("pending_review"))
    let proposal = env.proposals.pending.first { $0.section == SystemPromptSection.promptModeAdditions.rawValue }
    #expect(proposal?.proposedContent == "")

    let rejected = tools.call(
      name: "update_system_prompt",
      arguments: ["section": "chat", "content": "", "rationale": "clear"],
      access: .write)
    #expect(rejected.isError)
  }

  @Test("report_problem is accepted when warnings exist and carries the configuration block")
  func reportProblemKeepsWarningsAndConfiguration() {
    let env = MCPTestEnv(level: .apply)
    env.settings["transcription_model"] = "gemini-test"
    env.settings["dictate_prompt_model"] = "prompt-test"
    env.systemPrompts.updateSection(.dictationAdditions, content: badAdditions, source: .settings)
    let result = env.tools().call(
      name: "report_problem",
      arguments: [
        "title": "It paraphrases",
        "what_happens": "The transcript is rewritten.",
        "why_not_settings": "The built-in rules already forbid it.",
      ],
      access: .write)
    #expect(!result.isError)
    let body = env.proposals.pending.first?.proposedContent ?? ""
    #expect(body.contains("## Configuration (added by WhisperShortcut)"))
    #expect(body.contains("transcription_model: gemini-test"))
    #expect(body.contains("dictate_prompt_model: prompt-test"))
    #expect(body.contains("built-in + additions"))
    #expect(body.contains("Starts like a whole prompt"))
    #expect(body.contains(badAdditions))
    let config = body.range(of: "## Configuration (added by WhisperShortcut)")
    let version = body.range(of: "App version:")
    #expect(config != nil && version != nil && config!.lowerBound < version!.lowerBound)
  }

  // MARK: - Helpers

  private struct Migrated {
    var dir: URL
    var file: URL
    var store: SystemPromptsStore
  }

  private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("FixedPromptCoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// A pre-additions file: no additions headers, so migration still has work to do.
  private func legacyFile(sections: [SystemPromptSection: String]) -> String {
    let order: [SystemPromptSection] = [.dictation, .whisperGlossary, .promptMode, .chat, .readAloudRewrite]
    return order.map { section in
      section.fileHeader + "\n\n" + (sections[section] ?? "")
    }.joined(separator: "\n\n")
  }

  private func migrateFile(sections: [SystemPromptSection: String]) throws -> Migrated {
    let dir = try makeDir()
    let store = SystemPromptsStore(contextDirectoryURL: dir)
    let file = store.systemPromptsFileURL
    try legacyFile(sections: sections).write(to: file, atomically: true, encoding: .utf8)
    _ = store.loadDictationAdditions()
    return Migrated(dir: dir, file: file, store: store)
  }

  private func obj(_ result: MCPToolResult) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]) ?? [:]
  }
}

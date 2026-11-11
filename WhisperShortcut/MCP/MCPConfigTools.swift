import Foundation

typealias MCPToolResult = (text: String, isError: Bool)

/// Everything the configuration tools depend on, injected so tests use scratch directories and
/// fake settings. `live` wires the real stores.
struct MCPConfigEnvironment {
  var targets: MCPConfigTargets
  var proposals: MCPProposalStore
  var changeLog: MCPChangeLog
  var accessLevel: () -> MCPConfigAccessLevel
  var contextLoggingEnabled: () -> Bool
  var shareRecentInteractions: () -> Bool
  /// Interaction rows and outcome signals covering the query's window, oldest first (file order).
  /// Filtering, ordering and paging happen in `InteractionLogReader.page`, so tests hand in rows.
  var interactionLog: (_ query: InteractionLogQuery) -> (entries: [InteractionLogEntry], signals: [SignalLogEntry])
  /// Only the keys `MCPConfigTools.settingsKeys` names are ever read from it.
  var settings: () -> [String: String]
  var shortcuts: () -> [[String: Any]]
  var writingStyleEnabled: () -> Bool
  var appVersion: String
  /// The `get_settings` / `update_settings` catalog. Built once per environment; tests pass a
  /// catalog built from fake `MCPSettingsCatalog.Dependencies`.
  var settingsCatalog: [MCPSetting] = []
  /// Error-log lines for `get_recent_interactions` with `include_errors`. Tests hand in lines.
  var errorLog: (_ query: InteractionLogQuery) -> [ErrorLogLine] = { ErrorLogReader.load($0) }
  /// Rows of `system-prompts-history.jsonl`, oldest first, for `get_config_history`.
  var configHistory: () -> [UnifiedSystemPromptHistoryEntry] = { ConfigHistoryReader.load() }
  /// Features an AI app should mention when they are off or blocked by a missing permission.
  /// Defaults to everything working so tests that build an environment stay unaffected.
  var featureState: () -> MCPFeatureState = {
    MCPFeatureState(
      autoPaste: true, accessibility: true, frontWindowFallback: true, fieldTextContext: true, screenRecording: true,
      interactionsShared: true)
  }

  var applier: MCPConfigApplier { MCPConfigApplier(targets: targets, changeLog: changeLog) }

  static var live: MCPConfigEnvironment {
    let defaults = UserDefaults.standard
    return MCPConfigEnvironment(
      targets: .live, proposals: .shared, changeLog: .shared,
      accessLevel: { MCPConfigAccessLevel.current },
      contextLoggingEnabled: { defaults.bool(forKey: UserDefaultsKeys.contextLoggingEnabled) },
      shareRecentInteractions: { defaults.bool(forKey: UserDefaultsKeys.mcpShareRecentInteractions) },
      interactionLog: { query in InteractionLogReader.load(query) },
      settings: {
        var out: [String: String] = [:]
        for (key, defaultsKey) in MCPConfigTools.settingsKeys {
          if let value = defaults.string(forKey: defaultsKey) { out[key] = value }
        }
        return out
      },
      shortcuts: {
        ShortcutConfigManager.shared.loadConfiguration().assistantFacingRows.map { row in
          [
            "action": row.action,
            "shortcut": row.definition.displayStringWithSeparator,
            "enabled": row.definition.isEnabled,
          ]
        }
      },
      writingStyleEnabled: { defaults.bool(forKey: UserDefaultsKeys.writingStyleEnabled) },
      appVersion: AppConstants.appVersion,
      settingsCatalog: MCPSettingsCatalog.build(.live),
      featureState: {
        MCPFeatureState(
          autoPaste: AutoPasteDefault.currentValue,
          accessibility: AccessibilityPermissionManager.hasAccessibilityPermission(),
          frontWindowFallback: defaults.object(forKey: UserDefaultsKeys.screenshotInPromptMode) != nil
            ? defaults.bool(forKey: UserDefaultsKeys.screenshotInPromptMode)
            : SettingsDefaults.screenshotInPromptMode,
          fieldTextContext: DictationPreferences.promptSendsFocusedFieldTextEnabled,
          // Read-only, same check as MCPSettingsCatalog.Dependencies. Never call SCShareableContent.
          screenRecording: PermissionStatusChecker.status(for: .screenRecording) == .granted,
          interactionsShared: defaults.bool(forKey: UserDefaultsKeys.contextLoggingEnabled)
            && defaults.bool(forKey: UserDefaultsKeys.mcpShareRecentInteractions))
      })
  }
}

/// Configuration tools, resources and prompts behind the MCP server. Read tools work with either
/// token; write tools need the write token and an access level above "read".
struct MCPConfigTools {
  let env: MCPConfigEnvironment

  static let maxRationaleCharacters = 300
  static let maxFieldCharacters = 1_500
  static let maxGlossaryTermsPerCall = 50

  /// Model-facing section names, in display order.
  static let sections: [(name: String, section: SystemPromptSection)] = [
    ("dictation", .dictationAdditions), ("whisper_glossary", .whisperGlossary),
    ("dictate_prompt", .promptModeAdditions), ("chat", .chat), ("read_aloud_rewrite", .readAloudRewrite),
  ]
  /// Always a proposal, at every access level. A meeting or an email an AI app reads could contain
  /// text meant to change these instructions, or to remove glossary lines.
  static let alwaysProposalSections: Set<String> = [
    "dictation", "chat", "whisper_glossary", "dictate_prompt", "read_aloud_rewrite",
  ]

  /// The only settings `get_configuration` reads: model names, nothing else.
  static let settingsKeys: [String: String] = [
    "transcription_model": UserDefaultsKeys.selectedTranscriptionModel,
    "dictate_prompt_model": UserDefaultsKeys.selectedPromptModel,
    "chat_model": UserDefaultsKeys.selectedChatModel,
    "meeting_transcription_model": UserDefaultsKeys.selectedTranscriptionModelForMeetings,
    "meeting_summary_model": UserDefaultsKeys.selectedMeetingSummaryModel,
  ]

  static let readToolNames: Set<String> = [
    "get_configuration", "get_recent_interactions", "get_config_history", "get_settings",
    "get_proposal_status",
  ]
  static let writeToolNames: Set<String> = [
    "add_glossary_terms", "update_system_prompt", "update_writing_style_profile", "save_command",
    "delete_command", "report_problem", "update_settings",
  ]

  func handles(_ name: String) -> Bool {
    Self.readToolNames.contains(name) || Self.writeToolNames.contains(name)
  }

  // MARK: - Definitions

  private static let rationaleProperty: [String: Any] = [
    "type": "string",
    "description": "One line (max 300 characters) on why this change helps the user. Shown to the user.",
  ]
  private static let sectionNames = sections.map(\.name)

  static let readToolDefinitions: [[String: Any]] = [
    [
      "name": "get_configuration",
      "description":
        "Overview of how WhisperShortcut is configured: version, models, shortcuts, which system prompt sections are customized, writing style, commands, quick prompts with how often each was used in 30 days, the access level AI apps have, and the recipe for tuning WhisperShortcut to the user. Call this first when the user wants WhisperShortcut improved.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "include": [
            "type": "array", "items": ["type": "string", "enum": ["system_prompts", "writing_style", "commands"]],
            "description": "Also return these full texts inline (for clients without MCP resources).",
          ]
        ],
      ] as [String: Any],
      "annotations": ["title": "Get Configuration", "readOnlyHint": true, "openWorldHint": false],
    ],
    [
      "name": "get_recent_interactions",
      "description": InteractionLogTool.description(subject: "The user's recent dictations, Dictate Prompt turns and chats"),
      "inputSchema": InteractionLogTool.parameters,
      "annotations": ["title": "Get Recent Interactions", "readOnlyHint": true, "openWorldHint": false],
    ],
    [
      "name": "get_config_history",
      "description": ConfigHistoryTool.description,
      "inputSchema": ConfigHistoryTool.parameters,
      "annotations": ["title": "Get Config History", "readOnlyHint": true, "openWorldHint": false],
    ],
    [
      "name": "get_settings",
      "description":
        "Lists WhisperShortcut settings an AI app can read and, within the user's access level, change with update_settings: current value, type, and for enums the same options the user sees in the picker. Optionally filter by category (e.g. \"models\", \"shortcuts\").",
      "inputSchema": [
        "type": "object",
        "properties": ["category": ["type": "string", "description": "Only settings in this category."]],
      ] as [String: Any],
      "annotations": ["title": "Get Settings", "readOnlyHint": true, "openWorldHint": false],
    ],
    [
      "name": "get_proposal_status",
      "description": "Reports whether a proposal made earlier is pending, accepted or declined.",
      "inputSchema": [
        "type": "object", "properties": ["id": ["type": "string"]], "required": ["id"],
      ] as [String: Any],
      "annotations": ["title": "Get Proposal Status", "readOnlyHint": true, "openWorldHint": false],
    ],
  ]

  private static func write(
    _ name: String, _ title: String, _ description: String, _ properties: [String: Any], required: [String],
    annotations: [String: Any]
  ) -> [String: Any] {
    var props = properties
    props["rationale"] = rationaleProperty
    var ann = annotations
    ann["title"] = title
    return [
      "name": name, "description": description,
      "inputSchema": ["type": "object", "properties": props, "required": required + ["rationale"]] as [String: Any],
      "_meta": ["anthropic/requiresUserInteraction": true],
      "annotations": ann,
    ]
  }

  // Built apart from the definitions literal, which a concatenation inside would make much
  // harder for the type checker.
  private static let addGlossaryTermsDescription: String =
    "Adds names and domain terms to the Whisper glossary. Only ever adds, never removes. Each term is a bare term or: Term (not \"wrong\", \"wrong2\") with the misheard forms. Max 60 characters and 5 words per term; the glossary has a budget of 1,200 characters. Applied at once, unless the user set AI app access to \"Suggest changes for me to approve\" in WhisperShortcut Settings, in which case it creates a proposal the user reviews there."
    + " " + InteractionLogTool.tuningRules
  private static let updateSystemPromptDescription: String =
    "Replaces one system prompt section with the full new text (at most about 2,000 characters beyond the built-in default). For dictation and dictate_prompt the section holds only additional instructions (context, vocabulary, style) on top of a fixed built-in prompt that cannot be changed; never restate the task or write a whole prompt there, and empty content clears those two. dictation, chat and whisper_glossary always wait for the user to accept them in WhisperShortcut; dictate_prompt and read_aloud_rewrite follow the user's access level. Read the current text first and change as little as possible: keep every existing rule and glossary line, add or edit the one that fixes what the logs show."
    + " " + InteractionLogTool.tuningRules

  static let writeToolDefinitions: [[String: Any]] = [
    write(
      "add_glossary_terms", "Add Glossary Terms",
      addGlossaryTermsDescription,
      ["terms": ["type": "array", "items": ["type": "string"], "description": "Terms to add."]],
      required: ["terms"],
      annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]),
    write(
      "update_system_prompt", "Update System Prompt",
      updateSystemPromptDescription,
      [
        "section": ["type": "string", "enum": sectionNames],
        "content": [
          "type": "string",
          "description":
            "The complete new text of the section. For dictation and dictate_prompt: only additional instructions (context, vocabulary, style) on top of the fixed built-in prompt; never restate the task or write a whole prompt. Empty content clears those two.",
        ],
      ], required: ["section", "content"],
      annotations: ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": false]),
    write(
      "update_writing_style_profile", "Update Writing Style Profile",
      "Replaces the writing style profile with the full new text (max \(WritingStyleStore.maxChars) characters). Read it first.",
      ["content": ["type": "string", "description": "The complete new profile."]], required: ["content"],
      annotations: ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": false]),
    write(
      "save_command", "Save Command",
      "Creates or overwrites a chat command (a saved instruction the user runs as /name).",
      [
        "name": ["type": "string", "description": "Lowercase letters, digits and dashes, max 40."],
        "text": ["type": "string", "description": "The instruction the command runs."],
        "scope": ["type": "string", "enum": ["meeting", "chat", "both"]],
        "label": ["type": "string", "description": "Optional button text."],
        "description": ["type": "string", "description": "Optional one-line description."],
      ], required: ["name", "text", "scope"],
      annotations: ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": false]),
    write(
      "delete_command", "Delete Command", "Moves a chat command to the Trash.",
      ["name": ["type": "string"]], required: ["name"],
      annotations: ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": false]),
    [
      "name": "report_problem",
      "description":
        "Reports a problem in WhisperShortcut itself that no setting can fix: the instructions already forbid the behavior, or the mistake is in what the app does (pasting, history, timing, the wrong model). Before calling, read get_configuration; if a section's warnings explain the problem, fix the configuration instead. Saves a report the user reviews in WhisperShortcut; nothing is sent unless they open it as a GitHub issue themselves. Remove names, patient, customer and other private data from the examples.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "title": ["type": "string", "description": "Short summary, max 120 characters."],
          "what_happens": ["type": "string", "description": "What the app does wrong, max 1,000 characters."],
          "examples": [
            "type": "array", "items": ["type": "string"],
            "description": "Up to 3 short redacted excerpts, each max 500 characters.",
          ],
          "suspected_cause": ["type": "string", "description": "Optional. Where the bug might be, max 1,000 characters."],
          "why_not_settings": [
            "type": "string",
            "description": "Why a setting or prompt change cannot fix it, max 500 characters.",
          ],
        ],
        "required": ["title", "what_happens", "why_not_settings"],
      ] as [String: Any],
      "_meta": ["anthropic/requiresUserInteraction": true],
      "annotations": ["title": "Report Problem", "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false],
    ],
    write(
      "update_settings", "Update Settings",
      "Changes one or more settings from get_settings. All changes are validated together against the state the whole call would leave (not just today's values) first; if any one is invalid, nothing is written. Settings that always wait for approval (e.g. Launch at login) turn the whole call into one proposal, even at access level \"apply\". A \"shortcut\"-type setting's value is {\"key\": <name, e.g. \"a\"/\"1\"/\"f5\"/\"space\"/\"return\">, \"modifiers\": [subset of \"command\",\"option\",\"control\",\"shift\"]}, or null to disable it.",
      [
        "changes": [
          "type": "object",
          "description": "Setting id (from get_settings) → new value. Max 20 per call.",
        ]
      ], required: ["changes"],
      annotations: ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": false]),
  ]

  /// Tool definitions visible to a client: gated only by token type, not by the user's configured
  /// access level — clients fetch tools/list once per session and cache it, so the list a write
  /// token sees must not change as the user flips Settings between read/propose/apply. Calling a
  /// write tool at access level "read" is still rejected in `call()`, which runs per request.
  func toolDefinitions(access: MCPAccess) -> [[String: Any]] {
    access == .write ? Self.readToolDefinitions + Self.writeToolDefinitions : Self.readToolDefinitions
  }

  // MARK: - Dispatch

  func call(name: String, arguments: [String: Any], access: MCPAccess) -> MCPToolResult {
    if Self.writeToolNames.contains(name) {
      guard access == .write else {
        return reject(name, "read token", "This connection can only read. Use the write token from WhisperShortcut Settings.")
      }
      guard env.accessLevel() != .read else {
        return reject(name, "access level read", "Changing settings from AI apps is off in WhisperShortcut Settings.")
      }
    }
    switch name {
    case "get_configuration": return getConfiguration(arguments)
    case "get_recent_interactions": return getRecentInteractions(arguments)
    case "get_config_history": return getConfigHistory(arguments)
    case "add_glossary_terms": return addGlossaryTerms(arguments)
    case "update_system_prompt": return updateSystemPrompt(arguments)
    case "update_writing_style_profile": return updateWritingStyle(arguments)
    case "save_command": return saveCommand(arguments)
    case "delete_command": return deleteCommand(arguments)
    case "report_problem": return reportProblem(arguments)
    case "get_proposal_status": return getProposalStatus(arguments)
    case "get_settings": return getSettings(arguments)
    case "update_settings": return updateSettings(arguments)
    default: return ("Unknown tool: \(name)", true)
    }
  }

  // MARK: - Helpers

  func log(_ tool: String, _ outcome: String, _ reason: String? = nil, len: Int = 0) {
    DebugLogger.log("MCP-CONFIG: \(tool) \(outcome)\(reason.map { " (\($0))" } ?? "") len=\(len)")
  }

  func reject(_ tool: String, _ reason: String, _ message: String) -> MCPToolResult {
    log(tool, "rejected", reason)
    return (message, true)
  }

  func json(_ object: Any) -> String {
    let data = try? JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }

  func rationale(_ args: [String: Any], tool: String) -> (value: String?, error: MCPToolResult?) {
    guard let raw = (args["rationale"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return (nil, reject(tool, "missing rationale", "rationale is required: one line on why this helps the user."))
    }
    guard raw.count <= Self.maxRationaleCharacters else {
      return (nil, reject(tool, "rationale too long", "rationale is \(raw.count) characters; the limit is \(Self.maxRationaleCharacters)."))
    }
    return (raw, nil)
  }

  func pendingResult(_ id: String) -> MCPToolResult {
    (json(["status": "pending_review", "id": id, "message": "Waiting for the user to accept it in WhisperShortcut."]), false)
  }

  private func appliedResult(_ outcome: Result<String, Error>, tool: String, len: Int) -> MCPToolResult {
    switch outcome {
    case .success(let changeID):
      log(tool, "applied", len: len)
      return (json(["status": "applied", "change_id": changeID]), false)
    case .failure(let error):
      return reject(tool, "write failed", error.localizedDescription)
    }
  }

  // MARK: - get_configuration

  private func sectionInfo() -> [String: Any] {
    var info: [String: Any] = [:]
    for (name, section) in Self.sections {
      let body = env.targets.systemPrompts.loadSection(section)
      let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      // The default's length lets an AI app see at a glance which customized section grew far
      // past what the app ships, the usual sign of rules piling up.
      let legacy = env.targets.systemPrompts.legacyFullPrompt(for: section)
      var row: [String: Any] = [
        "customized": SystemPromptsStore.isCustomized(trimmed, for: section), "length": trimmed.count,
        "default_length": MCPProposalWindows.defaultText(for: section).count,
        "purpose": SystemPromptSectionGuide.purpose(for: section),
        "warnings": SystemPromptSectionGuide.warnings(for: section, text: trimmed, legacyActive: legacy != nil),
      ]
      if let legacy {
        row["legacy_full_prompt"] = legacy
        row["replaces_built_in"] = true
      }
      info[name] = row
    }
    return info
  }

  private func loadCommands() -> [UserCommand] {
    MCPMain.run {
      env.targets.commands.reload()
      return env.targets.commands.commands
    }
  }

  private func getConfiguration(_ args: [String: Any]) -> MCPToolResult {
    let include = Set((args["include"] as? [String]) ?? [])
    let settings = env.settings()
    var models: [String: String] = [:]
    for key in Self.settingsKeys.keys { if let v = settings[key] { models[key] = v } }
    let profile = env.targets.writingStyle.loadProfile()
    let commands = loadCommands()
    var out: [String: Any] = [
      "app_version": env.appVersion,
      "models": models,
      "settings": "call get_settings",
      "shortcuts": env.shortcuts(),
      "system_prompts": sectionInfo(),
      "writing_style": ["enabled": env.writingStyleEnabled(), "profile_length": profile.count],
      "commands": commands.map { ["name": $0.name, "scope": $0.scope.rawValue] },
      "ai_app_access": [
        "level": env.accessLevel().rawValue,
        "recent_interactions_shared": env.contextLoggingEnabled() && env.shareRecentInteractions(),
        "pending_proposals": MCPMain.run { env.proposals.pending.count },
      ] as [String: Any],
      "tune_recipe": MCPTuneRecipe.text(focus: nil),
      "not_yet_enabled": MCPFeatureHints.build(env.featureState()),
      "quick_prompts": (env.contextLoggingEnabled() && env.shareRecentInteractions())
        ? QuickActionStore.shared.usageSummary() as Any
        : "Turn on Save usage data and Let AI apps read my recent dictations to see how often each quick prompt is used." as Any,
    ]
    if include.contains("system_prompts") {
      var texts: [String: String] = [:]
      for (name, section) in Self.sections { texts[name] = env.targets.systemPrompts.loadSection(section) ?? "" }
      out["system_prompt_texts"] = texts
    }
    if include.contains("writing_style") { out["writing_style_profile"] = profile }
    if include.contains("commands") {
      out["command_texts"] = commands.map { ["name": $0.name, "scope": $0.scope.rawValue, "text": $0.body] }
    }
    log("get_configuration", "applied", "read", len: 0)
    return (json(out), false)
  }

  // MARK: - get_recent_interactions

  private func getRecentInteractions(_ args: [String: Any]) -> MCPToolResult {
    let logging = env.contextLoggingEnabled()
    let sharing = env.shareRecentInteractions()
    guard logging && sharing else {
      var missing: [String] = []
      if !logging { missing.append("\"Save usage data\"") }
      if !sharing { missing.append("\"AI apps may read my recent dictations\"") }
      return reject(
        "get_recent_interactions", "toggle off",
        "Recent dictations are not shared. Turn on \(missing.joined(separator: " and ")) in WhisperShortcut Settings.")
    }
    let parsed = InteractionLogQuery.parse(args)
    guard let query = parsed.query else {
      return reject("get_recent_interactions", "bad arguments", parsed.error ?? "Invalid arguments.")
    }
    let rows = env.interactionLog(query)
    let page = InteractionLogReader.page(entries: rows.entries, signals: rows.signals, query: query)
    let errors = query.includeErrors ? env.errorLog(query) : []
    let out = InteractionLogReader.result(
      page, query: query, fieldCap: Self.maxFieldCharacters, budget: MCPMeetingTools.maxResultCharacters,
      errors: errors)
    let text = json(out)
    log("get_recent_interactions", "applied", "read", len: text.count)
    return (text, false)
  }

  // MARK: - get_config_history

  /// Read-only and not behind the usage-data toggles: it is the history of the app's own
  /// configuration (the same texts `get_configuration` can return), not what the user dictated.
  private func getConfigHistory(_ args: [String: Any]) -> MCPToolResult {
    let parsed = ConfigHistoryQuery.parse(args)
    guard let query = parsed.query else {
      return reject("get_config_history", "bad arguments", parsed.error ?? "Invalid arguments.")
    }
    let text = json(ConfigHistoryReader.result(rows: env.configHistory(), query: query))
    log("get_config_history", "applied", "read", len: text.count)
    return (text, false)
  }

  // MARK: - add_glossary_terms

  /// `Term` or `Term (not "wrong", "wrong2")` → the glossary line, or an error message.
  static func glossaryLine(for raw: String) -> (line: String?, error: String?) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var termPart = trimmed
    var wrongParts: [String] = []
    if let r = trimmed.range(of: #"\s*\((?:not|nicht)\s+(.+)\)\s*$"#, options: [.regularExpression, .caseInsensitive]) {
      termPart = String(trimmed[..<r.lowerBound])
      var inner = String(trimmed[r])
      inner = inner.trimmingCharacters(in: .whitespaces)
      inner = String(inner.dropFirst().dropLast())  // parentheses
      if let k = inner.range(of: #"^(?:not|nicht)\s+"#, options: [.regularExpression, .caseInsensitive]) {
        inner.removeSubrange(k)
      }
      wrongParts = inner.components(separatedBy: ",")
    }
    func clean(_ part: String) -> String {
      SystemPromptsStore.normaliseTerm(
        part.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”„'‘’ ")))
    }
    func valid(_ part: String) -> Bool {
      !part.isEmpty && part.count <= SystemPromptsStore.maxTermCharacters
        && part.split(separator: " ").count <= SystemPromptsStore.maxTermWords
        && !part.contains(",") && !part.contains("\n")
    }
    let term = clean(termPart)
    guard valid(term) else {
      return (nil, "\"\(String(trimmed.prefix(40)))\" is not a term: use at most \(SystemPromptsStore.maxTermCharacters) characters and \(SystemPromptsStore.maxTermWords) words, no commas or line breaks.")
    }
    let wrongs = wrongParts.map(clean).filter { !$0.isEmpty }
    guard wrongs.allSatisfy(valid) else {
      return (nil, "A misheard form of \"\(term)\" is too long (max \(SystemPromptsStore.maxTermCharacters) characters, \(SystemPromptsStore.maxTermWords) words).")
    }
    return (wrongs.isEmpty ? term : GlossaryLearning.annotatedLine(term: term, rejected: wrongs), nil)
  }

  private func addGlossaryTerms(_ args: [String: Any]) -> MCPToolResult {
    let tool = "add_glossary_terms"
    let r = rationale(args, tool: tool)
    if let e = r.error { return e }
    guard let raw = args["terms"] as? [String], !raw.isEmpty else {
      return reject(tool, "no terms", "terms must be a non-empty list of strings.")
    }
    guard raw.count <= Self.maxGlossaryTermsPerCall else {
      return reject(tool, "too many terms", "Send at most \(Self.maxGlossaryTermsPerCall) terms per call.")
    }
    var lines: [String] = []
    for item in raw {
      let parsed = Self.glossaryLine(for: item)
      if let message = parsed.error { return reject(tool, "invalid term", message) }
      lines.append(parsed.line!)
    }
    return MCPMain.run {
      let current = env.targets.systemPrompts.loadWhisperGlossary()
      let merged = GlossaryLearning.mergeAdditively(current: current, suggestion: lines.joined(separator: "\n"))
      let base = current.trimmingCharacters(in: .whitespacesAndNewlines)
      if merged == base {
        log(tool, "applied", "no-op", len: current.count)
        return (json(["status": "no_change", "message": "Nothing new to add: the terms are already in the glossary (or are longer than three words without a (not ...) note)."]), false)
      }
      guard merged.count <= SystemPromptsStore.glossaryCharBudget else {
        let left = max(0, SystemPromptsStore.glossaryCharBudget - current.count)
        return reject(
          tool, "over budget",
          "The glossary budget is \(SystemPromptsStore.glossaryCharBudget) characters and only \(left) are left. Nothing was written. Pick the terms that occur most in the user's recent dictations.")
      }
      if env.accessLevel() == .propose {
        do {
          let p = try env.proposals.create(
            kind: .systemPrompt, section: SystemPromptSection.whisperGlossary.rawValue,
            previousContent: current, proposedContent: merged, rationale: r.value!)
          log(tool, "proposed", len: merged.count)
          return pendingResult(p.id)
        } catch {
          return reject(tool, "too many pending", error.localizedDescription)
        }
      }
      let known = Set(GlossaryLearning.entries(in: current).map { GlossaryLearning.fold($0.term) })
      let added = GlossaryLearning.entries(in: merged).map(\.term).filter { !known.contains(GlossaryLearning.fold($0)) }
      switch env.applier.applyGlossary(merged: merged, rationale: r.value!) {
      case .success(let id):
        log(tool, "applied", len: merged.count)
        return (json(["status": "applied", "change_id": id, "added": added, "glossary_length": merged.count]), false)
      case .failure(let error):
        return reject(tool, "write failed", error.localizedDescription)
      }
    }
  }

  // MARK: - update_system_prompt

  private func updateSystemPrompt(_ args: [String: Any]) -> MCPToolResult {
    let tool = "update_system_prompt"
    let r = rationale(args, tool: tool)
    if let e = r.error { return e }
    guard let name = args["section"] as? String, let section = Self.sections.first(where: { $0.name == name })?.section else {
      return reject(tool, "unknown section", "section must be one of: \(Self.sectionNames.joined(separator: ", ")).")
    }
    guard let rawContent = args["content"] as? String else {
      return reject(tool, "empty content", "content must be the full new section text.")
    }
    let trimmedContent = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
    // Dictation and Dictate Prompt store only additions, so empty content clears them.
    // Every other section still rejects an empty replacement.
    let additionsOnly = section == .dictationAdditions || section == .promptModeAdditions
    if trimmedContent.isEmpty && !additionsOnly {
      return reject(tool, "empty content", "content must be the full new section text.")
    }
    let content = additionsOnly && trimmedContent.isEmpty ? "" : rawContent
    let sectionLimit = ChatToolRegistry.instructionsSectionLimit(for: section)
    guard content.count <= sectionLimit else {
      return reject(tool, "too long", "content is \(content.count) characters; the limit is \(sectionLimit). Shorten it.")
    }
    let proposalOnly = Self.alwaysProposalSections.contains(name) || env.accessLevel() == .propose
    return MCPMain.run {
      let previous = env.targets.systemPrompts.loadSection(section)
      if MCPConfigTargets.normalized(previous) == MCPConfigTargets.normalized(content) {
        log(tool, "applied", "no-op", len: content.count)
        return systemPromptResult(
          ["status": "no_change", "message": "The section already has this text."],
          section: section, content: content)
      }
      if proposalOnly {
        do {
          let p = try env.proposals.create(
            kind: .systemPrompt, section: section.rawValue, previousContent: previous,
            proposedContent: content, rationale: r.value!)
          log(tool, "proposed", name, len: content.count)
          return systemPromptResult(
            ["status": "pending_review", "id": p.id, "message": "Waiting for the user to accept it in WhisperShortcut."],
            section: section, content: content)
        } catch {
          return reject(tool, "too many pending", error.localizedDescription)
        }
      }
      switch env.applier.applySystemPrompt(section: section, content: content, rationale: r.value!, viaProposal: false) {
      case .success(let changeID):
        log(tool, "applied", len: content.count)
        return systemPromptResult(["status": "applied", "change_id": changeID], section: section, content: content)
      case .failure(let error):
        return reject(tool, "write failed", error.localizedDescription)
      }
    }
  }

  // MARK: - update_writing_style_profile

  private func updateWritingStyle(_ args: [String: Any]) -> MCPToolResult {
    let tool = "update_writing_style_profile"
    let r = rationale(args, tool: tool)
    if let e = r.error { return e }
    guard let content = args["content"] as? String,
      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return reject(tool, "empty content", "content must be the full new profile.") }
    guard content.count <= WritingStyleStore.maxChars else {
      return reject(tool, "too long", "content is \(content.count) characters; the limit is \(WritingStyleStore.maxChars). Shorten it.")
    }
    return MCPMain.run {
      let previous = env.targets.current(kind: .writingStyle, target: "profile")
      if previous == content {
        return (json(["status": "no_change", "message": "The profile already has this text."]), false)
      }
      if env.accessLevel() == .propose {
        do {
          let p = try env.proposals.create(
            kind: .writingStyle, previousContent: previous, proposedContent: content, rationale: r.value!)
          log(tool, "proposed", len: content.count)
          return pendingResult(p.id)
        } catch {
          return reject(tool, "too many pending", error.localizedDescription)
        }
      }
      return appliedResult(
        env.applier.applyWritingStyle(content: content, rationale: r.value!, viaProposal: false),
        tool: tool, len: content.count)
    }
  }

  // MARK: - commands

  private func commandName(_ args: [String: Any], tool: String) -> (name: String?, error: MCPToolResult?) {
    guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces), UserCommandParser.isValidName(name) else {
      return (nil, reject(tool, "invalid name", "name must use lowercase letters, digits and dashes (max 40 characters)."))
    }
    return (name, nil)
  }

  private func saveCommand(_ args: [String: Any]) -> MCPToolResult {
    let tool = "save_command"
    let r = rationale(args, tool: tool)
    if let e = r.error { return e }
    let n = commandName(args, tool: tool)
    if let e = n.error { return e }
    let name = n.name!
    guard !env.targets.commands.reservedNameSet().contains(name) else {
      return reject(tool, "reserved name", "/\(name) is a built-in command. Pick another name.")
    }
    guard let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return reject(tool, "empty text", "text must be the command's instruction.")
    }
    guard let scope = (args["scope"] as? String).flatMap(UserCommandScope.init(rawValue:)) else {
      return reject(tool, "invalid scope", "scope must be meeting, chat or both.")
    }
    let label = args["label"] as? String
    let description = args["description"] as? String
    let size = UserCommandStore.render(name: name, text: text, scope: scope, label: label, description: description).utf8.count
    guard size <= UserCommandParser.maxFileBytes else {
      return reject(tool, "too large", "The command is larger than 32 KB.")
    }
    return MCPMain.run {
      if env.accessLevel() == .propose {
        let previous = loadCommands().first { $0.name == name }?.body
        do {
          let p = try env.proposals.create(
            kind: .saveCommand, commandName: name, commandScope: scope.rawValue, commandLabel: label,
            commandDescription: description, previousContent: previous, proposedContent: text,
            rationale: r.value!)
          log(tool, "proposed", len: text.count)
          return pendingResult(p.id)
        } catch {
          return reject(tool, "too many pending", error.localizedDescription)
        }
      }
      return appliedResult(
        env.applier.applySaveCommand(
          name: name, text: text, scope: scope, label: label, description: description,
          rationale: r.value!, viaProposal: false),
        tool: tool, len: text.count)
    }
  }

  private func deleteCommand(_ args: [String: Any]) -> MCPToolResult {
    let tool = "delete_command"
    let r = rationale(args, tool: tool)
    if let e = r.error { return e }
    let n = commandName(args, tool: tool)
    if let e = n.error { return e }
    let name = n.name!
    return MCPMain.run {
      guard env.targets.current(kind: .deleteCommand, target: name) != nil else {
        return reject(tool, "not found", "No command named \(name).")
      }
      if env.accessLevel() == .propose {
        let previous = loadCommands().first { $0.name == name }?.body
        do {
          let p = try env.proposals.create(
            kind: .deleteCommand, commandName: name, previousContent: previous, proposedContent: nil,
            rationale: r.value!)
          log(tool, "proposed")
          return pendingResult(p.id)
        } catch {
          return reject(tool, "too many pending", error.localizedDescription)
        }
      }
      return appliedResult(
        env.applier.applyDeleteCommand(name: name, rationale: r.value!, viaProposal: false),
        tool: tool, len: 0)
    }
  }

  // MARK: - report_problem

  private func boundedText(
    _ args: [String: Any], key: String, limit: Int, required: Bool
  ) -> (value: String?, error: MCPToolResult?) {
    let raw = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if raw.isEmpty {
      if required {
        return (nil, reject("report_problem", "missing \(key)", "\(key) is required."))
      }
      return (nil, nil)
    }
    guard raw.count <= limit else {
      return (nil, reject(
        "report_problem", "\(key) too long",
        "\(key) is \(raw.count) characters; the limit is \(limit)."))
    }
    return (raw, nil)
  }

  private func problemReportBody(
    whatHappens: String, examples: [String], suspectedCause: String?, whyNotSettings: String
  ) -> String {
    var parts = ["## What happens\n\(whatHappens)"]
    if !examples.isEmpty {
      parts.append("## Examples\n" + examples.map { "- \($0)" }.joined(separator: "\n"))
    }
    if let suspectedCause, !suspectedCause.isEmpty {
      parts.append("## Suspected cause\n\(suspectedCause)")
    }
    parts.append("## Why settings can't fix it\n\(whyNotSettings)")
    parts.append(configurationAppendix())
    parts.append(
      "---\nReported by an AI app via WhisperShortcut's MCP server.\n\(FeedbackLinks.environmentBlock)")
    return parts.joined(separator: "\n\n")
  }

  /// App-generated snapshot appended to every problem report. Warnings are included, never used
  /// to reject the report. Custom text is the legacy full prompt when one is active, otherwise
  /// the additions, and is cut at 1,500 characters.
  private func configurationAppendix() -> String {
    let settings = env.settings()
    var lines = ["## Configuration (added by WhisperShortcut)"]
    lines.append("transcription_model: \(settings["transcription_model"] ?? "")")
    lines.append("dictate_prompt_model: \(settings["dictate_prompt_model"] ?? "")")
    let modes: [(String, SystemPromptSection)] = [
      ("dictation", .dictationAdditions),
      ("dictate_prompt", .promptModeAdditions),
    ]
    for (name, section) in modes {
      let additions = (env.targets.systemPrompts.loadSection(section) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let legacy = env.targets.systemPrompts.legacyFullPrompt(for: section)
      let mode: String
      let custom: String?
      if let legacy {
        mode = "legacy full prompt (\(legacy.count) chars, replaces built-in)"
        custom = legacy
      } else if !additions.isEmpty {
        mode = "built-in + additions (\(additions.count) chars)"
        custom = additions
      } else {
        mode = "built-in"
        custom = nil
      }
      lines.append("\(name): \(mode)")
      let warnings = SystemPromptSectionGuide.warnings(
        for: section, text: additions, legacyActive: legacy != nil)
      if !warnings.isEmpty {
        lines.append("Warnings:")
        lines.append(contentsOf: warnings.map { "- \($0)" })
      }
      if let custom {
        lines.append("```")
        lines.append(String(custom.prefix(1_500)))
        lines.append("```")
      }
    }
    return lines.joined(separator: "\n")
  }

  /// Adds the legacy-prompt note and the warnings of `content` to a system-prompt tool result.
  private func systemPromptResult(
    _ base: [String: Any], section: SystemPromptSection, content: String
  ) -> MCPToolResult {
    var payload = base
    if env.targets.systemPrompts.legacyFullPrompt(for: section) != nil {
      let note =
        "A legacy full prompt replaces the built-in instructions for this mode; these additions take effect once the user converts it in Settings."
      if let existing = payload["message"] as? String, !existing.isEmpty {
        payload["message"] = existing + " " + note
      } else {
        payload["message"] = note
      }
    }
    let warnings = SystemPromptSectionGuide.warnings(for: section, text: content, legacyActive: false)
    if !warnings.isEmpty { payload["warnings"] = warnings }
    return (json(payload), false)
  }

  /// Always a proposal, at every access level above read: the user decides whether to open the issue.
  private func reportProblem(_ args: [String: Any]) -> MCPToolResult {
    let title = boundedText(args, key: "title", limit: 120, required: true)
    if let e = title.error { return e }
    let what = boundedText(args, key: "what_happens", limit: 1_000, required: true)
    if let e = what.error { return e }
    let why = boundedText(args, key: "why_not_settings", limit: 500, required: true)
    if let e = why.error { return e }
    let cause = boundedText(args, key: "suspected_cause", limit: 1_000, required: false)
    if let e = cause.error { return e }

    var examples: [String] = []
    if args["examples"] != nil {
      guard let list = args["examples"] as? [String] else {
        return reject("report_problem", "examples not strings", "examples must be a list of strings.")
      }
      guard list.count <= 3 else {
        return reject(
          "report_problem", "too many examples",
          "examples has \(list.count) items; the limit is 3.")
      }
      for item in list {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 500 else {
          return reject(
            "report_problem", "example too long",
            "An example is \(trimmed.count) characters; the limit is 500.")
        }
        if !trimmed.isEmpty { examples.append(trimmed) }
      }
    }

    let body = problemReportBody(
      whatHappens: what.value!, examples: examples, suspectedCause: cause.value, whyNotSettings: why.value!)
    return MCPMain.run {
      do {
        let proposal = try env.proposals.create(
          kind: .problemReport, title: title.value, previousContent: nil,
          proposedContent: body, rationale: why.value!)
        log("report_problem", "proposed", len: body.count)
        return (
          "Saved as a problem report in WhisperShortcut (id \(proposal.id)). The user decides whether to send it; nothing leaves the Mac unless they open it as a GitHub issue.",
          false)
      } catch {
        return reject("report_problem", "too many pending", error.localizedDescription)
      }
    }
  }

  private func getProposalStatus(_ args: [String: Any]) -> MCPToolResult {
    guard let id = args["id"] as? String, let p = env.proposals.status(of: id) else {
      return ("No proposal with that id.", true)
    }
    return (json(["id": p.id, "status": p.status.rawValue, "edited": p.edited]), false)
  }

  // MARK: - Resources

  static let resourcePrefix = "whisper-shortcut://"

  func resourceList() -> [[String: Any]] {
    var list: [[String: Any]] = Self.sections.map { s in
      [
        "uri": "\(Self.resourcePrefix)system-prompt/\(s.name)", "name": "System prompt: \(s.name)",
        "description": "Current text of the \(s.name) system prompt section. \(SystemPromptSectionGuide.purpose(for: s.section))",
        "mimeType": "text/markdown",
      ]
    }
    list.append([
      "uri": "\(Self.resourcePrefix)writing-style/profile", "name": "Writing style profile",
      "description": "The user's writing style profile.", "mimeType": "text/markdown",
    ])
    for c in loadCommands() {
      list.append([
        "uri": "\(Self.resourcePrefix)commands/\(c.name)", "name": "Command /\(c.name)",
        "description": c.description, "mimeType": "text/markdown",
      ])
    }
    return list
  }

  /// nil = unknown resource.
  func resourceRead(uri: String) -> String? {
    guard uri.hasPrefix(Self.resourcePrefix) else { return nil }
    let path = String(uri.dropFirst(Self.resourcePrefix.count))
    if path.hasPrefix("system-prompt/") {
      let name = String(path.dropFirst("system-prompt/".count))
      guard let section = Self.sections.first(where: { $0.name == name })?.section else { return nil }
      return env.targets.systemPrompts.loadSection(section) ?? ""
    }
    if path == "writing-style/profile" { return env.targets.writingStyle.loadProfile() }
    if path.hasPrefix("commands/") {
      let name = String(path.dropFirst("commands/".count))
      return loadCommands().first { $0.name == name }.map { $0.body }
    }
    return nil
  }
}

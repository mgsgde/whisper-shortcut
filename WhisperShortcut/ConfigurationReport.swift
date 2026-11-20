import Foundation

/// A paste-able snapshot of the user's configuration, for WhatsApp or mail.
///
/// Mirrors what the MCP `get_configuration` tool exposes (model names, shortcuts, prompt sections)
/// and nothing else. The base report carries no text the user wrote; prompt, glossary and template
/// texts appear only when the matching option is on. API keys, transcripts, interaction logs, chat
/// history, meeting content and the writing-style profile are never read.
enum ConfigurationReport {
  struct Options: Equatable {
    var includeGlossary = false
    var includePrompts = false
    var includeTemplates = false
  }

  /// The glossary is listed with a count only; its text stays behind `includeGlossary`.
  private static let flaggedSections: [(name: String, section: SystemPromptSection)] =
    MCPConfigTools.sections

  private static let promptSections: [(name: String, section: SystemPromptSection)] =
    MCPConfigTools.sections.filter { $0.section != .whisperGlossary }

  static func build(
    _ options: Options,
    store: SystemPromptsStore = .shared,
    defaults: UserDefaults = .standard,
    environment: UsageReport.Environment = .current,
    settings: [MCPSetting]? = nil,
    templates: [DictationTemplate]? = nil
  ) -> String {
    let buildLabel = environment.isAppStoreBuild ? "App Store build" : "direct build"
    var lines = [
      "WhisperShortcut configuration",
      "App \(environment.appVersion) (\(buildLabel)) · macOS \(environment.osVersion)",
    ]

    // The settings catalog reads effective values, defaults included, so a model the user never
    // changed still shows. Only models, toggles and shortcuts live there; no keys, no user text.
    lines += ["", "## Settings"]
    let catalog = settings ?? MCPSettingsCatalog.build(.init(defaults: defaults))
    var categories: [String] = []
    for setting in catalog where !categories.contains(setting.category) { categories.append(setting.category) }
    for category in categories {
      let rows = catalog.filter { $0.category == category && $0.unavailableReason() == nil }
      guard !rows.isEmpty else { continue }
      lines += ["", "### \(category)"]
      for setting in rows {
        lines.append("\(setting.title): \(MCPSettingsCatalog.label(for: setting.read(), kind: setting.kind))")
      }
    }

    lines += ["", "## System prompts"]
    for (name, section) in flaggedSections {
      let text = trimmed(store.loadSection(section))
      if let legacy = store.legacyFullPrompt(for: section) {
        lines.append("\(name): legacy full prompt, \(legacy.count) chars")
      } else {
        let state = SystemPromptsStore.isCustomized(text, for: section) ? "customized" : "default"
        let count = text.isEmpty ? MCPProposalWindows.defaultText(for: section).count : text.count
        lines.append("\(name): \(state), \(count) chars")
      }
    }

    if options.includePrompts {
      lines += ["", "## System prompt texts"]
      if let reason = store.unreadableReason {
        lines.append("Not available: system-prompts.md cannot be read (\(reason)). The app uses its defaults.")
      } else {
        for (name, section) in promptSections {
          lines += ["", "### \(name)", "```", textInUse(section, store: store), "```"]
        }
      }
    }

    if options.includeGlossary {
      lines += ["", "## Glossary"]
      if let reason = store.unreadableReason {
        lines.append("Not available: system-prompts.md cannot be read (\(reason)). The app uses its defaults.")
      } else {
        lines += ["```", textInUse(.whisperGlossary, store: store), "```"]
      }
    }

    if options.includeTemplates {
      lines += templateLines(templates ?? DictationTemplateStore.load())
    }

    return lines.joined(separator: "\n")
  }

  /// One block per template, after the glossary. A template with no shortcut says `none`, and so
  /// does an empty list: the heading is still there so a missing section is not read as "forgot".
  private static func templateLines(_ templates: [DictationTemplate]) -> [String] {
    var lines = ["", "## Templates"]
    if templates.isEmpty {
      lines.append("none")
      return lines
    }
    for template in templates {
      let shortcut = template.shortcut?.displayString ?? "none"
      lines += [
        "",
        "### \(template.name)  (shortcut: \(shortcut))",
        "```",
        template.instructions,
        "```",
      ]
    }
    return lines
  }

  private static func trimmed(_ text: String?) -> String {
    text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  /// The prompt actually sent. A legacy full prompt replaces the built-in. Otherwise Dictation
  /// and Dictate Prompt are the core plus additions. Other sections are the stored text, or the
  /// shipped default when empty.
  private static func textInUse(_ section: SystemPromptSection, store: SystemPromptsStore) -> String {
    let text = trimmed(store.loadSection(section))
    switch section {
    case .dictationAdditions:
      if let legacy = store.legacyFullPrompt(for: section) { return legacy }
      return AppConstants.withUserAdditions(
        core: AppConstants.defaultTranscriptionSystemPrompt, additions: text,
        taskReminder: AppConstants.dictationTaskReminder)
    case .promptModeAdditions:
      if let legacy = store.legacyFullPrompt(for: section) { return legacy }
      return AppConstants.withUserAdditions(
        core: AppConstants.defaultPromptModeSystemPrompt, additions: text,
        taskReminder: AppConstants.dictatePromptTaskReminder)
    default:
      return text.isEmpty ? MCPProposalWindows.defaultText(for: section) : text
    }
  }
}

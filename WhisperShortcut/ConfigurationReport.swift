import Foundation

/// A paste-able snapshot of the user's configuration, for WhatsApp or mail.
///
/// Mirrors what the MCP `get_configuration` tool exposes (model names, shortcuts, prompt sections)
/// and nothing else. The base report carries no text the user wrote; prompt and glossary texts
/// appear only when the matching option is on. API keys, transcripts, interaction logs, chat
/// history, meeting content and the writing-style profile are never read.
enum ConfigurationReport {
  struct Options: Equatable {
    var includeGlossary = false
    var includePrompts = false
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
    settings: [MCPSetting]? = nil
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
      let state = SystemPromptsStore.isCustomized(text, for: section) ? "customized" : "default"
      let count = text.isEmpty ? MCPProposalWindows.defaultText(for: section).count : text.count
      lines.append("\(name): \(state), \(count) chars")
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

    return lines.joined(separator: "\n")
  }

  private static func trimmed(_ text: String?) -> String {
    text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  /// The prompt actually sent. Dictation and Dictate Prompt are the fixed core plus the user's
  /// additions. Other sections are the customized text, or the shipped default when empty.
  private static func textInUse(_ section: SystemPromptSection, store: SystemPromptsStore) -> String {
    let text = trimmed(store.loadSection(section))
    switch section {
    case .dictation:
      return AppConstants.withUserAdditions(core: AppConstants.defaultTranscriptionSystemPrompt, additions: text)
    case .promptMode:
      return AppConstants.withUserAdditions(core: AppConstants.defaultPromptModeSystemPrompt, additions: text)
    default:
      return text.isEmpty ? MCPProposalWindows.defaultText(for: section) : text
    }
  }
}

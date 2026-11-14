import Foundation

/// A raw value a finding proposes to write, Equatable so findings can be compared in tests.
enum SettingsFindingValue: Equatable {
  case bool(Bool)
  case string(String)

  /// The raw value the catalog's `validate`/`apply` take.
  var raw: Any {
    switch self {
    case .bool(let b): return b
    case .string(let s): return s
    }
  }
}

/// One thing the in-app Chat's `/improve` review may suggest about the user's setup.
struct SettingsFinding: Equatable {
  enum Priority: String { case blocker, recommended, optional }
  enum Fix: Equatable {
    case set(id: String, value: SettingsFindingValue)
    case userAction(where: String)
  }

  /// A catalog setting id, or "permission.accessibility" / "permission.screen_recording".
  let id: String
  let title: String
  let benefit: String
  let priority: Priority
  /// English label of the current value (also what a suppression compares against).
  let current: String
  /// English label of the recommended value.
  let recommended: String
  let fix: Fix
}

/// Findings the user declined or dismissed, remembered per finding id together with the value the
/// setting had at that moment: a changed value clears the suppression, so a finding only comes
/// back when something it is about has moved.
struct ImproveSuppressions {
  static let defaultsKey = "improveSuppressions"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  private var stored: [String: String] {
    (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
  }

  func suppress(id: String, currentValue: String) {
    var all = stored
    all[id] = currentValue
    defaults.set(all, forKey: Self.defaultsKey)
  }

  func isSuppressed(id: String, currentValue: String) -> Bool {
    stored[id] == currentValue
  }
}

enum SettingsAdvisor {
  /// Most findings one review returns.
  static let maxFindings = 8

  static let accessibilityID = "permission.accessibility"
  static let screenRecordingID = "permission.screen_recording"
  static let usageDataID = "privacy.save_usage_data"
  static let modelIDs = ["dictation.transcription_model", "chat.model", "dictate_prompt.model"]

  /// Model-deviation findings are nag-once: `review` suppresses them as soon as it has shown them.
  static func isNagOnce(_ id: String) -> Bool { modelIDs.contains(id) }

  // MARK: - Findings

  /// Candidates in table order (blocker → recommended → optional), not yet filtered or capped.
  private static func candidates(
    catalog: [MCPSetting], deps: MCPSettingsCatalog.Dependencies
  ) -> [SettingsFinding] {
    func setting(_ id: String) -> MCPSetting? {
      guard let s = catalog.first(where: { $0.id == id }), s.unavailableReason() == nil else { return nil }
      return s
    }
    func isOn(_ id: String) -> Bool { (setting(id)?.read() as? Bool) == true }
    func label(_ s: MCPSetting, _ value: Any) -> String { MCPSettingsCatalog.label(for: value, kind: s.kind) }

    var out: [SettingsFinding] = []

    // Blockers
    if let s = setting(usageDataID), (s.read() as? Bool) == false, !OfflineModeProbe.isOn(deps) {
      out.append(SettingsFinding(
        id: s.id, title: String(localized: "Save usage data"),
        benefit: String(localized: "Lets Improve learn from your dictations and fix names and wording it keeps getting wrong. It stays on this Mac."),
        priority: .blocker, current: "Off", recommended: "On", fix: .set(id: s.id, value: .bool(true))))
    }
    if (isOn("clipboard.auto_paste") || isOn("dictation.fn_key")) && !deps.hasAccessibilityPermission() {
      out.append(SettingsFinding(
        id: accessibilityID, title: String(localized: "Accessibility permission"),
        benefit: String(localized: "Auto-paste and Fn dictation are on but can't work without it."),
        priority: .blocker, current: "Missing", recommended: "Granted",
        fix: .userAction(where: String(localized: "Settings → Permissions"))))
    }
    if isOn("dictate_prompt.screenshot_context") && !deps.hasScreenRecordingPermission() {
      out.append(SettingsFinding(
        id: screenRecordingID, title: String(localized: "Screen Recording permission"),
        benefit: String(localized: "Front window picture is on but does nothing without it."),
        priority: .blocker, current: "Missing", recommended: "Granted",
        fix: .userAction(where: String(localized: "Settings → Permissions"))))
    }

    // Recommended: bool settings that are off. Skipped when turning them on would be refused
    // right now (e.g. no Accessibility permission yet: the blocker above covers that case).
    let recommended: [(id: String, title: String, benefit: String)] = [
      ("dictation.fn_key", String(localized: "Dictate with the Fn key"),
       String(localized: "Press Fn to dictate, with no shortcut to remember.")),
      ("clipboard.auto_paste", String(localized: "Auto-paste after dictation"),
       String(localized: "Dictated text lands at the cursor by itself, no Cmd+V needed.")),
      ("dictate_prompt.field_text_context", String(localized: "Send text around the cursor"),
       String(localized: "Dictate Prompt sees the text you are editing, so \"shorten this\" or \"reply to that\" just works.")),
      ("dictate_prompt.screenshot_context", String(localized: "Send picture of front window"),
       String(localized: "When the field is empty or unreadable, Dictate Prompt also sees the front window (never the whole screen).")),
      ("general.launch_at_login", String(localized: "Launch at login"),
       String(localized: "Dictation is ready right after you start your Mac.")),
    ]
    for item in recommended {
      guard let s = setting(item.id), (s.read() as? Bool) == false, s.validate(true) == nil else { continue }
      out.append(SettingsFinding(
        id: s.id, title: item.title, benefit: item.benefit, priority: .recommended,
        current: "Off", recommended: "On", fix: .set(id: s.id, value: .bool(true))))
    }

    // Optional: models that differ from the shipped defaults.
    let defaultModels: [String: String] = [
      "dictation.transcription_model": SettingsDefaults.selectedTranscriptionModel.rawValue,
      "chat.model": SettingsDefaults.selectedChatModel.rawValue,
      "dictate_prompt.model": SettingsDefaults.selectedPromptModel.rawValue,
    ]
    for id in modelIDs {
      guard let s = setting(id), let target = defaultModels[id],
        let current = s.read() as? String, current != target,
        case .enumeration(let options) = s.kind,
        let option = options().first(where: { $0.value == target }), option.available
      else { continue }
      out.append(SettingsFinding(
        id: id, title: MCPSettingsCatalog.reviewTitle(s.title),
        benefit: String(localized: "The recommended model is \(option.label)."),
        priority: .optional, current: label(s, current), recommended: option.label,
        fix: .set(id: id, value: .string(target))))
    }
    if let s = setting("writing_style.enabled"), (s.read() as? Bool) == false, s.validate(true) == nil {
      out.append(SettingsFinding(
        id: s.id, title: String(localized: "Use my writing style in Dictate Prompt"),
        benefit: String(localized: "Dictate Prompt writes the way you do, learned from your sent mail."),
        priority: .optional, current: "Off", recommended: "On", fix: .set(id: s.id, value: .bool(true))))
    }
    return out
  }

  /// The pure review: unsuppressed findings, ordered blocker → recommended → optional (stable
  /// within a priority, in table order), at most `maxFindings`.
  static func findings(
    catalog: [MCPSetting], deps: MCPSettingsCatalog.Dependencies, suppressions: ImproveSuppressions
  ) -> [SettingsFinding] {
    let all = candidates(catalog: catalog, deps: deps)
    return sorted(all.filter { !suppressions.isSuppressed(id: $0.id, currentValue: $0.current) })
  }

  private static func sorted(_ list: [SettingsFinding]) -> [SettingsFinding] {
    let rank: [SettingsFinding.Priority: Int] = [.blocker: 0, .recommended: 1, .optional: 2]
    let ordered = list.enumerated().sorted { a, b in
      let ra = rank[a.element.priority] ?? 3, rb = rank[b.element.priority] ?? 3
      return ra != rb ? ra < rb : a.offset < b.offset
    }.map(\.element)
    return Array(ordered.prefix(maxFindings))
  }

  /// What the Chat's `app_settings` review returns: the findings, how many were held back by
  /// earlier declines, and the nag-once side effect (model-deviation findings are suppressed the
  /// first time they are shown, so they come up once and are never repeated unprompted).
  static func review(
    catalog: [MCPSetting], deps: MCPSettingsCatalog.Dependencies, suppressions: ImproveSuppressions
  ) -> (findings: [SettingsFinding], suppressedCount: Int) {
    let all = candidates(catalog: catalog, deps: deps)
    let suppressedCount = all.filter { suppressions.isSuppressed(id: $0.id, currentValue: $0.current) }.count
    let shown = sorted(all.filter { !suppressions.isSuppressed(id: $0.id, currentValue: $0.current) })
    for finding in shown where isNagOnce(finding.id) {
      suppressions.suppress(id: finding.id, currentValue: finding.current)
    }
    return (shown, suppressedCount)
  }

  /// English label of what a finding id is currently set to, i.e. the value a suppression is
  /// stored against. Nil for an id that is neither a permission nor a catalog setting.
  static func currentLabel(forFindingID id: String, catalog: [MCPSetting]) -> String? {
    if id == accessibilityID || id == screenRecordingID { return "Missing" }
    guard let s = catalog.first(where: { $0.id == id }) else { return nil }
    return MCPSettingsCatalog.label(for: s.read(), kind: s.kind)
  }

  /// The Settings tab that holds a finding's setting, when that is certain.
  static func settingsTab(forFindingID id: String) -> SettingsTab? {
    switch id.split(separator: ".").first.map(String.init) {
    case "privacy", "permission": return .permissions
    case "dictate_prompt", "writing_style": return .speechToPrompt
    case "general": return .general
    default: return nil
    }
  }

  /// JSON the Chat tool hands the model for one finding.
  static func json(_ finding: SettingsFinding) -> [String: Any] {
    var fix: [String: Any]
    switch finding.fix {
    case .set(let id, let value): fix = ["type": "set", "id": id, "value": value.raw]
    case .userAction(let place): fix = ["type": "user_action", "where": place]
    }
    return [
      "id": finding.id, "title": finding.title, "benefit": finding.benefit,
      "priority": finding.priority.rawValue, "current": finding.current,
      "recommended": finding.recommended, "fix": fix,
    ]
  }
}

/// Offline Mode as `privacy.save_usage_data` sees it: that entry is unavailable while it is on, so
/// the advisor never reaches the check with Offline Mode on; this only guards a catalog that does
/// not hide the entry.
private enum OfflineModeProbe {
  static func isOn(_ deps: MCPSettingsCatalog.Dependencies) -> Bool {
    deps.defaults.bool(forKey: UserDefaultsKeys.offlineModeEnabled)
  }
}

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

  func storedLabel(for id: String) -> String? {
    stored[id]
  }

  /// Drops one dismissal. Used when the value it was stored against is no longer current, so a
  /// later return to that same label is raised again instead of staying hidden.
  func clear(id: String) {
    var all = stored
    guard all.removeValue(forKey: id) != nil else { return }
    if all.isEmpty {
      defaults.removeObject(forKey: Self.defaultsKey)
    } else {
      defaults.set(all, forKey: Self.defaultsKey)
    }
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

  // MARK: - Feature states (the one list of "features worth turning on")

  /// One feature the user may want on: its current on/off and permission state, once, for both
  /// projections (the Chat's `/improve` findings and MCP `not_yet_enabled`).
  struct FeatureState {
    enum Permission { case accessibility, screenRecording }

    let setting: MCPSetting
    /// Chat wording (localized).
    let title: String
    let benefit: String
    /// Model-facing English wording for MCP.
    let mcpTitle: String
    let mcpBenefit: String
    let permission: Permission?
    let isOn: Bool
    /// True when no permission is needed or it is granted.
    let permissionGranted: Bool
    /// `how_to_enable` for MCP, by state.
    let mcpOffHow: String
    let mcpOffMissingHow: String?
    let mcpOnMissingHow: String?

    var id: String { setting.id }
  }

  /// Ids in MCP `not_yet_enabled` order (the Chat uses `featureStates` order).
  static let mcpFeatureOrder = [
    "clipboard.auto_paste", "dictate_prompt.screenshot_context", "dictation.fn_key",
    "dictate_prompt.field_text_context", "general.launch_at_login",
  ]

  /// Unsuppressed, uncapped, in Chat recommended order. Features the catalog hides (e.g. Fn key
  /// in the App Store build) are left out.
  static func featureStates(
    catalog: [MCPSetting], deps: MCPSettingsCatalog.Dependencies
  ) -> [FeatureState] {
    func make(
      _ id: String, title: String, benefit: String, mcpTitle: String, mcpBenefit: String,
      permission: FeatureState.Permission?, offHow: String, offMissingHow: String? = nil,
      onMissingHow: String? = nil
    ) -> FeatureState? {
      guard let s = catalog.first(where: { $0.id == id }), s.unavailableReason() == nil,
        let value = s.read() as? Bool
      else { return nil }
      let granted: Bool
      switch permission {
      case .accessibility: granted = deps.hasAccessibilityPermission()
      case .screenRecording: granted = deps.hasScreenRecordingPermission()
      case nil: granted = true
      }
      return FeatureState(
        setting: s, title: title, benefit: benefit, mcpTitle: mcpTitle, mcpBenefit: mcpBenefit,
        permission: permission, isOn: value, permissionGranted: granted, mcpOffHow: offHow,
        mcpOffMissingHow: offMissingHow, mcpOnMissingHow: onMissingHow)
    }
    let grantAccessibility =
      "The user grants Accessibility in WhisperShortcut Settings → Permissions (only they can), then you or they turn on"
    return [
      make(
        "dictation.fn_key", title: String(localized: "Dictate with the Fn key"),
        benefit: String(localized: "Press Fn to dictate, with no shortcut to remember."),
        mcpTitle: "Dictate with the Fn key",
        mcpBenefit: "Press Fn to dictate, with no shortcut to remember.",
        permission: .accessibility,
        offHow: "Ask the user, then update_settings dictation.fn_key = true.",
        offMissingHow: "\(grantAccessibility) dictation.fn_key.",
        onMissingHow:
          "Fn dictation is on but cannot work without Accessibility. The user grants it in WhisperShortcut Settings → Permissions."),
      make(
        "clipboard.auto_paste", title: String(localized: "Auto-paste after dictation"),
        benefit: String(localized: "Dictated text lands at the cursor by itself, no Cmd+V needed."),
        mcpTitle: "Auto-paste after dictation",
        mcpBenefit:
          "Dictated text lands at the cursor by itself instead of only on the clipboard, so the user does not have to press Cmd+V after every dictation.",
        permission: .accessibility,
        offHow: "Ask the user, then update_settings clipboard.auto_paste = true.",
        offMissingHow: "\(grantAccessibility) clipboard.auto_paste.",
        onMissingHow:
          "Auto-paste is on but cannot paste without Accessibility. The user grants it in WhisperShortcut Settings → Permissions."),
      make(
        "dictate_prompt.field_text_context", title: String(localized: "Send text around the cursor"),
        benefit: String(localized: "Dictate Prompt sees the text you are editing, so \"shorten this\" or \"reply to that\" just works."),
        mcpTitle: "Send text around the cursor",
        mcpBenefit: "Dictate Prompt sees the text you are editing, so \"shorten this\" or \"reply to that\" just works.",
        permission: nil,
        offHow:
          "Propose update_settings dictate_prompt.field_text_context = true. WhisperShortcut shows the user the consent text before anything changes; do not turn it on any other way."),
      make(
        "dictate_prompt.screenshot_context", title: String(localized: "Send picture of front window"),
        benefit: String(localized: "When the field is empty or unreadable, Dictate Prompt also sees the front window (never the whole screen)."),
        mcpTitle: "Front window picture",
        mcpBenefit:
          "When the focused field is empty, short or unreadable, Dictate Prompt also sees a picture of the front window (never the whole screen), so it understands what the user is replying to or editing.",
        permission: .screenRecording,
        offHow:
          "Propose update_settings dictate_prompt.screenshot_context = true. WhisperShortcut shows the user the consent text before anything changes; do not turn it on any other way.",
        offMissingHow:
          "The user grants Screen Recording in WhisperShortcut Settings → Permissions, then turns on Front window picture in Dictate Prompt settings. That switch shows the consent text first.",
        onMissingHow:
          "The setting is on but does nothing without Screen Recording. The user grants it in WhisperShortcut Settings → Permissions."),
      make(
        "general.launch_at_login", title: String(localized: "Launch at login"),
        benefit: String(localized: "Dictation is ready right after you start your Mac."),
        mcpTitle: "Launch at login",
        mcpBenefit: "Dictation is ready right after you start your Mac.",
        permission: nil,
        offHow:
          "Ask the user, then propose update_settings general.launch_at_login = true; the user accepts it in WhisperShortcut."),
    ].compactMap { $0 }
  }

  /// MCP `get_configuration` → `not_yet_enabled`: the same feature states, no suppressions (an
  /// outside AI app has its own conversation), none of the chat-only entries (models, writing
  /// style, usage data), plus `recent_interactions`, which only exists for MCP.
  static func mcpNotYetEnabled(
    catalog: [MCPSetting], deps: MCPSettingsCatalog.Dependencies, interactionsShared: Bool
  ) -> [[String: Any]] {
    func hint(_ id: String, _ title: String, _ state: String, _ benefit: String, _ how: String) -> [String: Any] {
      ["id": id, "title": title, "state": state, "benefit": benefit, "how_to_enable": how]
    }
    let states = featureStates(catalog: catalog, deps: deps)
    var out: [[String: Any]] = []
    for id in mcpFeatureOrder {
      guard let f = states.first(where: { $0.id == id }) else { continue }
      if f.isOn && f.permissionGranted { continue }
      if f.isOn {
        guard let how = f.mcpOnMissingHow else { continue }
        out.append(hint(id, f.mcpTitle, "on_but_permission_missing", f.mcpBenefit, how))
      } else if f.permissionGranted {
        out.append(hint(id, f.mcpTitle, "off", f.mcpBenefit, f.mcpOffHow))
      } else {
        out.append(hint(id, f.mcpTitle, "off_permission_missing", f.mcpBenefit, f.mcpOffMissingHow ?? f.mcpOffHow))
      }
    }
    if !interactionsShared {
      out.append(hint(
        "recent_interactions", "AI apps may read recent dictations", "off",
        "Lets you read the user's recent dictations and errors, so tuning fixes real mistakes instead of guesses.",
        "The user turns on \"Save usage data\" and \"AI apps may read my recent dictations\" in WhisperShortcut Settings."))
    }
    return out
  }

  // MARK: - Findings

  /// Chat candidates in table order (blocker → recommended → optional), not yet filtered or capped.
  private static func candidates(
    catalog: [MCPSetting], deps: MCPSettingsCatalog.Dependencies
  ) -> [SettingsFinding] {
    func setting(_ id: String) -> MCPSetting? {
      guard let s = catalog.first(where: { $0.id == id }), s.unavailableReason() == nil else { return nil }
      return s
    }
    func label(_ s: MCPSetting, _ value: Any) -> String { MCPSettingsCatalog.label(for: value, kind: s.kind) }

    let states = featureStates(catalog: catalog, deps: deps)
    func blocked(_ p: FeatureState.Permission) -> Bool {
      states.contains { $0.permission == p && $0.isOn && !$0.permissionGranted }
    }

    var out: [SettingsFinding] = []

    // Blockers
    if let s = setting(usageDataID), (s.read() as? Bool) == false, !OfflineModeProbe.isOn(deps) {
      out.append(SettingsFinding(
        id: s.id, title: String(localized: "Save usage data"),
        benefit: String(localized: "Lets Improve learn from your dictations and fix names and wording it keeps getting wrong. It stays on this Mac."),
        priority: .blocker, current: "Off", recommended: "On", fix: .set(id: s.id, value: .bool(true))))
    }
    if blocked(.accessibility) {
      out.append(SettingsFinding(
        id: accessibilityID, title: String(localized: "Accessibility permission"),
        benefit: String(localized: "Auto-paste and Fn dictation are on but can't work without it."),
        priority: .blocker, current: permissionLabel(granted: false), recommended: permissionLabel(granted: true),
        fix: .userAction(where: String(localized: "Settings → Permissions"))))
    }
    if blocked(.screenRecording) {
      out.append(SettingsFinding(
        id: screenRecordingID, title: String(localized: "Screen Recording permission"),
        benefit: String(localized: "Front window picture is on but does nothing without it."),
        priority: .blocker, current: permissionLabel(granted: false), recommended: permissionLabel(granted: true),
        fix: .userAction(where: String(localized: "Settings → Permissions"))))
    }

    // Recommended: features that are off. Skipped when turning them on would be refused right
    // now (e.g. no Accessibility permission yet: the blocker above covers that case).
    // Settings with consent text are optional: an AI app must not recommend them the way it
    // recommends Auto-paste. The proposal window shows the consent text before they change.
    for f in states where !f.isOn && f.setting.validate(true) == nil {
      let priority: SettingsFinding.Priority = f.setting.consentText == nil ? .recommended : .optional
      out.append(SettingsFinding(
        id: f.id, title: f.title, benefit: f.benefit, priority: priority,
        current: "Off", recommended: "On", fix: .set(id: f.id, value: .bool(true))))
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
    expirePermissionDismissals(suppressions, deps: deps)
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
    expirePermissionDismissals(suppressions, deps: deps)
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
  ///
  /// Accessibility and Screen Recording used to answer "Missing" always, so a dismissal stored
  /// against that word matched again after the permission was granted and then revoked. The live
  /// check (injected in tests) is what a later review compares.
  static func currentLabel(
    forFindingID id: String, catalog: [MCPSetting],
    permissionStatus: (PermissionKind) -> PermissionStatus = { PermissionStatusChecker.status(for: $0) }
  ) -> String? {
    switch id {
    case accessibilityID:
      return permissionLabel(granted: permissionStatus(.accessibility) == .granted)
    case screenRecordingID:
      return permissionLabel(granted: permissionStatus(.screenRecording) == .granted)
    default:
      guard let s = catalog.first(where: { $0.id == id }) else { return nil }
      return MCPSettingsCatalog.label(for: s.read(), kind: s.kind)
    }
  }

  /// The two words a permission finding and its dismissal share. Anything but granted is
  /// "Missing": denied and not-yet-asked look the same to this review.
  private static func permissionLabel(granted: Bool) -> String {
    granted ? "Granted" : "Missing"
  }

  /// A dismissal remembers the label it saw. Once that label moves (Missing → Granted), drop it.
  /// Otherwise a later revoke stays hidden: the finding only exists while the label is "Missing",
  /// which is exactly the word the dismissal stored.
  private static func expirePermissionDismissals(
    _ suppressions: ImproveSuppressions, deps: MCPSettingsCatalog.Dependencies
  ) {
    let status: (PermissionKind) -> PermissionStatus = { kind in
      switch kind {
      case .accessibility:
        return deps.hasAccessibilityPermission() ? .granted : .denied
      case .screenRecording:
        return deps.hasScreenRecordingPermission() ? .granted : .denied
      case .microphone:
        return .notDetermined
      }
    }
    for id in [accessibilityID, screenRecordingID] {
      guard let live = currentLabel(forFindingID: id, catalog: [], permissionStatus: status),
        let stored = suppressions.storedLabel(for: id), stored != live
      else { continue }
      suppressions.clear(id: id)
    }
  }

  /// The Settings tab that holds a finding's setting, when that is certain.
  ///
  /// Prefixes whose settings all live on one tab map together. `dictation` does not: the Fn key
  /// (`dictation.fn_key`) is on General, the transcription model (`dictation.transcription_model`)
  /// is on Dictate. Any other `dictation.*` id, and anything that is not one setting on one tab
  /// (for example MCP-only `recent_interactions`), stays nil.
  static func settingsTab(forFindingID id: String) -> SettingsTab? {
    switch id {
    case "dictation.fn_key": return .general
    case "dictation.transcription_model": return .speechToText
    default: break
    }
    switch id.split(separator: ".").first.map(String.init) {
    case "privacy", "permission": return .permissions
    case "dictate_prompt", "writing_style": return .speechToPrompt
    case "general", "clipboard": return .general
    case "chat": return .chat
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

import AppKit
import Foundation
import HotKey
import ServiceManagement

extension Notification.Name {
  /// Posted on main after `update_settings` applies a batch, so every open Settings window and
  /// every `@State` field that mirrors a UserDefaults key can reload instead of going stale or,
  /// on save, clobbering what an AI app just changed. One post per batch, never per setting.
  static let settingsChangedExternally = Notification.Name("settingsChangedExternally")
}

/// Modifier rule for global Carbon hotkeys, shared by the Settings UI recorder
/// (`ShortcutRecorderRow.handleKeyDown`) and `get_settings`/`update_settings`'s shortcut entries,
/// so an AI app cannot propose a combination the recorder itself would reject.
enum ShortcutValidation {
  private static let functionKeys: Set<Key> = [
    .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
    .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
  ]

  /// nil = allowed. F1–F20 may be bare; everything else needs ⌘/⌥/⌃ (Shift alone is rejected —
  /// macOS routes Shift+<printable> to text input, so Carbon never fires those bindings). Wording
  /// matches `ShortcutRecorderRow.handleKeyDown`'s inline messages exactly — that is the UI copy
  /// of record, this is the shared copy both the recorder and the MCP catalog call.
  static func modifierRuleViolation(key: Key, modifiers: NSEvent.ModifierFlags) -> String? {
    if functionKeys.contains(key) { return nil }
    let commandModifiers = modifiers.intersection([.command, .option, .control])
    guard commandModifiers.isEmpty else { return nil }
    if modifiers.isEmpty { return "Add ⌘/⌥/⌃ — or use an F-key (F1–F20) on its own" }
    return "Shift alone won't fire — add ⌘/⌥/⌃"
  }

  /// The slot name already using `key`/`modifiers` among `slots`, other than `excluding`; nil =
  /// free. Generic over (name, definition) pairs so `SettingsViewModel.findShortcutConflict` (which
  /// has no `ShortcutConfig`, only its own per-field `SettingsData`) and the `ShortcutConfig`
  /// overload below share one conflict rule instead of two copies that can drift apart.
  static func conflictingSlot(
    key: Key, modifiers: NSEvent.ModifierFlags,
    among slots: [(name: String, definition: ShortcutDefinition?)], excluding: String
  ) -> String? {
    for (name, def) in slots where name != excluding {
      guard let def, def.isEnabled, def.key == key, def.modifiers == modifiers else { continue }
      return name
    }
    return nil
  }

  /// The slot name already using `key`/`modifiers` in `config`, other than `excluding`; nil = free.
  static func conflictingSlot(
    key: Key, modifiers: NSEvent.ModifierFlags, in config: ShortcutConfig, excluding: String
  ) -> String? {
    let slots: [(name: String, definition: ShortcutDefinition?)] = [
      ("Toggle Dictation", config.startRecording), ("Toggle Dictate Prompt", config.startPrompting),
      ("Open Settings", config.openSettings), ("Open Chat", config.openChat),
      ("Screenshot", config.screenshotCapture), ("Read Aloud", config.readAloud),
      ("Add to Glossary", config.addToGlossary),
    ]
    return conflictingSlot(key: key, modifiers: modifiers, among: slots, excluding: excluding)
  }
}

/// One entry an AI app can read and, within its access level, change — the catalog behind the
/// generic `get_settings` / `update_settings` tools. Dependencies (UserDefaults, permission
/// checks, build flavour, notification poster) are closed over by each entry's closures, built by
/// `MCPSettingsCatalog.build(_:)` from a `Dependencies` value, so tests never touch the real
/// UserDefaults, Keychain or SMAppService.
struct MCPSetting {
  struct Option {
    let value: String
    let label: String
    /// False when the model/setting cannot run with what the user has configured (e.g. no key).
    let available: Bool
    let reason: String?

    init(_ value: String, _ label: String, available: Bool = true, reason: String? = nil) {
      self.value = value
      self.label = label
      self.available = available
      self.reason = reason
    }
  }

  enum Kind {
    case bool
    case string(maxLength: Int)
    case enumeration(options: () -> [Option])
    case shortcut
  }

  let id: String
  let title: String
  let category: String
  let kind: Kind
  /// Always a proposal, at every access level, never applied directly.
  let proposalOnly: Bool
  /// Non-nil = this entry cannot be read or changed right now (and why); the tools skip it.
  let unavailableReason: () -> String?
  let read: () -> Any
  /// nil = valid. Runs before any `apply`, so a batch with one invalid change writes nothing.
  let validate: (Any) -> String?
  let apply: (Any) throws -> Void
  /// What a proposal/change-log `toLabel` should show for a raw value headed into `apply` —
  /// identity for almost everything, but `chat.x_search_handles` normalizes (lowercases, dedupes,
  /// caps) before storing, so the label must show what will actually be stored, not the AI's raw
  /// input verbatim.
  let normalizeForLabel: (Any) -> Any

  init(
    id: String, title: String, category: String, kind: Kind, proposalOnly: Bool = false,
    unavailableReason: @escaping () -> String? = { nil }, read: @escaping () -> Any,
    validate: @escaping (Any) -> String?, apply: @escaping (Any) throws -> Void,
    normalizeForLabel: @escaping (Any) -> Any = { $0 }
  ) {
    self.id = id
    self.title = title
    self.category = category
    self.kind = kind
    self.proposalOnly = proposalOnly
    self.unavailableReason = unavailableReason
    self.read = read
    self.validate = validate
    self.apply = apply
    self.normalizeForLabel = normalizeForLabel
  }
}

/// One entry of an applied or proposed settings batch, with human labels for the plain-text
/// settings proposal/change-log body (`MCPProposalWindows`, `MeetingsInAIAppsSection`) and
/// JSON-encoded raw values (`MCPSettingsCatalog.encodeValue`/`decodeValue`) so Undo and proposal
/// acceptance can replay them through the catalog's own `validate`/`apply`.
struct MCPSettingsChangeItem: Codable, Equatable {
  let id: String
  let title: String
  let fromLabel: String
  let toLabel: String
  let fromJSON: String
  let toJSON: String
}

/// Result of replaying one item's `fromJSON` through the catalog on Undo.
enum MCPSettingsRestoreOutcome {
  case restored
  case invalid(String)
}

enum MCPSettingsCatalog {
  /// Everything an entry's closures need, injected so tests use fakes instead of the real
  /// UserDefaults, Keychain, Accessibility/Screen Recording permission or SMAppService.
  struct Dependencies {
    var defaults: UserDefaults = .standard
    var hasAccessibilityPermission: () -> Bool = { AccessibilityPermissionManager.hasAccessibilityPermission() }
    /// Read-only. `CGPreflightScreenCaptureAccess` does not prompt; MCP must never call
    /// `SCShareableContent`, which is what the Settings toggle uses to prompt.
    var hasScreenRecordingPermission: () -> Bool = {
      PermissionStatusChecker.status(for: .screenRecording) == .granted
    }
    var hasScreenshotFolder: () -> Bool = { ScreenshotSaveLocation.hasFolder }
    var isLaunchAtLoginEnabled: () -> Bool = { SMAppService.mainApp.status == .enabled }
    var setLaunchAtLogin: (Bool) throws -> Void = { enabled in
      if enabled {
        if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
      } else if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      }
    }
    var loadShortcutConfig: () -> ShortcutConfig = { ShortcutConfigManager.shared.loadConfiguration() }
    var saveShortcutConfig: (ShortcutConfig) -> Void = { ShortcutConfigManager.shared.saveConfiguration($0) }
    var postNotification: (Notification.Name, Any?) -> Void = { name, object in
      NotificationCenter.default.post(name: name, object: object)
    }
    /// After a model selection is written. Tests replace this; the live default is
    /// `ModelSelectionReconciler.postSelectionsChanged` (posts `.modelSelectionsReconciled`
    /// and `.modelChanged` for the dictation slot). Routed through `deps` so a test suite
    /// never posts those notifications into the user's running app.
    var postSelectionsChanged: () -> Void = {
      let post = { MainActor.assumeIsolated { ModelSelectionReconciler.postSelectionsChanged() } }
      if Thread.isMainThread { post() } else { DispatchQueue.main.sync(execute: post) }
    }
    /// Settings → Improvement calls this after the auto-run picker changes. Tests replace it;
    /// the live default is the same `checkAndRunIfDue()` the view runs.
    var checkImprovementAutoRun: () -> Void = {
      Task { @MainActor in
        await ImproveFromUsageAutoRunCoordinator.shared.checkAndRunIfDue()
      }
    }

    static let live = Dependencies()
  }

  /// Catalog token for a whole-number `Double` raw value the Settings picker stores as a number
  /// (`"10"`, `"0"`). `apply` writes the `Double` back under the same key.
  private static func wholeNumberToken(_ value: Double) -> String {
    String(Int(value.rounded()))
  }

  // MARK: - Value coding

  /// Wraps `value` so a bare scalar (Bool/String) round-trips through `JSONSerialization`, which
  /// requires an array or object at the top level. `NSNull` (used for "disabled"/"off") round-trips
  /// through this unchanged.
  static func encodeValue(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: ["v": value]) else { return "{}" }
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  static func decodeValue(_ json: String) -> Any? {
    guard let data = json.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj["v"]
  }

  /// Human label for a raw catalog value, used in `get_settings` output and in the plain-text
  /// settings proposal/change-log body. The visual design of that body belongs to Opus 5.5;
  /// this only supplies the words.
  static func label(for value: Any, kind: MCPSetting.Kind) -> String {
    switch kind {
    case .bool:
      return (value as? Bool) == true ? "On" : "Off"
    case .string:
      let s = (value as? String) ?? ""
      return s.isEmpty ? "(empty)" : s
    case .enumeration(let options):
      // `meetings.transcription_model` accepts JSON null for "same as dictation".
      if value is NSNull { return "Same as dictation" }
      guard let raw = value as? String else { return "\(value)" }
      return options().first { $0.value == raw }?.label ?? raw
    case .shortcut:
      if value is NSNull { return "Disabled" }
      guard let dict = value as? [String: Any], let def = shortcutDefinition(from: dict) else { return "Disabled" }
      return def.displayStringWithSeparator
    }
  }

  /// English `title` / `label(for:)` stay what `get_settings` and `update_settings` return to the
  /// AI app. The proposal review window uses these copies so the same words can be translated.
  static func reviewTitle(_ english: String) -> String {
    switch english {
    case "Dictation model": return String(localized: "Dictation model")
    case "Chat model": return String(localized: "Chat model")
    case "OpenRouter chat model id": return String(localized: "OpenRouter chat model id")
    case "Meeting transcription model": return String(localized: "Meeting transcription model")
    case "Dictate Prompt model": return String(localized: "Dictate Prompt model")
    case "Meeting summary model": return String(localized: "Meeting summary model")
    case "Smart Improvement model": return String(localized: "Smart Improvement model")
    case "Read Aloud model": return String(localized: "Read Aloud model")
    case "ChatGPT plan model id": return String(localized: "ChatGPT plan model id")
    case "Custom endpoint model id": return String(localized: "Custom endpoint model id")
    case "OpenRouter dictation model id": return String(localized: "OpenRouter dictation model id")
    case "Local Dictate Prompt model id": return String(localized: "Local Dictate Prompt model id")
    case "Dictation language": return String(localized: "Dictation language")
    case "Temperature": return String(localized: "Temperature")
    case "Thinking effort": return String(localized: "Thinking effort")
    case "Toggle Dictation shortcut": return String(localized: "Toggle Dictation shortcut")
    case "Toggle Dictate Prompt shortcut": return String(localized: "Toggle Dictate Prompt shortcut")
    case "Screenshot shortcut": return String(localized: "Screenshot shortcut")
    case "Read Aloud shortcut": return String(localized: "Read Aloud shortcut")
    case "Add to Glossary shortcut": return String(localized: "Add to Glossary shortcut")
    case "Open Chat shortcut": return String(localized: "Open Chat shortcut")
    case "Open Settings shortcut": return String(localized: "Open Settings shortcut")
    case "Show dictation notifications": return String(localized: "Show dictation notifications")
    case "Notification position": return String(localized: "Notification position")
    case "Notification duration": return String(localized: "Notification duration")
    case "Auto-paste after dictation": return String(localized: "Auto-paste after dictation")
    case "Restore clipboard after auto-paste": return String(localized: "Restore clipboard after auto-paste")
    case "Hold fn to dictate": return String(localized: "Hold fn to dictate")
    case "Close Settings when it loses focus": return String(localized: "Close Settings when it loses focus")
    case "Close Chat when clicking outside": return String(localized: "Close Chat when clicking outside")
    case "Read Aloud smart rewrite": return String(localized: "Read Aloud smart rewrite")
    case "Playback speed": return String(localized: "Playback speed")
    case "Gemini voice": return String(localized: "Gemini voice")
    case "OpenAI voice": return String(localized: "OpenAI voice")
    case "xAI voice": return String(localized: "xAI voice")
    case "macOS voice": return String(localized: "macOS voice")
    case "Save dictation screenshots": return String(localized: "Save dictation screenshots")
    case "Ask when recording longer than": return String(localized: "Ask when recording longer than")
    case "Meeting chunk interval": return String(localized: "Meeting chunk interval")
    case "Ask when meeting longer than": return String(localized: "Ask when meeting longer than")
    case "Screenshot context": return String(localized: "Screenshot context")
    case "X accounts for Grok": return String(localized: "X accounts for Grok")
    case "Run Improve from usage automatically": return String(localized: "Run Improve from usage automatically")
    case "Launch at login": return String(localized: "Launch at login")
    case "Use my writing style in Dictate Prompt": return String(localized: "Use my writing style in Dictate Prompt")
    case "Let Dictate Prompt use read-only tools": return String(localized: "Let Dictate Prompt use read-only tools")
    case "Let Claude search the web": return String(localized: "Let Claude search the web")
    default: return english
    }
  }

  /// Review-window copy of a stored English value label. Anything that is not one of these fixed
  /// words (a model name, a shortcut, text the user typed) is shown unchanged.
  static func reviewLabel(_ english: String) -> String {
    switch english {
    case "On": return String(localized: "On")
    case "Off": return String(localized: "Off")
    case "(empty)": return String(localized: "(empty)")
    case "Same as dictation": return String(localized: "Same as dictation")
    case "Disabled": return String(localized: "Disabled")
    case "Provider default": return String(localized: "Provider default")
    default: return english
    }
  }

  /// `modifiers` names the MCP shortcut JSON format accepts; anything else (including other
  /// `HotKey.Key(string:)` modifier spellings like "capslock" or "fn") is rejected rather than
  /// silently masked, so an AI app's typo surfaces as an error instead of a wrong shortcut.
  private static let modifierNameToFlag: [String: NSEvent.ModifierFlags] = [
    "command": .command, "option": .option, "control": .control, "shift": .shift,
  ]

  /// Carbon key names that are themselves modifier keys, never a real "key" to bind. Rejected as
  /// `key` even though `HotKey.Key(string:)` parses them (it also accepts "command", "shift", …).
  private static let modifierOnlyKeys: Set<Key> = [
    .command, .rightCommand, .option, .rightOption, .control, .rightControl,
    .shift, .rightShift, .function, .capsLock,
  ]

  /// Decodes the MCP shortcut JSON format (spec in `plans/active/mcp-settings.md`):
  /// `{"key": "1", "modifiers": ["control", "option"]}` — `key` is the key's name/character as
  /// `HotKey.Key(string:)` describes it ("a", "1", "f5", "space", "return", …), `modifiers` is a
  /// subset of `["command", "option", "control", "shift"]`. Unknown keys or modifier names are
  /// rejected (nil) rather than falling back to `.a` or being silently dropped — the old
  /// `ShortcutDefinition`-shaped format (carbon keycode + modifier bitmask) is no longer accepted.
  /// `displayCharacter` is always nil: there is no `NSEvent` to capture one from, and deriving it
  /// from the AI's `key` string (rather than the user's real keyboard) is exactly what
  /// `ShortcutRecorderRow` does NOT do — `ShortcutDefinition.renderShortcut` already falls back to
  /// the layout-aware character (or `Key.displayString`) when `displayCharacter` is nil, the same
  /// path legacy stored shortcuts use.
  private static func shortcutDefinition(from dict: [String: Any]) -> ShortcutDefinition? {
    guard let keyString = dict["key"] as? String, let key = Key(string: keyString),
      !modifierOnlyKeys.contains(key)
    else { return nil }
    guard let modifierNames = dict["modifiers"] as? [String] else { return nil }
    var modifiers: NSEvent.ModifierFlags = []
    for name in modifierNames {
      guard let flag = modifierNameToFlag[name.lowercased()] else { return nil }
      modifiers.insert(flag)
    }
    return ShortcutDefinition(key: key, modifiers: modifiers, isEnabled: true, displayCharacter: nil)
  }

  /// Inverse of `shortcutDefinition(from:)`: the same `{"key", "modifiers"}` shape `read` and
  /// `get_settings` hand back, and an AI app's `update_settings` call must accept.
  private static func json(of definition: ShortcutDefinition) -> Any {
    let modifierNames: [String] = modifierNameToFlag
      .filter { definition.modifiers.contains($0.value) }
      .map(\.key)
    return ["key": definition.key.mcpKeyName, "modifiers": modifierNames.sorted()]
  }

  /// Shown in `validate`/`apply` errors and in `update_settings`'s tool description, so an AI app
  /// sees the expected shape rather than guessing at the old `ShortcutDefinition` Codable layout.
  static let shortcutFormatHint =
    "A shortcut needs {\"key\": <name, e.g. \\\"a\\\"/\\\"1\\\"/\\\"f5\\\"/\\\"space\\\"/\\\"return\\\">, "
    + "\"modifiers\": [subset of \"command\",\"option\",\"control\",\"shift\"]}, or null to disable."

  /// id → slot name, the same name each `shortcutSetting(slot:)` call below passes to
  /// `ShortcutValidation.conflictingSlot(excluding:)` — so `validateBatch`'s merged-state conflict
  /// check (which cannot see the local `slot` captured in each entry's own closures) names the
  /// same slot the per-item check would.
  static let shortcutSlotNames: [String: String] = [
    "shortcuts.dictate": "Toggle Dictation",
    "shortcuts.dictate_prompt": "Toggle Dictate Prompt",
    "shortcuts.screenshot": "Screenshot",
    "shortcuts.read_aloud": "Read Aloud",
    "shortcuts.add_to_glossary": "Add to Glossary",
    "shortcuts.open_chat": "Open Chat",
    "shortcuts.open_settings": "Open Settings",
  ]

  /// Validates every item in a batch against the state the WHOLE batch would leave — not just
  /// today's on-disk state each item's own `validate` compares against — so e.g. two shortcut
  /// items in the same batch that both claim the same still-unused combo are caught before
  /// anything is written, and so is an item that would conflict with another item's new value.
  /// Returns the first problem, or nil if every item in the batch is fine together.
  static func validateBatch(catalog: [MCPSetting], items: [(id: String, value: Any)]) -> String? {
    var byID: [String: Any] = [:]
    for item in items {
      guard let setting = catalog.first(where: { $0.id == item.id }) else {
        return "Unknown setting: \(item.id)."
      }
      if let reason = setting.unavailableReason() { return "\(setting.title): \(reason)" }
      if let problem = setting.validate(item.value) { return "\(setting.title): \(problem)" }
      byID[item.id] = item.value
    }

    // Shortcut items only: re-run the modifier rule and the conflict check across the merged
    // state (every catalog shortcut slot, with this batch's changes layered on top of today's
    // on-disk config) for each shortcut item actually in the batch.
    let shortcutSettings = catalog.filter {
      if case .shortcut = $0.kind { return true } else { return false }
    }
    func resolvedDefinition(for setting: MCPSetting) -> ShortcutDefinition? {
      let value = byID[setting.id] ?? setting.read()
      guard !(value is NSNull), let dict = value as? [String: Any] else { return nil }
      return shortcutDefinition(from: dict)
    }
    let resolved: [(setting: MCPSetting, def: ShortcutDefinition)] = shortcutSettings.compactMap { s in
      resolvedDefinition(for: s).map { (s, $0) }
    }
    for (setting, def) in resolved where byID[setting.id] != nil {
      if let problem = ShortcutValidation.modifierRuleViolation(key: def.key, modifiers: def.modifiers) {
        return "\(setting.title): \(problem)"
      }
      if let other = resolved.first(where: { $0.setting.id != setting.id && $0.def.key == def.key && $0.def.modifiers == def.modifiers }) {
        let otherName = shortcutSlotNames[other.setting.id] ?? other.setting.title
        return "\(setting.title): That shortcut is already used by \(otherName)."
      }
    }
    return nil
  }

  // MARK: - Restore (Undo)

  /// Replays one change-log item's `from` value through the live catalog, used only by
  /// `MCPChangeLog.undo` for a `.settings` batch. Skips (rather than fails the whole undo) an item
  /// whose setting no longer validates — e.g. the model it names lost its credential meanwhile.
  static func restore(catalog: [MCPSetting], id: String, json: String) -> MCPSettingsRestoreOutcome {
    guard let setting = catalog.first(where: { $0.id == id }) else {
      return .invalid(String(localized: "setting no longer exists"))
    }
    guard setting.unavailableReason() == nil else { return .invalid(setting.unavailableReason() ?? "unavailable") }
    guard let value = decodeValue(json) else {
      return .invalid(String(localized: "could not read the previous value"))
    }
    if let problem = setting.validate(value) { return .invalid(problem) }
    do {
      try setting.apply(value)
      return .restored
    } catch {
      return .invalid(error.localizedDescription)
    }
  }

  // MARK: - Catalog

  /// The settings an AI app can read/change. A representative subset of the app's settings
  /// surface, not every `UserDefaultsKeys` entry — see `plans/active/mcp-settings.md` and the
  /// implementation report for which were left out and why.
  static func build(_ deps: Dependencies) -> [MCPSetting] {
    let defaults = deps.defaults

    func boolSetting(
      id: String, title: String, category: String, key: String, defaultValue: Bool,
      proposalOnly: Bool = false, unavailableReason: @escaping () -> String? = { nil },
      enablingRefused: @escaping () -> String? = { nil },
      afterApply: @escaping (Bool) -> Void = { _ in }
    ) -> MCPSetting {
      MCPSetting(
        id: id, title: title, category: category, kind: .bool, proposalOnly: proposalOnly,
        unavailableReason: unavailableReason,
        read: { defaults.object(forKey: key) != nil ? defaults.bool(forKey: key) : defaultValue },
        validate: { value in
          guard let b = value as? Bool else { return "\(title) needs true or false." }
          if b, let reason = enablingRefused() { return reason }
          return nil
        },
        apply: { value in
          guard let b = value as? Bool else { throw MCPConfigError(message: "\(title) needs true or false.") }
          if b, let reason = enablingRefused() { throw MCPConfigError(message: reason) }
          defaults.set(b, forKey: key)
          afterApply(b)
        })
    }

    /// Picker whose stored value is a `Double` raw value (seconds). The catalog speaks the
    /// whole-number token; `apply` writes `rawValue` under `key`, the same encoding as the UI.
    func doubleEnumSetting<T: RawRepresentable & CaseIterable>(
      id: String, title: String, category: String, key: String,
      defaultValue: T, label: @escaping (T) -> String
    ) -> MCPSetting where T.RawValue == Double {
      let cases = Array(T.allCases)
      return enumSetting(
        id: id, title: title, category: category,
        allOptions: { cases.map { MCPSetting.Option(Self.wholeNumberToken($0.rawValue), label($0)) } },
        current: {
          if defaults.object(forKey: key) != nil {
            let raw = defaults.double(forKey: key)
            if let match = cases.first(where: { $0.rawValue == raw }) {
              return Self.wholeNumberToken(match.rawValue)
            }
          }
          return Self.wholeNumberToken(defaultValue.rawValue)
        },
        applyValue: { token in
          guard let match = cases.first(where: { Self.wholeNumberToken($0.rawValue) == token }) else {
            throw MCPConfigError(message: "Unknown value for \(title).")
          }
          defaults.set(match.rawValue, forKey: key)
        })
    }

    func enumSetting<T: RawRepresentable>(
      id: String, title: String, category: String, allOptions: @escaping () -> [MCPSetting.Option],
      current: @escaping () -> T, applyValue: @escaping (T) throws -> Void
    ) -> MCPSetting where T.RawValue == String {
      MCPSetting(
        id: id, title: title, category: category, kind: .enumeration(options: allOptions),
        read: { current().rawValue },
        validate: { value in
          guard let raw = value as? String, let typed = T(rawValue: raw) else {
            return "\(title) must be one of: \(allOptions().map(\.value).joined(separator: ", "))."
          }
          if let option = allOptions().first(where: { $0.value == raw }), !option.available {
            return "\(option.label)\(option.reason.map { " (\($0))" } ?? "") is not available yet."
          }
          _ = typed
          return nil
        },
        apply: { value in
          guard let raw = value as? String, let typed = T(rawValue: raw) else {
            throw MCPConfigError(message: "Unknown value for \(title).")
          }
          try applyValue(typed)
        })
    }

    /// Same shape as the typed helper, for enumerations whose stored value is not a `String` raw
    /// value (`ReadAloudSpeed` is a Double; voice ids are free-form, including `""` for the
    /// provider default). The catalog value is still the option string.
    func enumSetting(
      id: String, title: String, category: String, allOptions: @escaping () -> [MCPSetting.Option],
      current: @escaping () -> String, applyValue: @escaping (String) throws -> Void
    ) -> MCPSetting {
      MCPSetting(
        id: id, title: title, category: category, kind: .enumeration(options: allOptions),
        read: current,
        validate: { value in
          guard let raw = value as? String, let option = allOptions().first(where: { $0.value == raw }) else {
            return "\(title) must be one of: \(allOptions().map(\.value).joined(separator: ", "))."
          }
          if !option.available {
            return "\(option.label)\(option.reason.map { " (\($0))" } ?? "") is not available yet."
          }
          return nil
        },
        apply: { value in
          guard let raw = value as? String else { throw MCPConfigError(message: "Unknown value for \(title).") }
          try applyValue(raw)
        })
    }

    func readAloudSpeedToken(_ speed: ReadAloudSpeed) -> String {
      switch speed {
      case .x075: return "0.75"
      case .x100: return "1.0"
      case .x125: return "1.25"
      case .x150: return "1.5"
      case .x175: return "1.75"
      case .x200: return "2.0"
      }
    }

    /// `true` only for a local MLX model whose weights are not yet on disk. The MCP surface must
    /// never trigger a multi-GB background download by picking an option —
    /// `PromptModel.hasRequiredCredential` is `true` for every local model whether or not it's
    /// downloaded (the Settings picker, via `.promptModelChanged` → `MenuBarController`, is the
    /// thing allowed to kick off that download; `update_settings` is not).
    func needsLocalModelDownload(_ model: PromptModel) -> Bool {
      guard let type = model.localMLXModelType else { return false }
      return MLXModelPaths.localDirectory(for: type) == nil
    }

    let notDownloadedReason = "Not downloaded. Download it in Settings first."

    /// `hasCredential`, additionally refusing a local MLX model that isn't downloaded yet.
    func availableNow(_ model: PromptModel, hasCredential: (PromptModel) -> Bool) -> Bool {
      hasCredential(model) && !needsLocalModelDownload(model)
    }

    func promptModelSetting(
      id: String, title: String, key: String, fallback: PromptModel,
      models: @escaping () -> [PromptModel],
      hasCredential: @escaping (PromptModel) -> Bool,
      // `meetings.summary_model` / `improvement.model` resolve their stored raw value the same
      // way `PromptModel.loadChatSlotModel` does (legacy raw-value migration, in-enum deprecation
      // mapping, chat-model supersession) so a valid stored value isn't misreported as the
      // fallback — see `PromptModel.resolvedChatSlotModel(forRawValue:)`, which does this WITHOUT
      // touching UserDefaults, unlike the real loader (which hardcodes `.standard`).
      // `dictate_prompt.model` keeps the plain lookup: it also accepts audio-only models the
      // chat-slot resolver's `supportsTextChat` filter would drop.
      resolveStoredRawValueAsChatSlot: Bool = false,
      // Only `dictate_prompt.model`'s own picker (`SpeechToPromptSettingsTab`) posts
      // `.promptModelChanged` on save; the Meeting Summary and Smart Improvement pickers don't, so
      // this must not post it there either (even though it is now harmless — the download gate
      // above means `.apply` only ever stores an already-downloaded model).
      postsPromptModelChanged: Bool = true
    ) -> MCPSetting {
      func resolveStored(_ raw: String) -> PromptModel? {
        if resolveStoredRawValueAsChatSlot {
          return PromptModel.resolvedChatSlotModel(forRawValue: raw)
        }
        guard let model = PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(raw)),
          models().contains(model)
        else { return nil }
        return model
      }
      return MCPSetting(
        id: id, title: title, category: "models",
        kind: .enumeration(options: {
          let selected = defaults.string(forKey: key).flatMap(resolveStored) ?? fallback
          return ModelPickerCuration.visibleModels(models(), selected: selected).map { model in
            MCPSetting.Option(
              model.rawValue, model.displayName,
              available: availableNow(model, hasCredential: hasCredential),
              reason: needsLocalModelDownload(model) ? notDownloadedReason : model.pickerSetupBadge)
          }
        }),
        read: {
          (defaults.string(forKey: key).flatMap(resolveStored) ?? fallback).rawValue
        },
        validate: { value in
          guard let raw = value as? String, let model = PromptModel(rawValue: raw), models().contains(model) else {
            return "Unknown \(title)."
          }
          guard hasCredential(model) else {
            return "\(model.displayName) needs a key or setup the user hasn't added yet."
          }
          guard !needsLocalModelDownload(model) else {
            return "\(model.displayName): \(notDownloadedReason)"
          }
          return nil
        },
        apply: { value in
          guard let raw = value as? String, let model = PromptModel(rawValue: raw) else {
            throw MCPConfigError(message: "Unknown \(title).")
          }
          defaults.set(model.rawValue, forKey: key)
          if postsPromptModelChanged { deps.postNotification(.promptModelChanged, model) }
          deps.postSelectionsChanged()
        })
    }

    /// Provider model slug. Same validation as `chat.openrouter_model_id`. `write` is the setter
    /// the Settings section uses (or the same UserDefaults key, when the section writes the key itself).
    func modelIDSetting(
      id: String, title: String, unavailableReason: @escaping () -> String? = { nil },
      read: @escaping () -> String, write: @escaping (String) -> Void
    ) -> MCPSetting {
      MCPSetting(
        id: id, title: title, category: "models", kind: .string(maxLength: 200),
        unavailableReason: unavailableReason,
        read: read,
        validate: { value in
          guard let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.count <= 200 else {
            return "\(title) must be 1–200 characters."
          }
          return nil
        },
        apply: { value in
          guard let s = value as? String else { throw MCPConfigError(message: "Expected a string.") }
          write(s)
        })
    }

    func storedOrDefault(_ key: String, default fallback: String) -> String {
      let v = (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return v.isEmpty ? fallback : v
    }

    var settings: [MCPSetting] = []

    // MARK: dictation.transcription_model
    // Uses `TranscriptionModel.selectableForDictation` (not `allCases`), same as
    // `meetings.transcription_model` below, so Offline Mode and non-dictation models are
    // respected. Reads through the injected `defaults` with the same migration helper the real
    // loader (`TranscriptionModel.loadSelected()`, which hardcodes `.standard` and has
    // write-side-effects the catalog's `read` must not have) uses.
    settings.append(MCPSetting(
      id: "dictation.transcription_model", title: "Dictation model", category: "models",
      kind: .enumeration(options: {
        let migrated = TranscriptionModel.migrateLegacyTranscriptionRawValue(
          defaults.string(forKey: UserDefaultsKeys.selectedTranscriptionModel) ?? "")
        let selected = TranscriptionModel(rawValue: migrated) ?? SettingsDefaults.selectedTranscriptionModel
        return ModelPickerCuration.visibleModels(TranscriptionModel.selectableForDictation, selected: selected).map {
          MCPSetting.Option(
            $0.rawValue, $0.displayName, available: $0.hasRequiredCredential,
            reason: $0.pickerSetupBadge)
        }
      }),
      read: {
        guard let raw = defaults.string(forKey: UserDefaultsKeys.selectedTranscriptionModel) else {
          return SettingsDefaults.selectedTranscriptionModel.rawValue
        }
        let migrated = TranscriptionModel.migrateLegacyTranscriptionRawValue(raw)
        return TranscriptionModel(rawValue: migrated)?.rawValue ?? SettingsDefaults.selectedTranscriptionModel.rawValue
      },
      validate: { value in
        guard let raw = value as? String, let model = TranscriptionModel(rawValue: raw),
          TranscriptionModel.selectableForDictation.contains(model)
        else { return "Unknown transcription model." }
        return model.hasRequiredCredential ? nil : "\(model.displayName) needs a key or setup the user hasn't added yet."
      },
      apply: { value in
        guard let raw = value as? String, let model = TranscriptionModel(rawValue: raw) else {
          throw MCPConfigError(message: "Unknown transcription model.")
        }
        defaults.set(model.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModel)
        deps.postNotification(.modelChanged, model)
        deps.postSelectionsChanged()
      }))

    // MARK: chat.model
    // `read` resolves the stored raw value the same way `PromptModel.loadChatSlotModel` does
    // (legacy raw-value migration, deprecation mapping, chat-model supersession), so a valid
    // stored value isn't misreported as the fallback. `available`/`reason` refuse a local MLX
    // model that isn't downloaded yet — picking one here must never trigger a background download.
    settings.append(MCPSetting(
      id: "chat.model", title: "Chat model", category: "models",
      kind: .enumeration(options: {
        PromptModel.chatModels.map {
          MCPSetting.Option(
            $0.rawValue, $0.displayName,
            available: availableNow($0, hasCredential: { $0.hasRequiredCredential }),
            reason: needsLocalModelDownload($0) ? notDownloadedReason : $0.pickerSetupBadge)
        }
      }),
      read: {
        guard let raw = defaults.string(forKey: UserDefaultsKeys.selectedChatModel) else {
          return SettingsDefaults.selectedChatModel.rawValue
        }
        return (PromptModel.resolvedChatSlotModel(forRawValue: raw) ?? SettingsDefaults.selectedChatModel).rawValue
      },
      validate: { value in
        guard let raw = value as? String, let model = PromptModel(rawValue: raw), PromptModel.chatModels.contains(model) else {
          return "Unknown chat model."
        }
        guard model.hasRequiredCredential else {
          return "\(model.displayName) needs a key the user hasn't added yet."
        }
        guard !needsLocalModelDownload(model) else {
          return "\(model.displayName): \(notDownloadedReason)"
        }
        return nil
      },
      apply: { value in
        guard let raw = value as? String, let model = PromptModel(rawValue: raw) else {
          throw MCPConfigError(message: "Unknown chat model.")
        }
        ChatViewModel.persistChatModelSelection(model, defaults: defaults)
        // Matches ChatView's own picker, which posts this on selection.
        deps.postNotification(.promptModelChanged, model)
        deps.postSelectionsChanged()
      }))

    // MARK: chat.openrouter_model_id
    settings.append(MCPSetting(
      id: "chat.openrouter_model_id", title: "OpenRouter chat model id", category: "models", kind: .string(maxLength: 200),
      read: { OpenRouterChatPreferences.modelID(defaults: defaults) },
      validate: { value in
        guard let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.count <= 200 else {
          return "OpenRouter model id must be 1–200 characters."
        }
        return nil
      },
      apply: { value in
        guard let s = value as? String else { throw MCPConfigError(message: "Expected a string.") }
        OpenRouterChatPreferences.setModelID(s, defaults: defaults)
      }))

    // MARK: meetings.transcription_model
    // JSON null clears the key. `TranscriptionModel.loadSelectedForMeeting()` treats a missing key
    // as "same as dictation" — that is the fallback the Settings loader already uses.
    settings.append(MCPSetting(
      id: "meetings.transcription_model", title: "Meeting transcription model", category: "models",
      kind: .enumeration(options: {
        let selected = defaults.string(forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings)
          .flatMap { TranscriptionModel(rawValue: TranscriptionModel.migrateLegacyTranscriptionRawValue($0)) }
          ?? SettingsDefaults.selectedTranscriptionModel
        return ModelPickerCuration.visibleModels(TranscriptionModel.selectableForDictation, selected: selected).map {
          MCPSetting.Option(
            $0.rawValue, $0.displayName, available: $0.hasRequiredCredential,
            reason: $0.pickerSetupBadge)
        }
      }),
      read: {
        guard let raw = defaults.string(forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings) else {
          return NSNull()
        }
        let migrated = TranscriptionModel.migrateLegacyTranscriptionRawValue(raw)
        guard let model = TranscriptionModel(rawValue: migrated) else { return NSNull() }
        return model.rawValue
      },
      validate: { value in
        if value is NSNull { return nil }
        guard let raw = value as? String, let model = TranscriptionModel(rawValue: raw),
          TranscriptionModel.selectableForDictation.contains(model)
        else { return "Unknown transcription model." }
        return model.hasRequiredCredential ? nil : "\(model.displayName) needs a key or setup the user hasn't added yet."
      },
      apply: { value in
        if value is NSNull {
          defaults.removeObject(forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings)
          deps.postSelectionsChanged()
          return
        }
        guard let raw = value as? String, let model = TranscriptionModel(rawValue: raw) else {
          throw MCPConfigError(message: "Unknown transcription model.")
        }
        defaults.set(model.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings)
        deps.postSelectionsChanged()
      }))

    // MARK: dictate_prompt.model
    settings.append(promptModelSetting(
      id: "dictate_prompt.model", title: "Dictate Prompt model",
      key: UserDefaultsKeys.selectedPromptModel, fallback: SettingsDefaults.selectedPromptModel,
      models: { PromptModel.dictatePromptCapableModels },
      hasCredential: { $0.hasRequiredCredentialForDictatePrompt }))

    // MARK: meetings.summary_model
    // Settings → Meetings' own picker (`MeetingsSettingsTab`) writes through `SettingsViewModel`'s
    // save flow, which does not post `.promptModelChanged` — so this entry must not either.
    settings.append(promptModelSetting(
      id: "meetings.summary_model", title: "Meeting summary model",
      key: UserDefaultsKeys.selectedMeetingSummaryModel, fallback: SettingsDefaults.selectedMeetingSummaryModel,
      models: { PromptModel.textChatModels },
      hasCredential: { $0.hasRequiredCredential },
      resolveStoredRawValueAsChatSlot: true, postsPromptModelChanged: false))

    // MARK: improvement.model
    // Same reasoning as `meetings.summary_model`: `ImprovementSettingsTab`'s picker doesn't post
    // `.promptModelChanged` either.
    settings.append(promptModelSetting(
      id: "improvement.model", title: "Smart Improvement model",
      key: UserDefaultsKeys.selectedImprovementModel, fallback: SettingsDefaults.selectedImprovementModel,
      models: { PromptModel.textChatModels },
      hasCredential: { $0.hasRequiredCredential },
      resolveStoredRawValueAsChatSlot: true, postsPromptModelChanged: false))

    // MARK: read_aloud.model
    settings.append(MCPSetting(
      id: "read_aloud.model", title: "Read Aloud model", category: "models",
      kind: .enumeration(options: {
        let selected = defaults.string(forKey: UserDefaultsKeys.selectedReadAloudModel)
          .flatMap { TTSModel(rawValue: TTSModel.migrateLegacyReadAloudRawValue($0)) }
          ?? SettingsDefaults.readAloudModel
        return ModelPickerCuration.visibleModels(TTSModel.readAloudModels, selected: selected).map {
          MCPSetting.Option(
            $0.rawValue, $0.displayName, available: $0.hasRequiredCredential,
            reason: $0.pickerSetupBadge)
        }
      }),
      read: {
        let raw = defaults.string(forKey: UserDefaultsKeys.selectedReadAloudModel)
        let migrated = raw.map { TTSModel.migrateLegacyReadAloudRawValue($0) }
        if let migrated, let model = TTSModel(rawValue: migrated), TTSModel.readAloudModels.contains(model) {
          return model.rawValue
        }
        return SettingsDefaults.readAloudModel.rawValue
      },
      validate: { value in
        guard let raw = value as? String, let model = TTSModel(rawValue: raw), TTSModel.readAloudModels.contains(model) else {
          return "Unknown Read Aloud model."
        }
        return model.hasRequiredCredential ? nil : "\(model.displayName) needs a key or setup the user hasn't added yet."
      },
      apply: { value in
        guard let raw = value as? String, let model = TTSModel(rawValue: raw) else {
          throw MCPConfigError(message: "Unknown Read Aloud model.")
        }
        defaults.set(model.rawValue, forKey: UserDefaultsKeys.selectedReadAloudModel)
        deps.postSelectionsChanged()
      }))

    // MARK: chat.chatgpt_plan_model_id
    settings.append(modelIDSetting(
      id: "chat.chatgpt_plan_model_id", title: "ChatGPT plan model id",
      unavailableReason: {
        #if APP_STORE
          return "direct-download build only"
        #else
          return ChatGPTPlanPreferences.isConfigured ? nil : "needs ChatGPT sign-in"
        #endif
      },
      read: { ChatGPTPlanPreferences.modelID(defaults: defaults) },
      write: { ChatGPTPlanPreferences.setModelID($0, defaults: defaults) }))

    // MARK: chat.custom_endpoint_model_id
    settings.append(modelIDSetting(
      id: "chat.custom_endpoint_model_id", title: "Custom endpoint model id",
      read: { storedOrDefault(UserDefaultsKeys.customOpenAIChatModelID, default: SettingsDefaults.customOpenAIChatModelID) },
      write: { defaults.set($0, forKey: UserDefaultsKeys.customOpenAIChatModelID) }))

    // MARK: dictation.openrouter_model_id
    settings.append(modelIDSetting(
      id: "dictation.openrouter_model_id", title: "OpenRouter dictation model id",
      read: { TranscriptionTuning.resolveOpenRouterModelID(defaults.string(forKey: UserDefaultsKeys.openRouterTranscriptionModelID)) },
      write: { defaults.set($0, forKey: UserDefaultsKeys.openRouterTranscriptionModelID) }))

    // MARK: dictate_prompt.local_model_id
    settings.append(modelIDSetting(
      id: "dictate_prompt.local_model_id", title: "Local Dictate Prompt model id",
      read: { storedOrDefault(UserDefaultsKeys.localPromptModelID, default: SettingsDefaults.localModelID) },
      write: { defaults.set($0, forKey: UserDefaultsKeys.localPromptModelID) }))

    // MARK: dictation.language
    settings.append(enumSetting(
      id: "dictation.language", title: "Dictation language", category: "dictation",
      allOptions: { WhisperLanguage.allCases.map { MCPSetting.Option($0.rawValue, $0.rawValue) } },
      current: {
        defaults.string(forKey: UserDefaultsKeys.whisperLanguage).flatMap(WhisperLanguage.init(rawValue:))
          ?? SettingsDefaults.whisperLanguage
      },
      applyValue: { (lang: WhisperLanguage) in defaults.set(lang.rawValue, forKey: UserDefaultsKeys.whisperLanguage) }))

    // MARK: dictation.temperature
    settings.append(enumSetting(
      id: "dictation.temperature", title: "Temperature", category: "dictation",
      allOptions: { TranscriptionTemperature.allCases.map { MCPSetting.Option($0.rawValue, $0.displayName) } },
      current: {
        defaults.string(forKey: UserDefaultsKeys.transcriptionTemperature)
          .flatMap(TranscriptionTemperature.init(rawValue:)) ?? SettingsDefaults.transcriptionTemperature
      },
      applyValue: { (temperature: TranscriptionTemperature) in
        defaults.set(temperature.rawValue, forKey: UserDefaultsKeys.transcriptionTemperature)
      }))

    // MARK: dictation.thinking_effort
    settings.append(enumSetting(
      id: "dictation.thinking_effort", title: "Thinking effort", category: "dictation",
      allOptions: { TranscriptionThinkingEffort.allCases.map { MCPSetting.Option($0.rawValue, $0.displayName) } },
      current: {
        defaults.string(forKey: UserDefaultsKeys.transcriptionThinkingEffort)
          .flatMap(TranscriptionThinkingEffort.init(rawValue:)) ?? SettingsDefaults.transcriptionThinkingEffort
      },
      applyValue: { (effort: TranscriptionThinkingEffort) in
        defaults.set(effort.rawValue, forKey: UserDefaultsKeys.transcriptionThinkingEffort)
      }))

    // MARK: shortcuts.* — one slot of ShortcutConfig. `slot` is the name
    // `ShortcutValidation.conflictingSlot(excluding:)` uses, so a binding already taken by
    // another row is refused with that row's name. null disables the slot without changing its key.
    func directDownloadOnly() -> String? {
      #if APP_STORE
      return "Direct-download build only."
      #else
      return nil
      #endif
    }

    func shortcutSetting(
      id: String, title: String, slot: String,
      keyPath: WritableKeyPath<ShortcutConfig, ShortcutDefinition>,
      unavailableReason: @escaping () -> String? = { nil }
    ) -> MCPSetting {
      MCPSetting(
        id: id, title: title, category: "shortcuts", kind: .shortcut,
        unavailableReason: unavailableReason,
        read: {
          let def = deps.loadShortcutConfig()[keyPath: keyPath]
          return def.isEnabled ? json(of: def) : NSNull()
        },
        validate: { value in
          if value is NSNull { return nil }
          guard let dict = value as? [String: Any], let def = shortcutDefinition(from: dict) else {
            return "\(Self.shortcutFormatHint)"
          }
          if let problem = ShortcutValidation.modifierRuleViolation(key: def.key, modifiers: def.modifiers) {
            return problem
          }
          if let conflict = ShortcutValidation.conflictingSlot(
            key: def.key, modifiers: def.modifiers, in: deps.loadShortcutConfig(), excluding: slot)
          {
            return "That shortcut is already used by \(conflict)."
          }
          return nil
        },
        apply: { value in
          var config = deps.loadShortcutConfig()
          if value is NSNull {
            let current = config[keyPath: keyPath]
            config[keyPath: keyPath] = ShortcutDefinition(
              key: current.key, modifiers: current.modifiers, isEnabled: false)
          } else {
            guard let dict = value as? [String: Any], let def = shortcutDefinition(from: dict) else {
              throw MCPConfigError(message: "\(Self.shortcutFormatHint)")
            }
            config[keyPath: keyPath] = def
          }
          deps.saveShortcutConfig(config)
        })
    }

    settings.append(shortcutSetting(
      id: "shortcuts.dictate", title: "Toggle Dictation shortcut", slot: "Toggle Dictation",
      keyPath: \.startRecording))
    settings.append(shortcutSetting(
      id: "shortcuts.dictate_prompt", title: "Toggle Dictate Prompt shortcut", slot: "Toggle Dictate Prompt",
      keyPath: \.startPrompting))
    settings.append(shortcutSetting(
      id: "shortcuts.screenshot", title: "Screenshot shortcut", slot: "Screenshot",
      keyPath: \.screenshotCapture))
    // Selection-based shortcuts (they copy via ⌘C). Hidden in Settings on the App Store build.
    settings.append(shortcutSetting(
      id: "shortcuts.read_aloud", title: "Read Aloud shortcut", slot: "Read Aloud",
      keyPath: \.readAloud, unavailableReason: directDownloadOnly))
    settings.append(shortcutSetting(
      id: "shortcuts.add_to_glossary", title: "Add to Glossary shortcut", slot: "Add to Glossary",
      keyPath: \.addToGlossary, unavailableReason: directDownloadOnly))
    settings.append(shortcutSetting(
      id: "shortcuts.open_chat", title: "Open Chat shortcut", slot: "Open Chat",
      keyPath: \.openChat))
    settings.append(shortcutSetting(
      id: "shortcuts.open_settings", title: "Open Settings shortcut", slot: "Open Settings",
      keyPath: \.openSettings))

    // MARK: notifications.enabled
    settings.append(boolSetting(
      id: "notifications.enabled", title: "Show dictation notifications", category: "notifications",
      key: UserDefaultsKeys.showPopupNotifications, defaultValue: SettingsDefaults.showPopupNotifications))

    // MARK: notifications.position
    settings.append(enumSetting(
      id: "notifications.position", title: "Notification position", category: "notifications",
      allOptions: { NotificationPosition.allCases.map { MCPSetting.Option($0.rawValue, $0.displayName) } },
      current: {
        defaults.string(forKey: UserDefaultsKeys.notificationPosition).flatMap(NotificationPosition.init(rawValue:))
          ?? SettingsDefaults.notificationPosition
      },
      applyValue: { (pos: NotificationPosition) in defaults.set(pos.rawValue, forKey: UserDefaultsKeys.notificationPosition) }))

    // MARK: notifications.duration — picker stores the Double raw value (seconds).
    settings.append(doubleEnumSetting(
      id: "notifications.duration", title: "Notification duration", category: "notifications",
      key: UserDefaultsKeys.notificationDuration, defaultValue: SettingsDefaults.notificationDuration,
      label: { $0.isRecommended ? "\($0.displayName) (Recommended)" : $0.displayName }))

    // MARK: clipboard.auto_paste — never prompts; stays visible and can always be turned OFF.
    // `enablingRefused`, not `unavailableReason`, so an AI app can still see and disable this
    // without Accessibility — matching `dictate_prompt.screenshot_context`'s pattern below.
    settings.append(boolSetting(
      id: "clipboard.auto_paste", title: "Auto-paste after dictation", category: "clipboard",
      key: UserDefaultsKeys.autoPasteAfterDictation, defaultValue: SettingsDefaults.autoPasteAfterDictation,
      enablingRefused: {
        deps.hasAccessibilityPermission() ? nil : "Needs the Accessibility permission, which the user has to grant themselves."
      }))

    // MARK: clipboard.restore_after_paste
    settings.append(boolSetting(
      id: "clipboard.restore_after_paste", title: "Restore clipboard after auto-paste", category: "clipboard",
      key: UserDefaultsKeys.restoreClipboardAfterPaste, defaultValue: SettingsDefaults.restoreClipboardAfterPaste))

    // MARK: dictation.fn_key — direct-download build only (hidden in Settings on the App Store
    // build, `KeyboardShortcutsSection`'s `#if !APP_STORE`); same Accessibility gate as
    // `clipboard.auto_paste`, via `enablingRefused` so OFF always stays reachable.
    settings.append(boolSetting(
      id: "dictation.fn_key", title: "Hold fn to dictate", category: "dictation",
      key: UserDefaultsKeys.fnKeyDictation, defaultValue: SettingsDefaults.fnKeyDictation,
      unavailableReason: {
        #if APP_STORE
          return "Direct-download build only."
        #else
          return nil
        #endif
      },
      enablingRefused: {
        deps.hasAccessibilityPermission() ? nil : "Needs the Accessibility permission, which the user has to grant themselves."
      }))

    // MARK: window.settings_close_on_focus_loss
    settings.append(boolSetting(
      id: "window.settings_close_on_focus_loss", title: "Close Settings when it loses focus", category: "window",
      key: UserDefaultsKeys.settingsCloseOnFocusLoss, defaultValue: SettingsDefaults.settingsCloseOnFocusLoss))

    // MARK: chat.close_on_focus_loss
    settings.append(boolSetting(
      id: "chat.close_on_focus_loss", title: "Close Chat when clicking outside", category: "chat",
      key: UserDefaultsKeys.chatCloseOnFocusLoss, defaultValue: SettingsDefaults.chatCloseOnFocusLoss))

    // MARK: read_aloud.smart_rewrite
    settings.append(boolSetting(
      id: "read_aloud.smart_rewrite", title: "Read Aloud smart rewrite", category: "read_aloud",
      key: UserDefaultsKeys.readAloudSmartRewriteEnabled, defaultValue: SettingsDefaults.readAloudSmartRewriteEnabled))

    // MARK: read_aloud.speed
    // The picker stores `ReadAloudSpeed.rawValue` (a Double). The catalog speaks the string token.
    settings.append(enumSetting(
      id: "read_aloud.speed", title: "Playback speed", category: "read_aloud",
      allOptions: { ReadAloudSpeed.allCases.map { MCPSetting.Option(readAloudSpeedToken($0), $0.displayName) } },
      current: {
        guard defaults.object(forKey: UserDefaultsKeys.readAloudSpeed) != nil,
          let speed = ReadAloudSpeed(rawValue: defaults.double(forKey: UserDefaultsKeys.readAloudSpeed))
        else { return readAloudSpeedToken(SettingsDefaults.readAloudSpeed) }
        return readAloudSpeedToken(speed)
      },
      applyValue: { token in
        guard let speed = ReadAloudSpeed.allCases.first(where: { readAloudSpeedToken($0) == token }) else {
          throw MCPConfigError(message: "Unknown playback speed.")
        }
        defaults.set(speed.rawValue, forKey: UserDefaultsKeys.readAloudSpeed)
      }))

    // MARK: read_aloud.voice.*
    // `""` is the provider default, the same sentinel `SettingsSlot.string` persists.
    func voiceSetting(id: String, title: String, provider: TTSProvider) {
      let key = provider.voiceUserDefaultsKey
      settings.append(enumSetting(
        id: id, title: title, category: "read_aloud",
        allOptions: {
          [MCPSetting.Option("", "Provider default")]
            + provider.voices.map { MCPSetting.Option($0.id, $0.displayName) }
        },
        current: { defaults.string(forKey: key) ?? "" },
        applyValue: { raw in defaults.set(raw, forKey: key) }))
    }
    voiceSetting(id: "read_aloud.voice.gemini", title: "Gemini voice", provider: .gemini)
    voiceSetting(id: "read_aloud.voice.openai", title: "OpenAI voice", provider: .openai)
    voiceSetting(id: "read_aloud.voice.xai", title: "xAI voice", provider: .xai)
    voiceSetting(id: "read_aloud.voice.system", title: "macOS voice", provider: .system)

    // MARK: screenshot.save_enabled — refused turning ON without a folder chosen (MCP never opens
    // the picker); `enablingRefused`, not `unavailableReason`, so the entry stays visible and OFF
    // always stays reachable.
    settings.append(boolSetting(
      id: "screenshot.save_enabled", title: "Save dictation screenshots", category: "screenshot",
      key: UserDefaultsKeys.screenshotSaveEnabled, defaultValue: SettingsDefaults.screenshotSaveEnabled,
      enablingRefused: {
        deps.hasScreenshotFolder() ? nil : "No folder is chosen yet; the user has to pick one in WhisperShortcut Settings."
      }))

    // MARK: recording.confirm_above_duration — picker stores the Double raw value (seconds; 0 = never).
    settings.append(doubleEnumSetting(
      id: "recording.confirm_above_duration", title: "Ask when recording longer than", category: "recording",
      key: UserDefaultsKeys.confirmAboveDurationSeconds, defaultValue: SettingsDefaults.confirmAboveDuration,
      label: { $0.isRecommended ? "\($0.displayName) (Recommended)" : $0.displayName }))

    // MARK: meetings.chunk_interval
    settings.append(doubleEnumSetting(
      id: "meetings.chunk_interval", title: "Meeting chunk interval", category: "meetings",
      key: UserDefaultsKeys.liveMeetingChunkInterval, defaultValue: SettingsDefaults.liveMeetingChunkInterval,
      label: { $0.displayName }))

    // MARK: meetings.safeguard_duration
    settings.append(doubleEnumSetting(
      id: "meetings.safeguard_duration", title: "Ask when meeting longer than", category: "meetings",
      key: UserDefaultsKeys.liveMeetingSafeguardDurationSeconds,
      defaultValue: SettingsDefaults.liveMeetingSafeguardDuration,
      label: { $0.displayName }))

    // MARK: dictate_prompt.screenshot_context — on needs Screen Recording already granted.
    // The Settings toggle prompts via SCShareableContent; MCP only reads the injected check.
    settings.append(boolSetting(
      id: "dictate_prompt.screenshot_context", title: "Screenshot context", category: "dictate_prompt",
      key: UserDefaultsKeys.screenshotInPromptMode, defaultValue: SettingsDefaults.screenshotInPromptMode,
      enablingRefused: {
        deps.hasScreenRecordingPermission()
          ? nil
          : "Grant Screen Recording in Settings → Permissions first."
      }))

    // MARK: chat.x_search_handles — same bytes `XSearchHandles.defaultHandles`'s setter writes:
    // normalized, lowercased, capped, space-joined. Empty means search all of X.
    settings.append(MCPSetting(
      id: "chat.x_search_handles", title: "X accounts for Grok", category: "chat",
      kind: .string(maxLength: 2000),
      read: {
        XSearchHandles.normalize(defaults.string(forKey: UserDefaultsKeys.grokXSearchHandles) ?? "")
          .joined(separator: " ")
      },
      validate: { value in
        guard let s = value as? String, s.count <= 2000 else {
          return "X accounts must be at most 2000 characters."
        }
        return nil
      },
      apply: { value in
        guard let s = value as? String else { throw MCPConfigError(message: "Expected a string.") }
        let stored = XSearchHandles.normalize(s).joined(separator: " ")
        defaults.set(stored, forKey: UserDefaultsKeys.grokXSearchHandles)
      },
      // The proposal/change-log `toLabel` must show what will actually be stored (normalized),
      // not the AI's raw input verbatim.
      normalizeForLabel: { value in
        guard let s = value as? String else { return value }
        return XSearchHandles.normalize(s).joined(separator: " ")
      }))

    // MARK: improvement.auto_run_interval — picker stores the Int raw value (days; 0 = off).
    settings.append(enumSetting(
      id: "improvement.auto_run_interval", title: "Run Improve from usage automatically",
      category: "improvement",
      allOptions: {
        ImproveFromUsageAutoRunInterval.allCases.map { MCPSetting.Option(String($0.rawValue), $0.displayName) }
      },
      current: {
        let interval: ImproveFromUsageAutoRunInterval
        if defaults.object(forKey: UserDefaultsKeys.improveFromUsageAutoRunInterval) != nil,
          let parsed = ImproveFromUsageAutoRunInterval(
            rawValue: defaults.integer(forKey: UserDefaultsKeys.improveFromUsageAutoRunInterval))
        {
          interval = parsed
        } else {
          // Same default as the Settings `@AppStorage` and `checkAndRunIfDue` when the key is unset.
          interval = .every7Days
        }
        return String(interval.rawValue)
      },
      applyValue: { raw in
        guard let value = Int(raw), let interval = ImproveFromUsageAutoRunInterval(rawValue: value) else {
          throw MCPConfigError(message: "Unknown auto-run interval.")
        }
        defaults.set(interval.rawValue, forKey: UserDefaultsKeys.improveFromUsageAutoRunInterval)
        deps.checkImprovementAutoRun()
      }))

    // MARK: general.launch_at_login — always a proposal: a background-login change the user should see coming.
    settings.append(MCPSetting(
      id: "general.launch_at_login", title: "Launch at login", category: "general", kind: .bool, proposalOnly: true,
      read: { deps.isLaunchAtLoginEnabled() },
      validate: { value in value is Bool ? nil : "Launch at login needs true or false." },
      apply: { value in
        guard let b = value as? Bool else { throw MCPConfigError(message: "Launch at login needs true or false.") }
        try deps.setLaunchAtLogin(b)
      }))

    // MARK: writing_style.enabled — always a proposal: turning it on imports sent mail.
    settings.append(boolSetting(
      id: "writing_style.enabled", title: "Use my writing style in Dictate Prompt",
      category: "writing_style", key: UserDefaultsKeys.writingStyleEnabled, defaultValue: false,
      proposalOnly: true,
      afterApply: { WritingStyleSettingsSection.handleToggle(enabled: $0) }))

    // MARK: dictate_prompt.tools_enabled — always a proposal: lookups are sent to the model.
    settings.append(boolSetting(
      id: "dictate_prompt.tools_enabled", title: "Let Dictate Prompt use read-only tools",
      category: "dictate_prompt", key: UserDefaultsKeys.dictatePromptToolsEnabled, defaultValue: true,
      proposalOnly: true))

    // MARK: chat.claude_web_search — always a proposal: Anthropic bills each search.
    settings.append(boolSetting(
      id: "chat.claude_web_search", title: "Let Claude search the web",
      category: "chat", key: UserDefaultsKeys.claudeWebSearchEnabled, defaultValue: true,
      proposalOnly: true))

    return settings
  }
}

// MARK: - Settings batch apply/undo (the single apply path for `update_settings` and an accepted
// settings proposal; mirrors `MCPConfigApplier`'s other `apply*` methods).

extension MCPConfigApplier {
  /// All-or-nothing: validates every item against the state the WHOLE batch would leave (not
  /// just today's on-disk state, which can't see two items in the same batch claiming the same
  /// combo — see `MCPSettingsCatalog.validateBatch`), applies them in order, and records one
  /// change-log entry only once every item has succeeded. If an `apply` throws partway through,
  /// everything already applied in this batch is rolled back (reverse order, by replaying each
  /// item's `from` value through `apply`) before the failure is returned — a batch must never
  /// leave earlier items written, unlogged, with no `.settingsChangedExternally` for a failure
  /// further down. The accepted-proposal path (`MCPProposalStore.accept`) calls this same
  /// function, so both ways into a settings change go through one all-or-nothing apply.
  func applySettingsBatch(
    catalog: [MCPSetting], items: [MCPSettingsChangeItem], rationale: String, viaProposal: Bool
  ) -> Result<String, Error> {
    MCPMain.run {
      var decoded: [(id: String, value: Any)] = []
      for item in items {
        guard let value = MCPSettingsCatalog.decodeValue(item.toJSON) else {
          return .failure(MCPConfigError(message: "Could not read the new value for \(item.id)."))
        }
        decoded.append((item.id, value))
      }
      if let problem = MCPSettingsCatalog.validateBatch(catalog: catalog, items: decoded) {
        return .failure(MCPConfigError(message: problem))
      }

      var applied: [MCPSettingsChangeItem] = []
      for item in items {
        guard let setting = catalog.first(where: { $0.id == item.id }) else {
          return .failure(MCPConfigError(message: "Unknown setting: \(item.id)."))
        }
        guard let value = MCPSettingsCatalog.decodeValue(item.toJSON) else {
          return .failure(MCPConfigError(message: "Could not read the new value for \(item.id)."))
        }
        do {
          try setting.apply(value)
        } catch {
          for rollback in applied.reversed() {
            guard let rollbackSetting = catalog.first(where: { $0.id == rollback.id }),
              let fromValue = MCPSettingsCatalog.decodeValue(rollback.fromJSON)
            else { continue }
            try? rollbackSetting.apply(fromValue)
          }
          return .failure(error)
        }
        applied.append(item)
      }
      let change = changeLog.recordSettings(items: applied, rationale: rationale, viaProposal: viaProposal)
      // One post per batch, whether this came from a direct `update_settings` apply or an
      // accepted settings proposal — every open Settings window reloads the same way either time.
      NotificationCenter.default.post(name: .settingsChangedExternally, object: nil)
      return .success(change.id)
    }
  }
}

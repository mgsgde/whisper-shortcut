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
  /// macOS routes Shift+<printable> to text input, so Carbon never fires those bindings).
  static func modifierRuleViolation(key: Key, modifiers: NSEvent.ModifierFlags) -> String? {
    if functionKeys.contains(key) { return nil }
    let commandModifiers = modifiers.intersection([.command, .option, .control])
    guard commandModifiers.isEmpty else { return nil }
    if modifiers.isEmpty { return "Add ⌘/⌥/⌃ — or use an F-key (F1–F20) on its own." }
    return "Shift alone won't fire — add ⌘/⌥/⌃."
  }

  /// The slot name already using `key`/`modifiers` in `config`, other than `excluding`; nil = free.
  static func conflictingSlot(
    key: Key, modifiers: NSEvent.ModifierFlags, in config: ShortcutConfig, excluding: String
  ) -> String? {
    let slots: [(name: String, def: ShortcutDefinition)] = [
      ("Toggle Dictation", config.startRecording), ("Toggle Dictate Prompt", config.startPrompting),
      ("Open Settings", config.openSettings), ("Open Chat", config.openChat),
      ("Screenshot", config.screenshotCapture), ("Read Aloud", config.readAloud),
      ("Add to Glossary", config.addToGlossary),
    ]
    for (name, def) in slots where name != excluding && def.isEnabled {
      if def.key == key && def.modifiers == modifiers { return name }
    }
    return nil
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

  init(
    id: String, title: String, category: String, kind: Kind, proposalOnly: Bool = false,
    unavailableReason: @escaping () -> String? = { nil }, read: @escaping () -> Any,
    validate: @escaping (Any) -> String?, apply: @escaping (Any) throws -> Void
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

    static let live = Dependencies()
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
      guard let raw = value as? String else { return "\(value)" }
      return options().first { $0.value == raw }?.label ?? raw
    case .shortcut:
      if value is NSNull { return "Disabled" }
      guard let dict = value as? [String: Any], let def = shortcutDefinition(from: dict) else { return "Disabled" }
      return def.displayStringWithSeparator
    }
  }

  private static func shortcutDefinition(from dict: [String: Any]) -> ShortcutDefinition? {
    guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
    return try? JSONDecoder().decode(ShortcutDefinition.self, from: data)
  }

  private static func json(of definition: ShortcutDefinition) -> Any {
    guard let data = try? JSONEncoder().encode(definition),
      let obj = try? JSONSerialization.jsonObject(with: data)
    else { return NSNull() }
    return obj
  }

  // MARK: - Restore (Undo)

  /// Replays one change-log item's `from` value through the live catalog, used only by
  /// `MCPChangeLog.undo` for a `.settings` batch. Skips (rather than fails the whole undo) an item
  /// whose setting no longer validates — e.g. the model it names lost its credential meanwhile.
  static func restore(catalog: [MCPSetting], id: String, json: String) -> MCPSettingsRestoreOutcome {
    guard let setting = catalog.first(where: { $0.id == id }) else { return .invalid("setting no longer exists") }
    guard setting.unavailableReason() == nil else { return .invalid(setting.unavailableReason() ?? "unavailable") }
    guard let value = decodeValue(json) else { return .invalid("could not read the previous value") }
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
      afterApply: @escaping (Bool) -> Void = { _ in }
    ) -> MCPSetting {
      MCPSetting(
        id: id, title: title, category: category, kind: .bool, proposalOnly: proposalOnly,
        unavailableReason: unavailableReason,
        read: { defaults.object(forKey: key) != nil ? defaults.bool(forKey: key) : defaultValue },
        validate: { value in value is Bool ? nil : "\(title) needs true or false." },
        apply: { value in
          guard let b = value as? Bool else { throw MCPConfigError(message: "\(title) needs true or false.") }
          defaults.set(b, forKey: key)
          afterApply(b)
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

    var settings: [MCPSetting] = []

    // MARK: dictation.transcription_model
    settings.append(MCPSetting(
      id: "dictation.transcription_model", title: "Dictation model", category: "models",
      kind: .enumeration(options: {
        let selected = TranscriptionModel.loadSelected()
        return ModelPickerCuration.visibleModels(TranscriptionModel.allCases, selected: selected).map {
          MCPSetting.Option(
            $0.rawValue, $0.displayName, available: $0.hasRequiredCredential,
            reason: $0.pickerSetupBadge)
        }
      }),
      read: { TranscriptionModel.loadSelected().rawValue },
      validate: { value in
        guard let raw = value as? String, let model = TranscriptionModel(rawValue: raw) else {
          return "Unknown transcription model."
        }
        return model.hasRequiredCredential ? nil : "\(model.displayName) needs a key or setup the user hasn't added yet."
      },
      apply: { value in
        guard let raw = value as? String, let model = TranscriptionModel(rawValue: raw) else {
          throw MCPConfigError(message: "Unknown transcription model.")
        }
        defaults.set(model.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModel)
        deps.postNotification(.modelChanged, model)
      }))

    // MARK: chat.model
    settings.append(MCPSetting(
      id: "chat.model", title: "Chat model", category: "models",
      kind: .enumeration(options: {
        PromptModel.chatModels.map {
          MCPSetting.Option($0.rawValue, $0.displayName, available: $0.hasRequiredCredential, reason: $0.pickerSetupBadge)
        }
      }),
      read: {
        (defaults.string(forKey: UserDefaultsKeys.selectedChatModel)).flatMap(PromptModel.init(rawValue:))?.rawValue
          ?? SettingsDefaults.selectedChatModel.rawValue
      },
      validate: { value in
        guard let raw = value as? String, let model = PromptModel(rawValue: raw), PromptModel.chatModels.contains(model) else {
          return "Unknown chat model."
        }
        return model.hasRequiredCredential ? nil : "\(model.displayName) needs a key the user hasn't added yet."
      },
      apply: { value in
        guard let raw = value as? String, let model = PromptModel(rawValue: raw) else {
          throw MCPConfigError(message: "Unknown chat model.")
        }
        defaults.set(model.rawValue, forKey: UserDefaultsKeys.selectedChatModel)
        deps.postNotification(.promptModelChanged, model)
      }))

    // MARK: chat.openrouter_model_id
    settings.append(MCPSetting(
      id: "chat.openrouter_model_id", title: "OpenRouter chat model id", category: "models", kind: .string(maxLength: 200),
      read: { OpenRouterChatPreferences.modelID },
      validate: { value in
        guard let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.count <= 200 else {
          return "OpenRouter model id must be 1–200 characters."
        }
        return nil
      },
      apply: { value in
        guard let s = value as? String else { throw MCPConfigError(message: "Expected a string.") }
        OpenRouterChatPreferences.setModelID(s)
      }))

    // MARK: dictation.language
    settings.append(enumSetting(
      id: "dictation.language", title: "Dictation language", category: "dictation",
      allOptions: { WhisperLanguage.allCases.map { MCPSetting.Option($0.rawValue, $0.rawValue) } },
      current: {
        defaults.string(forKey: UserDefaultsKeys.whisperLanguage).flatMap(WhisperLanguage.init(rawValue:))
          ?? SettingsDefaults.whisperLanguage
      },
      applyValue: { (lang: WhisperLanguage) in defaults.set(lang.rawValue, forKey: UserDefaultsKeys.whisperLanguage) }))

    // MARK: shortcuts.dictate
    settings.append(MCPSetting(
      id: "shortcuts.dictate", title: "Toggle Dictation shortcut", category: "shortcuts", kind: .shortcut,
      read: {
        let def = deps.loadShortcutConfig().startRecording
        return def.isEnabled ? json(of: def) : NSNull()
      },
      validate: { value in
        if value is NSNull { return nil }
        guard let dict = value as? [String: Any], let def = shortcutDefinition(from: dict) else {
          return "A shortcut needs a key, modifiers and enabled."
        }
        if let problem = ShortcutValidation.modifierRuleViolation(key: def.key, modifiers: def.modifiers) {
          return problem
        }
        if let conflict = ShortcutValidation.conflictingSlot(
          key: def.key, modifiers: def.modifiers, in: deps.loadShortcutConfig(), excluding: "Toggle Dictation")
        {
          return "That shortcut is already used by \(conflict)."
        }
        return nil
      },
      apply: { value in
        var config = deps.loadShortcutConfig()
        if value is NSNull {
          config.startRecording = ShortcutDefinition(
            key: config.startRecording.key, modifiers: config.startRecording.modifiers, isEnabled: false)
        } else {
          guard let dict = value as? [String: Any], let def = shortcutDefinition(from: dict) else {
            throw MCPConfigError(message: "A shortcut needs a key, modifiers and enabled.")
          }
          config.startRecording = def
        }
        deps.saveShortcutConfig(config)
      }))

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

    // MARK: clipboard.auto_paste — never prompts; refused without Accessibility already granted.
    settings.append(boolSetting(
      id: "clipboard.auto_paste", title: "Auto-paste after dictation", category: "clipboard",
      key: UserDefaultsKeys.autoPasteAfterDictation, defaultValue: SettingsDefaults.autoPasteAfterDictation,
      unavailableReason: {
        deps.hasAccessibilityPermission() ? nil : "Needs the Accessibility permission, which the user has to grant themselves."
      }))

    // MARK: dictation.fn_key — same permission gate.
    settings.append(boolSetting(
      id: "dictation.fn_key", title: "Hold fn to dictate", category: "dictation",
      key: UserDefaultsKeys.fnKeyDictation, defaultValue: SettingsDefaults.fnKeyDictation,
      unavailableReason: {
        deps.hasAccessibilityPermission() ? nil : "Needs the Accessibility permission, which the user has to grant themselves."
      }))

    // MARK: window.settings_close_on_focus_loss
    settings.append(boolSetting(
      id: "window.settings_close_on_focus_loss", title: "Close Settings when it loses focus", category: "window",
      key: UserDefaultsKeys.settingsCloseOnFocusLoss, defaultValue: SettingsDefaults.settingsCloseOnFocusLoss))

    // MARK: read_aloud.smart_rewrite
    settings.append(boolSetting(
      id: "read_aloud.smart_rewrite", title: "Read Aloud smart rewrite", category: "read_aloud",
      key: UserDefaultsKeys.readAloudSmartRewriteEnabled, defaultValue: SettingsDefaults.readAloudSmartRewriteEnabled))

    // MARK: screenshot.save_enabled — refused without a folder chosen; MCP never opens the picker.
    settings.append(boolSetting(
      id: "screenshot.save_enabled", title: "Save dictation screenshots", category: "screenshot",
      key: UserDefaultsKeys.screenshotSaveEnabled, defaultValue: SettingsDefaults.screenshotSaveEnabled,
      unavailableReason: {
        deps.hasScreenshotFolder() ? nil : "No folder is chosen yet; the user has to pick one in WhisperShortcut Settings."
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

    return settings
  }
}

// MARK: - Settings batch apply/undo (the single apply path for `update_settings` and an accepted
// settings proposal; mirrors `MCPConfigApplier`'s other `apply*` methods).

extension MCPConfigApplier {
  /// Validates every item against the live catalog, then applies all of them and records one
  /// change-log entry. Fails without writing anything if any item no longer validates (e.g. the
  /// setting's dependency changed between validation at the tool call and this apply).
  func applySettingsBatch(
    catalog: [MCPSetting], items: [MCPSettingsChangeItem], rationale: String, viaProposal: Bool
  ) -> Result<String, Error> {
    MCPMain.run {
      var applied: [MCPSettingsChangeItem] = []
      for item in items {
        guard let setting = catalog.first(where: { $0.id == item.id }) else {
          return .failure(MCPConfigError(message: "Unknown setting: \(item.id)."))
        }
        if let reason = setting.unavailableReason() { return .failure(MCPConfigError(message: reason)) }
        guard let value = MCPSettingsCatalog.decodeValue(item.toJSON) else {
          return .failure(MCPConfigError(message: "Could not read the new value for \(item.id)."))
        }
        if let problem = setting.validate(value) { return .failure(MCPConfigError(message: problem)) }
        do {
          try setting.apply(value)
        } catch {
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

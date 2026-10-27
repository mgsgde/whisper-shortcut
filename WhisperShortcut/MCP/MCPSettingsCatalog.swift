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
    /// After a model selection is written. Tests replace this; the live default is
    /// `ModelSelectionReconciler.postSelectionsChanged` (posts `.modelSelectionsReconciled`
    /// and `.modelChanged` for the dictation slot). Routed through `deps` so a test suite
    /// never posts those notifications into the user's running app.
    var postSelectionsChanged: () -> Void = {
      let post = { MainActor.assumeIsolated { ModelSelectionReconciler.postSelectionsChanged() } }
      if Thread.isMainThread { post() } else { DispatchQueue.main.sync(execute: post) }
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

    func promptModelSetting(
      id: String, title: String, key: String, fallback: PromptModel,
      models: @escaping () -> [PromptModel],
      hasCredential: @escaping (PromptModel) -> Bool
    ) -> MCPSetting {
      MCPSetting(
        id: id, title: title, category: "models",
        kind: .enumeration(options: {
          let selected = defaults.string(forKey: key)
            .flatMap { PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue($0)) } ?? fallback
          return ModelPickerCuration.visibleModels(models(), selected: selected).map { model in
            MCPSetting.Option(
              model.rawValue, model.displayName,
              available: hasCredential(model), reason: model.pickerSetupBadge)
          }
        }),
        read: {
          if let raw = defaults.string(forKey: key),
            let model = PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(raw)),
            models().contains(model)
          {
            return model.rawValue
          }
          return fallback.rawValue
        },
        validate: { value in
          guard let raw = value as? String, let model = PromptModel(rawValue: raw), models().contains(model) else {
            return "Unknown \(title)."
          }
          return hasCredential(model) ? nil : "\(model.displayName) needs a key or setup the user hasn't added yet."
        },
        apply: { value in
          guard let raw = value as? String, let model = PromptModel(rawValue: raw) else {
            throw MCPConfigError(message: "Unknown \(title).")
          }
          defaults.set(model.rawValue, forKey: key)
          deps.postNotification(.promptModelChanged, model)
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
        deps.postSelectionsChanged()
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
        ChatViewModel.persistChatModelSelection(model, defaults: defaults)
        deps.postNotification(.promptModelChanged, model)
        deps.postSelectionsChanged()
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
    settings.append(promptModelSetting(
      id: "meetings.summary_model", title: "Meeting summary model",
      key: UserDefaultsKeys.selectedMeetingSummaryModel, fallback: SettingsDefaults.selectedMeetingSummaryModel,
      models: { PromptModel.textChatModels },
      hasCredential: { $0.hasRequiredCredential }))

    // MARK: improvement.model
    settings.append(promptModelSetting(
      id: "improvement.model", title: "Smart Improvement model",
      key: UserDefaultsKeys.selectedImprovementModel, fallback: SettingsDefaults.selectedImprovementModel,
      models: { PromptModel.textChatModels },
      hasCredential: { $0.hasRequiredCredential }))

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
      read: { ChatGPTPlanPreferences.modelID },
      write: { ChatGPTPlanPreferences.setModelID($0) }))

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
            return "A shortcut needs a key, modifiers and enabled."
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
              throw MCPConfigError(message: "A shortcut needs a key, modifiers and enabled.")
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

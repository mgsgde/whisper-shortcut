import Testing
import Foundation
import AppKit
import HotKey
@testable import WhisperShortcut_AppStore

@Suite("MCP settings catalog and get_settings/update_settings")
struct MCPSettingsCatalogTests {

  private func obj(_ r: MCPToolResult) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any]) ?? [:]
  }

  // MARK: - Catalog correctness

  @Test("Every catalog id is unique")
  func uniqueIds() {
    let env = MCPTestEnv()
    let ids = env.settingsCatalog.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test("Every entry reads without crashing")
  func readsCleanly() {
    let env = MCPTestEnv()
    for setting in env.settingsCatalog {
      _ = setting.read()
    }
  }

  /// Deny-list from the spec's "Never exposed" list (`plans/active/mcp-settings.md`): applying
  /// every catalog entry with a plausible valid value into an isolated defaults suite must never
  /// write any of these keys. Sparkle's is framework-internal, not in `UserDefaultsKeys`.
  private static let deniedKeys: [String] = [
    UserDefaultsKeys.mcpServerEnabled, UserDefaultsKeys.mcpServerPort,
    UserDefaultsKeys.mcpConfigAccessLevel, UserDefaultsKeys.mcpShareRecentInteractions,
    UserDefaultsKeys.offlineModeEnabled, UserDefaultsKeys.contextLoggingEnabled,
    UserDefaultsKeys.customOpenAIChatEndpointURL, UserDefaultsKeys.customTranscriptionAPIURL,
    UserDefaultsKeys.localPromptEndpointURL, UserDefaultsKeys.workspaceFolders,
    UserDefaultsKeys.chatWorkspaceWriteEnabled, UserDefaultsKeys.telemetryEnabled,
    "SUEnableAutomaticChecks",
  ]

  /// A plausible valid value for a setting, used only to probe that applying it never touches a
  /// denied key — not to check the setting's own behaviour.
  private static func sampleValue(for setting: MCPSetting) -> Any? {
    switch setting.kind {
    case .bool: return true
    case .string: return setting.read() as? String ?? ""
    case .enumeration(let options):
      return options().first(where: \.available)?.value ?? options().first?.value
    case .shortcut: return NSNull()
    }
  }

  @Test("No entry's apply ever writes a denied UserDefaults key")
  func noDeniedKeyEverWritten() {
    let env = MCPTestEnv(level: .apply)
    let before = Self.deniedKeys.map { env.testDefaults.object(forKey: $0).map { "\($0)" } }
    for setting in env.settingsCatalog {
      guard setting.unavailableReason() == nil, let value = Self.sampleValue(for: setting) else { continue }
      guard setting.validate(value) == nil else { continue }
      try? setting.apply(value)
    }
    let after = Self.deniedKeys.map { env.testDefaults.object(forKey: $0).map { "\($0)" } }
    #expect(before == after, "a catalog entry wrote a key on the spec's \"Never exposed\" list")
  }

  @Test("An enum setting's current value is one of its own options")
  func currentValueInOptions() {
    let env = MCPTestEnv()
    for setting in env.settingsCatalog {
      guard case .enumeration(let options) = setting.kind else { continue }
      let current = setting.read() as? String
      let values = options().map(\.value)
      #expect(current == nil || values.contains(current!), "\(setting.id) current value not in its options")
    }
  }

  // MARK: - get_settings

  @Test("get_settings lists an id with its type and current value")
  func getSettingsLists() {
    let env = MCPTestEnv()
    let r = env.tools().call(name: "get_settings", arguments: [:], access: .write)
    #expect(!r.isError)
    let settings = obj(r)["settings"] as? [[String: Any]] ?? []
    #expect(settings.contains { $0["id"] as? String == "notifications.enabled" })
  }

  @Test("get_settings filters by category")
  func getSettingsFiltersByCategory() {
    let env = MCPTestEnv()
    let r = env.tools().call(name: "get_settings", arguments: ["category": "notifications"], access: .write)
    let settings = obj(r)["settings"] as? [[String: Any]] ?? []
    #expect(!settings.isEmpty)
    #expect(settings.allSatisfy { $0["category"] as? String == "notifications" })
  }

  @Test("get_settings works with the read token")
  func getSettingsIsReadOnly() {
    let env = MCPTestEnv()
    let r = env.tools().call(name: "get_settings", arguments: [:], access: .read)
    #expect(!r.isError)
  }

  // MARK: - update_settings: validation and all-or-nothing

  @Test("update_settings applies a bool setting and get_settings reflects it")
  func updateBool() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["notifications.enabled": false], "rationale": "r"], access: .write)
    #expect(!r.isError)
    #expect(obj(r)["status"] as? String == "applied")
    let after = env.tools().call(name: "get_settings", arguments: ["category": "notifications"], access: .write)
    let settings = obj(after)["settings"] as? [[String: Any]] ?? []
    let entry = settings.first { $0["id"] as? String == "notifications.enabled" }
    #expect(entry?["value"] as? Bool == false)
  }

  @Test("update_settings is a no-op when the value already matches")
  func updateNoOp() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(
      name: "update_settings",
      arguments: ["changes": ["notifications.enabled": SettingsDefaults.showPopupNotifications], "rationale": "r"],
      access: .write)
    #expect(obj(r)["status"] as? String == "no_change")
  }

  @Test("An unknown setting id is refused and nothing else in the batch is written")
  func unknownIdWritesNothing() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(
      name: "update_settings",
      arguments: ["changes": ["notifications.enabled": false, "no.such.setting": true], "rationale": "r"],
      access: .write)
    #expect(r.isError)
    let after = env.tools().call(name: "get_settings", arguments: ["category": "notifications"], access: .write)
    let entry = (obj(after)["settings"] as? [[String: Any]])?.first { $0["id"] as? String == "notifications.enabled" }
    #expect(entry?["value"] as? Bool == true, "the valid change in the same batch must not have been written")
  }

  @Test("An invalid value is refused")
  func invalidValueRefused() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["notifications.enabled": "not-a-bool"], "rationale": "r"],
      access: .write)
    #expect(r.isError)
  }

  @Test("A model without the required credential is refused; the catalog's credential check matches the model's own")
  func modelWithoutCredentialRefused() throws {
    let env = MCPTestEnv(level: .apply)
    // The catalog's validate uses the model's own `hasRequiredCredential` (a real Keychain read,
    // not injected — see the implementation report); skip if this Mac happens to have the key.
    try #require(!TranscriptionModel.openAIGPTTranscribe.hasRequiredCredential)
    let r = env.tools().call(
      name: "update_settings",
      arguments: ["changes": ["dictation.transcription_model": "openai-gpt-transcribe"], "rationale": "r"],
      access: .write)
    #expect(r.isError)
  }

  @Test("A permission-gated setting is refused without the permission, and never prompts")
  func permissionGatedRefused() {
    let env = MCPTestEnv(level: .apply)
    env.box.hasAccessibility = false
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["clipboard.auto_paste": true], "rationale": "r"], access: .write)
    #expect(r.isError)
  }

  @Test("A proposal-only setting becomes a proposal even at access level apply")
  func proposalOnlyForcesProposal() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["general.launch_at_login": true], "rationale": "r"], access: .write)
    #expect(obj(r)["status"] as? String == "pending_review")
    #expect(env.box.launchAtLogin == false, "must not be applied yet")
  }

  @Test("Access level propose turns an ordinary setting into a proposal")
  func proposeLevelProposes() {
    let env = MCPTestEnv(level: .propose)
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["notifications.enabled": false], "rationale": "r"], access: .write)
    #expect(obj(r)["status"] as? String == "pending_review")
    let id = obj(r)["id"] as? String ?? ""
    guard case .success = env.proposals.accept(id) else { Issue.record("accept failed"); return }
    let after = env.tools().call(name: "get_settings", arguments: ["category": "notifications"], access: .write)
    let entry = (obj(after)["settings"] as? [[String: Any]])?.first { $0["id"] as? String == "notifications.enabled" }
    #expect(entry?["value"] as? Bool == false)
  }

  /// A tiny two-entry catalog (one normal bool, one that throws on apply) to exercise
  /// `applySettingsBatch`'s rollback without touching any real settings.
  private func rollbackCatalog(flag: Box<Bool>, shouldThrow: Box<Bool>) -> [MCPSetting] {
    let good = MCPSetting(
      id: "fake.good", title: "Fake Good", category: "fake", kind: .bool,
      read: { flag.value }, validate: { _ in nil },
      apply: { value in flag.value = (value as? Bool) ?? false })
    let bad = MCPSetting(
      id: "fake.bad", title: "Fake Bad", category: "fake", kind: .bool,
      read: { false }, validate: { _ in nil },
      apply: { _ in if shouldThrow.value { throw MCPConfigError(message: "boom") } })
    return [good, bad]
  }

  private final class Box<T> { var value: T; init(_ v: T) { value = v } }

  @Test("A throwing apply on the 2nd item rolls back the 1st; nothing is logged")
  func batchRollsBackOnFailure() {
    let env = MCPTestEnv(level: .apply)
    let flag = Box(false)
    let shouldThrow = Box(true)
    let catalog = rollbackCatalog(flag: flag, shouldThrow: shouldThrow)
    let items = [
      MCPSettingsChangeItem(
        id: "fake.good", title: "Fake Good", fromLabel: "false", toLabel: "true",
        fromJSON: MCPSettingsCatalog.encodeValue(false), toJSON: MCPSettingsCatalog.encodeValue(true)),
      MCPSettingsChangeItem(
        id: "fake.bad", title: "Fake Bad", fromLabel: "false", toLabel: "true",
        fromJSON: MCPSettingsCatalog.encodeValue(false), toJSON: MCPSettingsCatalog.encodeValue(true)),
    ]
    let before = env.changeLog.changes.count
    let result = env.tools().env.applier.applySettingsBatch(
      catalog: catalog, items: items, rationale: "r", viaProposal: false)
    switch result {
    case .success: Issue.record("expected failure")
    case .failure: break
    }
    #expect(flag.value == false, "the 1st item must have been rolled back")
    #expect(env.changeLog.changes.count == before, "no change-log entry for a failed batch")
  }

  @Test("Undo restores every value of an applied batch")
  func undoRestoresBatch() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(
      name: "update_settings",
      arguments: [
        "changes": ["notifications.enabled": false, "window.settings_close_on_focus_loss": true], "rationale": "r",
      ], access: .write)
    let changeID = obj(r)["change_id"] as? String ?? ""
    #expect(env.changeLog.undo(changeID) == .undone)
    let after = env.tools().call(name: "get_settings", arguments: [:], access: .write)
    let settings = obj(after)["settings"] as? [[String: Any]] ?? []
    #expect(settings.first { $0["id"] as? String == "notifications.enabled" }?["value"] as? Bool == true)
    #expect(settings.first { $0["id"] as? String == "window.settings_close_on_focus_loss" }?["value"] as? Bool == false)
  }

  @Test("Undo skips an item changed by hand since the AI app's edit; the hand-set value is kept")
  func undoSkipsWhenChangedSince() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["notifications.enabled": false], "rationale": "r"],
      access: .write)
    let changeID = obj(r)["change_id"] as? String ?? ""
    // Someone (or another AI app) changes it by hand before Undo runs.
    env.testDefaults.set(true, forKey: UserDefaultsKeys.showPopupNotifications)
    let outcome = env.changeLog.undo(changeID)
    #expect(outcome == .conflict(current: nil), "the only item in the batch was skipped, so the whole undo is a conflict")
    #expect(env.testDefaults.bool(forKey: UserDefaultsKeys.showPopupNotifications) == true, "the hand-set value must be kept")
  }

  @Test("settingsChangedExternally is posted exactly once per applied batch")
  func settingsChangedExternallyPostedOnce() {
    let env = MCPTestEnv(level: .apply)
    final class Counter { var count = 0 }
    let counter = Counter()
    let observer = NotificationCenter.default.addObserver(
      forName: .settingsChangedExternally, object: nil, queue: nil) { _ in counter.count += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }
    _ = env.tools().call(
      name: "update_settings",
      arguments: [
        "changes": ["notifications.enabled": false, "window.settings_close_on_focus_loss": true], "rationale": "r",
      ], access: .write)
    #expect(counter.count == 1)
  }

  // MARK: - Shortcuts

  @Test("A shortcut missing ⌘/⌥/⌃ is refused")
  func shortcutModifierRuleEnforced() {
    let env = MCPTestEnv(level: .apply)
    let dict: [String: Any] = ["key": "a", "modifiers": []]
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["shortcuts.dictate": dict], "rationale": "r"], access: .write)
    #expect(r.isError)
  }

  @Test("A shortcut that conflicts with another enabled slot is refused")
  func shortcutConflictDetected() {
    let env = MCPTestEnv(level: .apply)
    // startPrompting's default is ⌃⌥2; proposing the same combo for Dictate must be refused.
    let taken = env.box.shortcutConfig.startPrompting
    let dict = Self.jsonObject(of: taken)
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["shortcuts.dictate": dict], "rationale": "r"], access: .write)
    #expect(r.isError)
  }

  @Test("An unknown key name is refused")
  func shortcutUnknownKeyRejected() {
    let env = MCPTestEnv(level: .apply)
    let dict: [String: Any] = ["key": "notakey", "modifiers": ["control", "option"]]
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["shortcuts.dictate": dict], "rationale": "r"], access: .write)
    #expect(r.isError)
  }

  @Test("An extra modifier name (capsLock-like) is refused")
  func shortcutUnknownModifierRejected() {
    let env = MCPTestEnv(level: .apply)
    let dict: [String: Any] = ["key": "1", "modifiers": ["control", "capslock"]]
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["shortcuts.dictate": dict], "rationale": "r"], access: .write)
    #expect(r.isError)
  }

  @Test("A modifier-only key name is refused as the key itself")
  func shortcutModifierAsKeyRejected() {
    let env = MCPTestEnv(level: .apply)
    let dict: [String: Any] = ["key": "command", "modifiers": ["control"]]
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["shortcuts.dictate": dict], "rationale": "r"], access: .write)
    #expect(r.isError)
  }

  @Test("A shortcut round-trips through the {key, modifiers} JSON format")
  func shortcutFormatRoundTrips() throws {
    let env = MCPTestEnv(level: .apply)
    let dict: [String: Any] = ["key": "5", "modifiers": ["control", "option"]]
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["shortcuts.dictate": dict], "rationale": "r"], access: .write)
    #expect(!r.isError)
    #expect(env.box.shortcutConfig.startRecording.key == .five)
    #expect(env.box.shortcutConfig.startRecording.modifiers == [.control, .option])

    let after = env.tools().call(name: "get_settings", arguments: ["category": "shortcuts"], access: .write)
    let settings = obj(after)["settings"] as? [[String: Any]] ?? []
    let entry = settings.first { $0["id"] as? String == "shortcuts.dictate" }
    let value = try #require(entry?["value"] as? [String: Any])
    #expect(value["key"] as? String == "5")
    #expect(Set((value["modifiers"] as? [String]) ?? []) == Set(["control", "option"]))
  }

  @Test("Two shortcut items in the same batch claiming the same unused combo are both rejected; nothing is written")
  func shortcutBatchConflictBetweenNewItems() {
    let env = MCPTestEnv(level: .apply)
    // ⌃⌥9 is not used by any default shortcut.
    let dict: [String: Any] = ["key": "9", "modifiers": ["control", "option"]]
    let before = env.box.shortcutConfig
    let r = env.tools().call(
      name: "update_settings",
      arguments: ["changes": ["shortcuts.open_chat": dict, "shortcuts.open_settings": dict], "rationale": "r"],
      access: .write)
    #expect(r.isError)
    #expect(env.box.shortcutConfig == before, "nothing in the batch must have been written")
  }

  @Test("null disables the shortcut")
  func shortcutNullDisables() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["shortcuts.dictate": NSNull()], "rationale": "r"], access: .write)
    #expect(!r.isError)
    #expect(env.box.shortcutConfig.startRecording.isEnabled == false)
  }

  @Test("All seven shortcut settings are in the catalog")
  func allShortcutIdsPresent() {
    let ids = MCPTestEnv().settingsCatalog.map(\.id)
    let expected = [
      "shortcuts.dictate",
      "shortcuts.dictate_prompt",
      "shortcuts.screenshot",
      "shortcuts.read_aloud",
      "shortcuts.add_to_glossary",
      "shortcuts.open_chat",
      "shortcuts.open_settings",
    ]
    for id in expected {
      #expect(ids.contains(id), "missing \(id)")
    }
  }

  @Test("Dictate Prompt refuses Screenshot's shortcut")
  func shortcutConflictBetweenNewSlots() {
    let env = MCPTestEnv(level: .apply)
    let taken = env.box.shortcutConfig.screenshotCapture
    let dict = Self.jsonObject(of: taken)
    let r = env.tools().call(
      name: "update_settings",
      arguments: ["changes": ["shortcuts.dictate_prompt": dict], "rationale": "r"], access: .write)
    #expect(r.isError)
    #expect(env.box.shortcutConfig.startPrompting == ShortcutConfig.default.startPrompting)
  }

  @Test("null disables Open Chat")
  func shortcutNullDisablesOpenChat() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["shortcuts.open_chat": NSNull()], "rationale": "r"], access: .write)
    #expect(!r.isError)
    #expect(env.box.shortcutConfig.openChat.isEnabled == false)
  }

  @Test("Proposal-only toggles require approval and stay pending at apply level")
  func proposalOnlyTogglesRequireApproval() {
    let env = MCPTestEnv(level: .apply)
    let ids = ["writing_style.enabled", "dictate_prompt.tools_enabled", "chat.claude_web_search"]
    let listed = env.tools().call(name: "get_settings", arguments: [:], access: .write)
    let settings = obj(listed)["settings"] as? [[String: Any]] ?? []
    for id in ids {
      let entry = settings.first { $0["id"] as? String == id }
      #expect(entry?["requires_approval"] as? Bool == true, "\(id) requires_approval")
    }
    let r = env.tools().call(
      name: "update_settings",
      arguments: ["changes": ["writing_style.enabled": true], "rationale": "r"], access: .write)
    #expect(obj(r)["status"] as? String == "pending_review")
    #expect(env.testDefaults.bool(forKey: UserDefaultsKeys.writingStyleEnabled) == false)
  }

  // MARK: - Models, provider ids, parameters

  @Test("Model, provider-id and parameter entries are present and unique")
  func modelEntriesPresent() {
    let env = MCPTestEnv()
    let ids = env.settingsCatalog.map(\.id)
    #expect(Set(ids).count == ids.count)
    let expected = [
      "meetings.transcription_model",
      "dictate_prompt.model",
      "meetings.summary_model",
      "improvement.model",
      "read_aloud.model",
      "chat.chatgpt_plan_model_id",
      "chat.custom_endpoint_model_id",
      "dictation.openrouter_model_id",
      "dictate_prompt.local_model_id",
      "dictation.temperature",
      "dictation.thinking_effort",
      "read_aloud.speed",
      "read_aloud.voice.gemini",
      "read_aloud.voice.openai",
      "read_aloud.voice.xai",
      "read_aloud.voice.system",
    ]
    for id in expected {
      #expect(ids.contains(id), "missing \(id)")
    }
  }

  @Test("A chat model write calls the reconciler and posts promptModelChanged")
  func modelWritePostsReconcilerAndPromptChanged() throws {
    let env = MCPTestEnv(level: .apply)
    let setting = try #require(env.settingsCatalog.first { $0.id == "chat.model" })
    try setting.apply(SettingsDefaults.selectedChatModel.rawValue)
    #expect(env.box.notifications.contains { $0.0 == .promptModelChanged })
    #expect(env.box.notifications.contains { $0.0 == .modelSelectionsReconciled })
    #expect(
      env.testDefaults.string(forKey: UserDefaultsKeys.selectedChatModel)
        == SettingsDefaults.selectedChatModel.rawValue)
  }

  @Test("meetings.transcription_model null clears the key and reads back as null")
  func meetingsTranscriptionNullRoundTrip() throws {
    let env = MCPTestEnv(level: .apply)
    let setting = try #require(env.settingsCatalog.first { $0.id == "meetings.transcription_model" })
    #expect(setting.read() is NSNull)

    let model = TranscriptionModel.parakeetUltra
    try setting.apply(model.rawValue)
    #expect(setting.read() as? String == model.rawValue)
    #expect(
      env.testDefaults.string(forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings) == model.rawValue)

    let r = env.tools().call(
      name: "update_settings",
      arguments: ["changes": ["meetings.transcription_model": NSNull()], "rationale": "r"],
      access: .write)
    #expect(!r.isError)
    #expect(obj(r)["status"] as? String == "applied")
    #expect(setting.read() is NSNull)
    #expect(env.testDefaults.object(forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings) == nil)
  }

  // MARK: - Behaviour entries

  @Test("Behaviour entries are in the catalog")
  func behaviourEntriesPresent() {
    let ids = MCPTestEnv().settingsCatalog.map(\.id)
    let expected = [
      "notifications.duration",
      "clipboard.restore_after_paste",
      "chat.close_on_focus_loss",
      "recording.confirm_above_duration",
      "meetings.chunk_interval",
      "meetings.safeguard_duration",
      "dictate_prompt.screenshot_context",
      "chat.x_search_handles",
      "improvement.auto_run_interval",
    ]
    for id in expected {
      #expect(ids.contains(id), "missing \(id)")
    }
  }

  @Test("Screenshot context is refused without Screen Recording permission")
  func screenshotContextRefusedWithoutPermission() {
    let env = MCPTestEnv(level: .apply)
    env.box.hasScreenRecording = false
    env.testDefaults.set(false, forKey: UserDefaultsKeys.screenshotInPromptMode)
    let r = env.tools().call(
      name: "update_settings",
      arguments: ["changes": ["dictate_prompt.screenshot_context": true], "rationale": "r"],
      access: .write)
    #expect(r.isError)
    #expect(r.text.contains("Grant Screen Recording in Settings → Permissions first."))
    #expect(env.testDefaults.bool(forKey: UserDefaultsKeys.screenshotInPromptMode) == false)
  }

  @Test("chat.x_search_handles change-log toLabel shows the normalized form, not the raw input")
  func xSearchHandlesToLabelNormalized() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(
      name: "update_settings",
      arguments: ["changes": ["chat.x_search_handles": "@ElonMusk @elonmusk"], "rationale": "r"],
      access: .write)
    #expect(!r.isError)
    let changeID = obj(r)["change_id"] as? String ?? ""
    let change = env.changeLog.changes.first { $0.id == changeID }
    let toLabel = change?.settingsChanges?.first { $0.id == "chat.x_search_handles" }?.toLabel
    #expect(toLabel == "elonmusk", "must show the normalized/deduped form, not the raw \"@ElonMusk @elonmusk\"")
  }

  @Test("notifications.duration round-trips through update_settings and get_settings")
  func notificationDurationRoundTrip() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(
      name: "update_settings",
      arguments: ["changes": ["notifications.duration": "10"], "rationale": "r"],
      access: .write)
    #expect(!r.isError)
    #expect(obj(r)["status"] as? String == "applied")
    let after = env.tools().call(name: "get_settings", arguments: ["category": "notifications"], access: .write)
    let settings = obj(after)["settings"] as? [[String: Any]] ?? []
    let entry = settings.first { $0["id"] as? String == "notifications.duration" }
    #expect(entry?["value"] as? String == "10")
    #expect(env.testDefaults.double(forKey: UserDefaultsKeys.notificationDuration) == NotificationDuration.tenSeconds.rawValue)
  }

  /// The new MCP shortcut JSON format `{"key": "<name>", "modifiers": [...]}`, mirroring
  /// `MCPSettingsCatalog`'s own `json(of:)` so tests can build a value for an existing
  /// `ShortcutDefinition` (e.g. a slot's current combo) without duplicating its modifier mapping.
  private static func jsonObject(of definition: ShortcutDefinition) -> [String: Any] {
    var modifiers: [String] = []
    if definition.modifiers.contains(.command) { modifiers.append("command") }
    if definition.modifiers.contains(.option) { modifiers.append("option") }
    if definition.modifiers.contains(.control) { modifiers.append("control") }
    if definition.modifiers.contains(.shift) { modifiers.append("shift") }
    return ["key": definition.key.mcpKeyName, "modifiers": modifiers]
  }
}

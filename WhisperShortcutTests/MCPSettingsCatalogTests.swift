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
    case .stringList: return ["Korrigiere."]
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

  // MARK: - dictate_prompt.quick_prompts

  private func setQuickPrompts(_ env: MCPTestEnv, _ value: Any) -> MCPToolResult {
    env.tools().call(
      name: "update_settings",
      arguments: ["changes": ["dictate_prompt.quick_prompts": value], "rationale": "r"], access: .write)
  }

  @Test("quick_prompts stores the trimmed non-blank list in order")
  func quickPromptsStored() {
    let env = MCPTestEnv(level: .apply)
    let r = setQuickPrompts(env, ["  A  ", "", "B"])
    #expect(!r.isError)
    #expect(env.testDefaults.stringArray(forKey: UserDefaultsKeys.dictatePromptCustomQuickActions) == ["A", "B"])
  }

  @Test("quick_prompts rejects more than 9 entries and writes nothing")
  func quickPromptsTooMany() {
    let env = MCPTestEnv(level: .apply)
    let r = setQuickPrompts(env, (1...10).map { "P\($0)" })
    #expect(r.isError)
    #expect(env.testDefaults.object(forKey: UserDefaultsKeys.dictatePromptCustomQuickActions) == nil)
  }

  @Test("quick_prompts rejects an entry over 300 characters")
  func quickPromptsTooLong() {
    let env = MCPTestEnv(level: .apply)
    let r = setQuickPrompts(env, [String(repeating: "x", count: 301)])
    #expect(r.isError)
    #expect(env.testDefaults.object(forKey: UserDefaultsKeys.dictatePromptCustomQuickActions) == nil)
  }

  @Test("quick_prompts rejects a non-array value")
  func quickPromptsNotArray() {
    let env = MCPTestEnv(level: .apply)
    let r = setQuickPrompts(env, "A")
    #expect(r.isError)
    #expect(env.testDefaults.object(forKey: UserDefaultsKeys.dictatePromptCustomQuickActions) == nil)
  }

  @Test("get_settings lists quick_prompts as a string_list with max_items 9")
  func quickPromptsListed() {
    let env = MCPTestEnv()
    let r = env.tools().call(name: "get_settings", arguments: ["category": "dictate_prompt"], access: .write)
    let entry = (obj(r)["settings"] as? [[String: Any]])?.first { $0["id"] as? String == "dictate_prompt.quick_prompts" }
    #expect(entry?["type"] as? String == "string_list")
    #expect(entry?["max_items"] as? Int == 9)
  }

  // MARK: - get_settings

  @Test("get_settings lists an id with its type and current value", arguments: [
    (MCPAccess.write, true, "write token"),
    (.read, false, "read token"),
  ])
  func getSettingsLists(access: MCPAccess, listsNotification: Bool, label: String) {
    let env = MCPTestEnv()
    let r = env.tools().call(name: "get_settings", arguments: [:], access: access)
    #expect(!r.isError, "\(label)")
    if listsNotification {
      let settings = obj(r)["settings"] as? [[String: Any]] ?? []
      #expect(settings.contains { $0["id"] as? String == "notifications.enabled" }, "\(label)")
    }
  }

  @Test("get_settings filters by category")
  func getSettingsFiltersByCategory() {
    let env = MCPTestEnv()
    let r = env.tools().call(name: "get_settings", arguments: ["category": "notifications"], access: .write)
    let settings = obj(r)["settings"] as? [[String: Any]] ?? []
    #expect(!settings.isEmpty)
    #expect(settings.allSatisfy { $0["category"] as? String == "notifications" })
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

  @Test("writing_style.enabled routes its side effect through the injected hook")
  func writingStyleToggleIsInjected() throws {
    let env = MCPTestEnv(level: .apply)
    let setting = try #require(env.settingsCatalog.first { $0.id == "writing_style.enabled" })
    try setting.apply(true)
    #expect(env.box.writingStyleToggles == [true])
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

  @Test(
    "A model without the required credential is refused; the catalog's credential check matches the model's own",
    .enabled(if: !TranscriptionModel.openAIGPTTranscribe.hasRequiredCredential,
             "OpenAI key is present; this case needs a model with no credential"))
  func modelWithoutCredentialRefused() throws {
    let env = MCPTestEnv(level: .apply)
    // The catalog's validate uses the model's own `hasRequiredCredential` (a real Keychain read,
    // not injected — see the implementation report). The trait above skips when this Mac has the key.
    let r = env.tools().call(
      name: "update_settings",
      arguments: ["changes": ["dictation.transcription_model": "openai-gpt-transcribe"], "rationale": "r"],
      access: .write)
    #expect(r.isError)
  }

  private struct PermissionRefusal: Sendable {
    let note: String
    let settingId: String
    let missingPermission: String
    let message: String?
    let unchangedKey: String?
  }

  private static let permissionRefusals: [PermissionRefusal] = [
    .init(note: "auto-paste without Accessibility", settingId: "clipboard.auto_paste",
          missingPermission: "accessibility", message: nil, unchangedKey: nil),
    .init(note: "screenshot context without Screen Recording", settingId: "dictate_prompt.screenshot_context",
          missingPermission: "screenRecording",
          message: "Grant Screen Recording in Settings → Permissions first.",
          unchangedKey: UserDefaultsKeys.screenshotInPromptMode),
  ]

  @Test("A permission-gated setting is refused without the permission, and never prompts", arguments: permissionRefusals)
  private func permissionGatedRefused(_ row: PermissionRefusal) {
    let env = MCPTestEnv(level: .apply)
    if row.missingPermission == "accessibility" {
      env.box.hasAccessibility = false
    } else {
      env.box.hasScreenRecording = false
    }
    if let key = row.unchangedKey { env.testDefaults.set(false, forKey: key) }
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": [row.settingId: true], "rationale": "r"], access: .write)
    #expect(r.isError, "\(row.note)")
    if let message = row.message { #expect(r.text.contains(message), "\(row.note)") }
    if let key = row.unchangedKey { #expect(env.testDefaults.bool(forKey: key) == false, "\(row.note)") }
  }

  private struct ProposalOnlyRow: Sendable {
    let note: String
    let settingId: String
    let approvalIds: [String]
    let staysOff: String
  }

  private static let proposalOnlyRows: [ProposalOnlyRow] = [
    .init(note: "launch at login", settingId: "general.launch_at_login", approvalIds: [], staysOff: "launchAtLogin"),
    .init(note: "proposal-only toggles", settingId: "writing_style.enabled",
          approvalIds: [
            "writing_style.enabled", "dictate_prompt.tools_enabled", "chat.claude_web_search",
            "dictation.transcription_model", "meetings.transcription_model", "dictate_prompt.screenshot_context",
          ],
          staysOff: "writingStyle"),
  ]

  @Test("A proposal-only setting stays pending even at access level apply", arguments: proposalOnlyRows)
  private func proposalOnlyForcesProposal(_ row: ProposalOnlyRow) {
    let env = MCPTestEnv(level: .apply)
    if !row.approvalIds.isEmpty {
      let listed = env.tools().call(name: "get_settings", arguments: [:], access: .write)
      let settings = obj(listed)["settings"] as? [[String: Any]] ?? []
      for id in row.approvalIds {
        let entry = settings.first { $0["id"] as? String == id }
        #expect(entry?["requires_approval"] as? Bool == true, "\(row.note): \(id)")
      }
    }
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": [row.settingId: true], "rationale": "r"], access: .write)
    #expect(obj(r)["status"] as? String == "pending_review", "\(row.note)")
    switch row.staysOff {
    case "launchAtLogin":
      #expect(env.box.launchAtLogin == false, "\(row.note)")
    case "writingStyle":
      #expect(env.testDefaults.bool(forKey: UserDefaultsKeys.writingStyleEnabled) == false, "\(row.note)")
    default:
      Issue.record("unknown staysOff \(row.staysOff)")
    }
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

  @Test("An invalid shortcut is refused", arguments: [
    ("a", [] as [String], "missing ⌘/⌥/⌃"),
    ("notakey", ["control", "option"], "unknown key"),
    ("1", ["control", "capslock"], "unknown modifier"),
    ("command", ["control"], "modifier used as the key"),
  ])
  func shortcutRejected(key: String, modifiers: [String], label: String) {
    let env = MCPTestEnv(level: .apply)
    let dict: [String: Any] = ["key": key, "modifiers": modifiers]
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["shortcuts.dictate": dict], "rationale": "r"], access: .write)
    #expect(r.isError, "\(label)")
  }

  private struct ShortcutConflictRow: Sendable {
    let note: String
    let settingId: String
    let source: String
    let checkPromptingUnchanged: Bool
  }

  private static let shortcutConflicts: [ShortcutConflictRow] = [
    // startPrompting's default is ⌃⌥2; proposing the same combo for Dictate must be refused.
    .init(note: "dictate vs an existing slot", settingId: "shortcuts.dictate", source: "startPrompting",
          checkPromptingUnchanged: false),
    .init(note: "dictate prompt vs screenshot", settingId: "shortcuts.dictate_prompt", source: "screenshot",
          checkPromptingUnchanged: true),
  ]

  @Test("A shortcut that conflicts with another enabled slot is refused", arguments: shortcutConflicts)
  private func shortcutConflictDetected(_ row: ShortcutConflictRow) {
    let env = MCPTestEnv(level: .apply)
    let taken: ShortcutDefinition
    switch row.source {
    case "startPrompting": taken = env.box.shortcutConfig.startPrompting
    case "screenshot": taken = env.box.shortcutConfig.screenshotCapture
    default:
      Issue.record("\(row.note)")
      return
    }
    let dict = Self.jsonObject(of: taken)
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": [row.settingId: dict], "rationale": "r"], access: .write)
    #expect(r.isError, "\(row.note)")
    if row.checkPromptingUnchanged {
      #expect(env.box.shortcutConfig.startPrompting == ShortcutConfig.default.startPrompting, "\(row.note)")
    }
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

  // MARK: - Models, provider ids, parameters

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
    #expect(obj(r)["status"] as? String == "pending_review")
    #expect(setting.read() as? String == model.rawValue, "a proposal must not clear the key yet")
    guard case .success = env.proposals.accept(obj(r)["id"] as? String ?? "") else {
      Issue.record("accept failed"); return
    }
    #expect(setting.read() is NSNull)
    #expect(env.testDefaults.object(forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings) == nil)
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

  // MARK: - Stale accept, normalised comparison (R218, R219)

  @Test("Accepting a settings proposal refuses when the setting changed since, and applies nothing")
  func staleSettingsProposalRefused() {
    let env = MCPTestEnv(level: .propose)
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["notifications.enabled": false], "rationale": "r"], access: .write)
    let id = obj(r)["id"] as? String ?? ""
    // Changed by hand after the AI app proposed (from-value was `true`).
    env.testDefaults.set(false, forKey: UserDefaultsKeys.showPopupNotifications)
    let changesBefore = env.changeLog.changes.count
    switch env.proposals.accept(id) {
    case .success: Issue.record("stale settings proposal must not be accepted")
    case .failure(let error): #expect(error.localizedDescription.contains("changed since"))
    }
    #expect(env.changeLog.changes.count == changesBefore)
    #expect(env.proposals.status(of: id)?.status == .pending)
  }

  @Test("sameValue compares arrays element-wise and shortcuts regardless of modifier order")
  func sameValueArraysAndShortcuts() {
    #expect(MCPSettingsCatalog.sameValue(["A", "B"] as [Any], ["A", "B"] as [Any]))
    #expect(!MCPSettingsCatalog.sameValue(["A", "B"] as [Any], ["B", "A"] as [Any]))
    #expect(!MCPSettingsCatalog.sameValue(["A"] as [Any], ["A", "B"] as [Any]))
    let a: [String: Any] = ["key": "a", "modifiers": ["option", "control"]]
    let b: [String: Any] = ["key": "a", "modifiers": ["control", "option"]]
    #expect(MCPSettingsCatalog.sameValue(a, b))
  }

  @Test("A model id with surrounding spaces is stored trimmed and a repeat call is no_change")
  func modelIDTrimmed() {
    let env = MCPTestEnv(level: .apply)
    let args: [String: Any] = ["changes": ["chat.custom_endpoint_model_id": "  my-model  "], "rationale": "r"]
    let first = env.tools().call(name: "update_settings", arguments: args, access: .write)
    #expect(!first.isError)
    #expect(env.testDefaults.string(forKey: UserDefaultsKeys.customOpenAIChatModelID) == "my-model")
    let second = env.tools().call(name: "update_settings", arguments: args, access: .write)
    #expect(obj(second)["status"] as? String == "no_change")
  }

  @Test("Undo of quick_prompts restores the previous list and an identical call is no_change")
  func quickPromptsUndoAndNoChange() {
    let env = MCPTestEnv(level: .apply)
    let args: [String: Any] = [
      "changes": ["dictate_prompt.quick_prompts": ["  A  ", "", "B"]], "rationale": "r"]
    let r = env.tools().call(name: "update_settings", arguments: args, access: .write)
    let changeID = obj(r)["change_id"] as? String ?? ""
    #expect(!changeID.isEmpty)
    let again = env.tools().call(name: "update_settings", arguments: args, access: .write)
    #expect(obj(again)["status"] as? String == "no_change")
    #expect(env.changeLog.undo(changeID) == .undone)
    #expect(env.testDefaults.stringArray(forKey: UserDefaultsKeys.dictatePromptCustomQuickActions) == [])
  }

  // MARK: - Qwen3 voice validated against the model in the same batch (R220)

  @Test("qwen3 voice is judged against the read_aloud.model set in the same batch")
  func qwen3VoiceFollowsBatchModel() {
    let env = MCPTestEnv()
    guard let voice = env.settingsCatalog.first(where: { $0.id == "read_aloud.voice.qwen3" }) else {
      Issue.record("missing read_aloud.voice.qwen3"); return
    }
    let speaker = Qwen3VoicePersona.customVoiceSpeakers[0].id
    let persona = Qwen3VoicePersona.default.id
    // Right pairs accepted.
    #expect(voice.validateWithBatch(speaker, batch: ["read_aloud.model": TTSModel.qwen3CustomVoice.rawValue]) == nil)
    #expect(voice.validateWithBatch(persona, batch: ["read_aloud.model": TTSModel.qwen3VoiceDesign.rawValue]) == nil)
    // Wrong pairs rejected.
    #expect(voice.validateWithBatch(persona, batch: ["read_aloud.model": TTSModel.qwen3CustomVoice.rawValue]) != nil)
    #expect(voice.validateWithBatch(speaker, batch: ["read_aloud.model": TTSModel.qwen3VoiceDesign.rawValue]) != nil)
  }
}

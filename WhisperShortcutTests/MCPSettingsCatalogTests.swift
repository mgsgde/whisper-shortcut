import Testing
import Foundation
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

  @Test("No excluded UserDefaults key is exposed raw")
  func noSecretsExposed() {
    // The catalog must never carry an API key or token under any id.
    let env = MCPTestEnv()
    let forbidden = ["apikey", "api_key", "token", "secret", "password"]
    for setting in env.settingsCatalog {
      let lowered = setting.id.lowercased()
      #expect(!forbidden.contains { lowered.contains($0) })
    }
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

  // MARK: - Shortcuts

  @Test("A shortcut missing ⌘/⌥/⌃ is refused")
  func shortcutModifierRuleEnforced() {
    let env = MCPTestEnv(level: .apply)
    let dict: [String: Any] = ["key": 0, "modifiers": 0, "isEnabled": true]
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

  @Test("null disables the shortcut")
  func shortcutNullDisables() {
    let env = MCPTestEnv(level: .apply)
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["shortcuts.dictate": NSNull()], "rationale": "r"], access: .write)
    #expect(!r.isError)
    #expect(env.box.shortcutConfig.startRecording.isEnabled == false)
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

  private static func jsonObject(of definition: ShortcutDefinition) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(definition),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
  }
}

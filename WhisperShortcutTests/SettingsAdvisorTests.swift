import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Settings advisor, app_settings tool and /improve")
struct SettingsAdvisorTests {

  /// Fake dependencies and an isolated defaults suite; nothing touches the real app state.
  final class Fixture: @unchecked Sendable {
    let defaults = UserDefaults(suiteName: "settings-advisor-test-\(UUID().uuidString)")!
    var hasAccessibility = true
    var hasScreenRecording = true
    var launchAtLogin = false
    lazy var deps = MCPSettingsCatalog.Dependencies(
      defaults: defaults,
      hasAccessibilityPermission: { [unowned self] in hasAccessibility },
      hasScreenRecordingPermission: { [unowned self] in hasScreenRecording },
      isLaunchAtLoginEnabled: { [unowned self] in launchAtLogin },
      setLaunchAtLogin: { [unowned self] in launchAtLogin = $0 },
      postNotification: { _, _ in },
      postSelectionsChanged: {},
      writingStyleToggled: { _ in })
    var suppressions: ImproveSuppressions { ImproveSuppressions(defaults: defaults) }

    /// A model picker whose options are always available (real ones depend on the Keychain).
    static func fakeModel(id: String, defaultValue: String, defaults: UserDefaults) -> MCPSetting {
      let key = "fake.\(id)"
      return MCPSetting(
        id: id, title: "Chat model", category: "models",
        kind: .enumeration(options: {
          [MCPSetting.Option(defaultValue, "Default model"), MCPSetting.Option("other", "Other"),
           MCPSetting.Option("other2", "Other two")]
        }),
        read: { defaults.string(forKey: key) ?? defaultValue },
        validate: { _ in nil },
        apply: { defaults.set($0 as? String, forKey: key) })
    }

    lazy var catalog: [MCPSetting] = {
      let fakes: [String: String] = [
        "dictation.transcription_model": SettingsDefaults.selectedTranscriptionModel.rawValue,
        "chat.model": SettingsDefaults.selectedChatModel.rawValue,
        "dictate_prompt.model": SettingsDefaults.selectedPromptModel.rawValue,
      ]
      return MCPSettingsCatalog.build(deps).map { s in
        fakes[s.id].map { Self.fakeModel(id: s.id, defaultValue: $0, defaults: defaults) } ?? s
      }
    }()

    /// Everything the advisor looks at is in its good state.
    func setAllGood() {
      defaults.set(true, forKey: UserDefaultsKeys.contextLoggingEnabled)
      defaults.set(true, forKey: UserDefaultsKeys.fnKeyDictation)
      defaults.set(true, forKey: UserDefaultsKeys.autoPasteAfterDictation)
      defaults.set(true, forKey: UserDefaultsKeys.promptSendsFocusedFieldText)
      defaults.set(true, forKey: UserDefaultsKeys.screenshotInPromptMode)
      defaults.set(true, forKey: UserDefaultsKeys.writingStyleEnabled)
      launchAtLogin = true
    }

    func findings() -> [SettingsFinding] {
      SettingsAdvisor.findings(catalog: catalog, deps: deps, suppressions: suppressions)
    }
    func ids() -> [String] { findings().map(\.id) }
  }

  @Test("A fully set-up Mac has no findings")
  func allGood() {
    let f = Fixture()
    f.setAllGood()
    #expect(f.ids().isEmpty)
  }

  @Test("A recommended switch that is off is a recommended finding; on, none")
  func recommendedSwitch() {
    let f = Fixture()
    f.setAllGood()
    f.defaults.set(false, forKey: UserDefaultsKeys.autoPasteAfterDictation)
    let found = f.findings().first { $0.id == "clipboard.auto_paste" }
    #expect(found?.priority == .recommended)
    #expect(found?.fix == .set(id: "clipboard.auto_paste", value: .bool(true)))
    f.defaults.set(true, forKey: UserDefaultsKeys.autoPasteAfterDictation)
    #expect(f.ids().isEmpty)
  }

  @Test("Fn key: a recommended finding when off (direct-download build), none when on")
  func fnKey() {
    let f = Fixture()
    f.setAllGood()
    f.defaults.set(false, forKey: UserDefaultsKeys.fnKeyDictation)
    let available = f.catalog.first { $0.id == "dictation.fn_key" }?.unavailableReason() == nil
    #expect(f.ids().contains("dictation.fn_key") == available)
    f.defaults.set(true, forKey: UserDefaultsKeys.fnKeyDictation)
    #expect(!f.ids().contains("dictation.fn_key"))
  }

  @Test("Auto-paste on without Accessibility is a blocker that sorts before recommendations")
  func accessibilityBlocker() {
    let f = Fixture()
    f.setAllGood()
    f.hasAccessibility = false
    f.defaults.set(false, forKey: UserDefaultsKeys.promptSendsFocusedFieldText)
    let found = f.findings()
    #expect(found.first?.id == "permission.accessibility")
    #expect(found.first?.priority == .blocker)
    #expect(found.first?.fix == .userAction(where: String(localized: "Settings → Permissions")))
    #expect(found.contains { $0.id == "dictate_prompt.field_text_context" })
  }

  @Test("Picture of the front window on without Screen Recording is a blocker")
  func screenRecordingBlocker() {
    let f = Fixture()
    f.setAllGood()
    f.hasScreenRecording = false
    #expect(f.ids() == ["permission.screen_recording"])
  }

  @Test("Save usage data off is a blocker; Offline Mode hides it")
  func usageDataBlocker() {
    let f = Fixture()
    f.setAllGood()
    f.defaults.set(false, forKey: UserDefaultsKeys.contextLoggingEnabled)
    #expect(f.findings().first?.id == "privacy.save_usage_data")
    #expect(f.findings().first?.priority == .blocker)
    f.defaults.set(true, forKey: UserDefaultsKeys.offlineModeEnabled)
    #expect(!f.ids().contains("privacy.save_usage_data"))
  }

  @Test("A model that differs from the default is raised once, until its value changes")
  func modelNagOnce() {
    let f = Fixture()
    f.setAllGood()
    f.defaults.set("other", forKey: "fake.chat.model")
    let first = SettingsAdvisor.review(catalog: f.catalog, deps: f.deps, suppressions: f.suppressions)
    #expect(first.findings.map(\.id) == ["chat.model"])
    #expect(first.findings.first?.priority == .optional)
    let second = SettingsAdvisor.review(catalog: f.catalog, deps: f.deps, suppressions: f.suppressions)
    #expect(second.findings.isEmpty)
    #expect(second.suppressedCount == 1)
    f.defaults.set("other2", forKey: "fake.chat.model")
    let third = SettingsAdvisor.review(catalog: f.catalog, deps: f.deps, suppressions: f.suppressions)
    #expect(third.findings.map(\.id) == ["chat.model"])
  }

  @Test("Back on the default model there is no finding")
  func modelOnDefault() {
    let f = Fixture()
    f.setAllGood()
    #expect(f.ids().isEmpty)
  }

  @Test("A suppressed recommendation stays quiet until its value changes")
  func suppressionHoldsUntilValueChanges() {
    let f = Fixture()
    f.setAllGood()
    f.defaults.set(false, forKey: UserDefaultsKeys.promptSendsFocusedFieldText)
    #expect(f.ids() == ["dictate_prompt.field_text_context"])
    f.suppressions.suppress(id: "dictate_prompt.field_text_context", currentValue: "Off")
    #expect(f.ids().isEmpty)
    #expect(f.suppressions.isSuppressed(id: "dictate_prompt.field_text_context", currentValue: "Off"))
    #expect(!f.suppressions.isSuppressed(id: "dictate_prompt.field_text_context", currentValue: "On"))
    // Reviewing a blocker never suppresses it by itself.
    f.defaults.set(false, forKey: UserDefaultsKeys.contextLoggingEnabled)
    _ = SettingsAdvisor.review(catalog: f.catalog, deps: f.deps, suppressions: f.suppressions)
    #expect(f.ids().contains("privacy.save_usage_data"))
  }

  @Test("At most 8 findings, blockers before recommendations before optional ones")
  func capAndOrder() {
    let f = Fixture()
    f.launchAtLogin = false
    for key in [UserDefaultsKeys.fnKeyDictation, UserDefaultsKeys.autoPasteAfterDictation,
                UserDefaultsKeys.promptSendsFocusedFieldText, UserDefaultsKeys.screenshotInPromptMode,
                UserDefaultsKeys.writingStyleEnabled, UserDefaultsKeys.contextLoggingEnabled] {
      f.defaults.set(false, forKey: key)
    }
    for id in ["dictation.transcription_model", "chat.model", "dictate_prompt.model"] {
      f.defaults.set("other", forKey: "fake.\(id)")
    }
    let found = f.findings()
    #expect(found.count == 8)
    let rank: [SettingsFinding.Priority: Int] = [.blocker: 0, .recommended: 1, .optional: 2]
    let ranks = found.map { rank[$0.priority]! }
    #expect(ranks == ranks.sorted())
    #expect(found.first?.priority == .blocker)
  }

  // MARK: - app_settings tool

  @Test("Only app_settings set needs the approval card, and never chat-wide approval")
  func approvalGate() {
    #expect(ChatToolRegistry.requiresUserApproval("app_settings", args: ["action": "set"]))
    #expect(!ChatToolRegistry.requiresUserApproval("app_settings", args: ["action": "review"]))
    #expect(!ChatToolRegistry.requiresUserApproval("app_settings", args: ["action": "dismiss"]))
    #expect(!ChatToolRegistry.allowsChatWideApproval("app_settings"))
  }

  @Test("The set approval card lists title and from → to")
  func approvalSummaryLines() {
    let f = Fixture()
    f.setAllGood()
    f.defaults.set(false, forKey: UserDefaultsKeys.promptSendsFocusedFieldText)
    let text = AppSettingsChatTool.approvalSummary(
      args: ["action": "set", "changes": [["id": "dictate_prompt.field_text_context", "value": true]]],
      catalog: f.catalog)
    #expect(text.hasPrefix(String(localized: "Change settings:")))
    #expect(text.contains("→"))
  }

  @Test("app_settings is declared for cloud models and not for the on-device one")
  func declared() {
    func names(_ provider: ChatModelProvider) -> [String] {
      ChatToolRegistry.allDeclarations(
        calendarConnected: false, trelloConnected: false, imageGenerationAvailable: false,
        meetingContext: false, workspaceAvailable: false, workspaceWritable: false,
        mailAvailable: false, mailAccountsConnected: false, usageDataAvailable: false,
        chatProvider: provider).compactMap { $0["name"] as? String }
    }
    #expect(names(.gemini).contains("app_settings"))
    #expect(names(.localMLX).isEmpty)
  }

  @Test("set applies through the MCP path, is logged and undoable; dismiss suppresses")
  func executeSetAndDismiss() {
    let env = MCPTestEnv(level: .apply)
    let f = Fixture()
    f.defaults.set(false, forKey: UserDefaultsKeys.promptSendsFocusedFieldText)
    let before = env.changeLog.changes.count
    let applier = env.tools().env.applier
    let result = AppSettingsChatTool.execute(
      args: ["action": "set", "changes": [["id": "dictate_prompt.field_text_context", "value": true]]],
      catalog: env.settingsCatalog, deps: f.deps, suppressions: f.suppressions, applier: applier)
    #expect(result["status"] as? String == "applied")
    #expect(env.testDefaults.bool(forKey: UserDefaultsKeys.promptSendsFocusedFieldText))
    #expect(env.changeLog.changes.count == before + 1)

    let dismissed = AppSettingsChatTool.execute(
      args: ["action": "dismiss", "ids": ["clipboard.auto_paste"]],
      catalog: env.settingsCatalog, deps: f.deps, suppressions: f.suppressions, applier: applier)
    #expect(dismissed["status"] as? String == "dismissed")
    #expect(f.suppressions.isSuppressed(id: "clipboard.auto_paste", currentValue:
      SettingsAdvisor.currentLabel(forFindingID: "clipboard.auto_paste", catalog: env.settingsCatalog) ?? ""))
  }

  @Test("A declined set card suppresses its findings")
  func declinedSuppresses() {
    let f = Fixture()
    f.setAllGood()
    f.defaults.set(false, forKey: UserDefaultsKeys.promptSendsFocusedFieldText)
    AppSettingsChatTool.suppressDeclined(
      args: ["action": "set", "changes": [["id": "dictate_prompt.field_text_context", "value": true]]],
      catalog: f.catalog, suppressions: f.suppressions)
    #expect(f.ids().isEmpty)
  }

  @Test("Save usage data is reachable from the Chat but never through MCP get_settings or update_settings")
  func usageDataStaysOutOfMCP() {
    let env = MCPTestEnv(level: .apply)
    let listed = env.tools().call(name: "get_settings", arguments: [:], access: .write)
    #expect(!listed.text.contains("privacy.save_usage_data"))
    let r = env.tools().call(
      name: "update_settings", arguments: ["changes": ["privacy.save_usage_data": true], "rationale": "r"], access: .write)
    #expect(r.isError)
    #expect(!env.testDefaults.bool(forKey: UserDefaultsKeys.contextLoggingEnabled))
  }

  // MARK: - /improve without the model

  @MainActor
  @Test("The deterministic /improve message says the setup looks good, then the footer")
  func offlineMessageNoFindings() {
    let text = ChatViewModel.improveOfflineMessage(findings: [], footer: "FOOTER")
    #expect(text.contains(String(localized: "Your setup looks good.")))
    #expect(text.hasSuffix("\n\nFOOTER"))
  }

  @MainActor
  @Test("The deterministic /improve message lists at most three findings")
  func offlineMessageFindings() {
    let f = Fixture()
    f.launchAtLogin = false
    for key in [UserDefaultsKeys.autoPasteAfterDictation, UserDefaultsKeys.promptSendsFocusedFieldText,
                UserDefaultsKeys.screenshotInPromptMode, UserDefaultsKeys.contextLoggingEnabled] {
      f.defaults.set(false, forKey: key)
    }
    let text = ChatViewModel.improveOfflineMessage(findings: f.findings(), footer: "FOOTER")
    #expect(text.components(separatedBy: "• **").count - 1 == 3)
    #expect(text.hasSuffix("FOOTER"))
  }
}

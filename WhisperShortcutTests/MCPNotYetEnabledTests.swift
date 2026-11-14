import XCTest

@testable import WhisperShortcut_AppStore

/// `get_configuration` → `not_yet_enabled`, the MCP projection of `SettingsAdvisor`.
final class MCPNotYetEnabledTests: XCTestCase {

  /// Fake permissions and an isolated defaults suite, via `MCPTestEnv`. Starts with every
  /// feature on, both permissions granted and interactions shared.
  private final class Fixture {
    let env = MCPTestEnv()
    var interactionsShared = true

    init() {
      let d = env.testDefaults
      d.set(true, forKey: UserDefaultsKeys.autoPasteAfterDictation)
      d.set(true, forKey: UserDefaultsKeys.fnKeyDictation)
      d.set(true, forKey: UserDefaultsKeys.screenshotInPromptMode)
      d.set(true, forKey: UserDefaultsKeys.promptSendsFocusedFieldText)
      env.box.launchAtLogin = true
    }

    func set(_ key: String, _ on: Bool) { env.testDefaults.set(on, forKey: key) }

    func hints() -> [[String: Any]] {
      SettingsAdvisor.mcpNotYetEnabled(
        catalog: env.settingsCatalog, deps: env.settingsDeps, interactionsShared: interactionsShared)
    }
  }

  private func assertOnly(
    _ hints: [[String: Any]], id: String, state: String, howToEnable: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(hints.count, 1, file: file, line: line)
    XCTAssertEqual(hints.first?["id"] as? String, id, file: file, line: line)
    XCTAssertEqual(hints.first?["state"] as? String, state, file: file, line: line)
    XCTAssertEqual(hints.first?["how_to_enable"] as? String, howToEnable, file: file, line: line)
  }

  func testEverythingFineReturnsNothing() {
    XCTAssertTrue(Fixture().hints().isEmpty)
  }

  func testAutoPasteOffWithAccessibility() {
    let f = Fixture()
    f.set(UserDefaultsKeys.autoPasteAfterDictation, false)
    assertOnly(
      f.hints(), id: "clipboard.auto_paste", state: "off",
      howToEnable: "Ask the user, then update_settings clipboard.auto_paste = true.")
  }

  func testAutoPasteOffWithoutAccessibility() {
    let f = Fixture()
    f.set(UserDefaultsKeys.autoPasteAfterDictation, false)
    f.set(UserDefaultsKeys.fnKeyDictation, true)
    f.env.box.hasAccessibility = false
    let hints = f.hints().filter { ($0["id"] as? String) == "clipboard.auto_paste" }
    assertOnly(
      hints, id: "clipboard.auto_paste", state: "off_permission_missing",
      howToEnable:
        "The user grants Accessibility in WhisperShortcut Settings → Permissions (only they can), then you or they turn on clipboard.auto_paste.")
  }

  func testAutoPasteOnWithoutAccessibility() {
    let f = Fixture()
    f.env.box.hasAccessibility = false
    let hints = f.hints().filter { ($0["id"] as? String) == "clipboard.auto_paste" }
    assertOnly(
      hints, id: "clipboard.auto_paste", state: "on_but_permission_missing",
      howToEnable:
        "Auto-paste is on but cannot paste without Accessibility. The user grants it in WhisperShortcut Settings → Permissions.")
  }

  func testFrontWindowOffWithScreenRecording() {
    let f = Fixture()
    f.set(UserDefaultsKeys.screenshotInPromptMode, false)
    assertOnly(
      f.hints(), id: "dictate_prompt.screenshot_context", state: "off",
      howToEnable:
        "Propose update_settings dictate_prompt.screenshot_context = true; the user accepts it in WhisperShortcut.")
  }

  func testFrontWindowOffWithoutScreenRecording() {
    let f = Fixture()
    f.set(UserDefaultsKeys.screenshotInPromptMode, false)
    f.env.box.hasScreenRecording = false
    assertOnly(
      f.hints(), id: "dictate_prompt.screenshot_context", state: "off_permission_missing",
      howToEnable:
        "The user grants Screen Recording in WhisperShortcut Settings → Permissions, then turns on Front window picture in the Dictate Prompt settings.")
  }

  func testFrontWindowOnWithoutScreenRecording() {
    let f = Fixture()
    f.env.box.hasScreenRecording = false
    assertOnly(
      f.hints(), id: "dictate_prompt.screenshot_context", state: "on_but_permission_missing",
      howToEnable:
        "The setting is on but does nothing without Screen Recording. The user grants it in WhisperShortcut Settings → Permissions.")
  }

  func testRecentInteractionsNotShared() {
    let f = Fixture()
    f.interactionsShared = false
    assertOnly(
      f.hints(), id: "recent_interactions", state: "off",
      howToEnable:
        "The user turns on \"Save usage data\" and \"AI apps may read my recent dictations\" in WhisperShortcut Settings.")
  }

  func testFnKeyOffIsListed() throws {
    let f = Fixture()
    let fn = try XCTUnwrap(f.env.settingsCatalog.first { $0.id == "dictation.fn_key" })
    try XCTSkipIf(fn.unavailableReason() != nil, "Fn key is direct-download only.")
    f.set(UserDefaultsKeys.fnKeyDictation, false)
    assertOnly(
      f.hints(), id: "dictation.fn_key", state: "off",
      howToEnable: "Ask the user, then update_settings dictation.fn_key = true.")
  }

  func testLaunchAtLoginOffIsListed() {
    let f = Fixture()
    f.env.box.launchAtLogin = false
    assertOnly(
      f.hints(), id: "general.launch_at_login", state: "off",
      howToEnable:
        "Ask the user, then propose update_settings general.launch_at_login = true; the user accepts it in WhisperShortcut.")
  }

  func testFieldTextContextOffIsListed() {
    let f = Fixture()
    f.set(UserDefaultsKeys.promptSendsFocusedFieldText, false)
    assertOnly(
      f.hints(), id: "dictate_prompt.field_text_context", state: "off",
      howToEnable: "Ask the user, then update_settings dictate_prompt.field_text_context = true.")
  }

  func testOffFeaturesStayInProjectionOrder() {
    let f = Fixture()
    f.set(UserDefaultsKeys.autoPasteAfterDictation, false)
    f.set(UserDefaultsKeys.screenshotInPromptMode, false)
    f.set(UserDefaultsKeys.promptSendsFocusedFieldText, false)
    f.env.box.launchAtLogin = false
    f.interactionsShared = false
    let ids = f.hints().compactMap { $0["id"] as? String }
    XCTAssertEqual(
      ids,
      ["clipboard.auto_paste", "dictate_prompt.screenshot_context", "dictate_prompt.field_text_context",
       "general.launch_at_login", "recent_interactions"])
  }

  func testSuppressionsNeverHideAnMCPHint() {
    let f = Fixture()
    f.set(UserDefaultsKeys.autoPasteAfterDictation, false)
    ImproveSuppressions(defaults: f.env.testDefaults).suppress(id: "clipboard.auto_paste", currentValue: "Off")
    XCTAssertEqual(f.hints().compactMap { $0["id"] as? String }, ["clipboard.auto_paste"])
  }

  func testChatOnlyEntriesNeverAppear() {
    let f = Fixture()
    // Everything off, nothing granted, nothing shared, usage data off, writing style off.
    for key in [
      UserDefaultsKeys.autoPasteAfterDictation, UserDefaultsKeys.fnKeyDictation,
      UserDefaultsKeys.screenshotInPromptMode, UserDefaultsKeys.promptSendsFocusedFieldText,
      UserDefaultsKeys.contextLoggingEnabled, UserDefaultsKeys.writingStyleEnabled,
    ] { f.set(key, false) }
    f.env.box.launchAtLogin = false
    f.env.box.hasAccessibility = false
    f.env.box.hasScreenRecording = false
    f.interactionsShared = false
    let ids = f.hints().compactMap { $0["id"] as? String }
    XCTAssertFalse(ids.isEmpty)
    for id in ids {
      XCTAssertFalse(id.hasSuffix(".model") || id == "dictation.transcription_model", id)
      XCTAssertNotEqual(id, "writing_style.enabled")
      XCTAssertNotEqual(id, "privacy.save_usage_data")
    }
  }

  func testGetConfigurationListsNotYetEnabledWhenAutoPasteIsOff() throws {
    let f = Fixture()
    f.set(UserDefaultsKeys.autoPasteAfterDictation, false)
    let result = f.env.tools().call(name: "get_configuration", arguments: [:], access: .read)
    XCTAssertFalse(result.isError)
    XCTAssertTrue(result.text.contains("not_yet_enabled"))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
    let hints = try XCTUnwrap(object["not_yet_enabled"] as? [[String: Any]])
    XCTAssertEqual(hints.first?["id"] as? String, "clipboard.auto_paste")
    XCTAssertEqual(hints.first?["state"] as? String, "off")
  }
}

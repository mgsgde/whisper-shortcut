import XCTest

@testable import WhisperShortcut_AppStore

final class MCPFeatureHintsTests: XCTestCase {

  private func state(
    autoPaste: Bool = true,
    accessibility: Bool = true,
    frontWindowFallback: Bool = true,
    screenRecording: Bool = true,
    interactionsShared: Bool = true
  ) -> MCPFeatureState {
    MCPFeatureState(
      autoPaste: autoPaste, accessibility: accessibility, frontWindowFallback: frontWindowFallback,
      screenRecording: screenRecording, interactionsShared: interactionsShared)
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
    XCTAssertTrue(MCPFeatureHints.build(state()).isEmpty)
  }

  func testAutoPasteOffWithAccessibility() {
    assertOnly(
      MCPFeatureHints.build(state(autoPaste: false)),
      id: "clipboard.auto_paste", state: "off",
      howToEnable: "Ask the user, then update_settings clipboard.auto_paste = true.")
  }

  func testAutoPasteOffWithoutAccessibility() {
    assertOnly(
      MCPFeatureHints.build(state(autoPaste: false, accessibility: false)),
      id: "clipboard.auto_paste", state: "off_permission_missing",
      howToEnable:
        "The user grants Accessibility in WhisperShortcut Settings → Permissions (only they can), then you or they turn on clipboard.auto_paste.")
  }

  func testAutoPasteOnWithoutAccessibility() {
    assertOnly(
      MCPFeatureHints.build(state(accessibility: false)),
      id: "clipboard.auto_paste", state: "on_but_permission_missing",
      howToEnable:
        "Auto-paste is on but cannot paste without Accessibility. The user grants it in WhisperShortcut Settings → Permissions.")
  }

  func testFrontWindowOffWithScreenRecording() {
    assertOnly(
      MCPFeatureHints.build(state(frontWindowFallback: false)),
      id: "dictate_prompt.screenshot_context", state: "off",
      howToEnable:
        "Propose update_settings dictate_prompt.screenshot_context = true; the user accepts it in WhisperShortcut.")
  }

  func testFrontWindowOffWithoutScreenRecording() {
    assertOnly(
      MCPFeatureHints.build(state(frontWindowFallback: false, screenRecording: false)),
      id: "dictate_prompt.screenshot_context", state: "off_permission_missing",
      howToEnable:
        "The user grants Screen Recording in WhisperShortcut Settings → Permissions, then turns on Front window as fallback in the Dictate Prompt settings.")
  }

  func testFrontWindowOnWithoutScreenRecording() {
    assertOnly(
      MCPFeatureHints.build(state(screenRecording: false)),
      id: "dictate_prompt.screenshot_context", state: "on_but_permission_missing",
      howToEnable:
        "The setting is on but does nothing without Screen Recording. The user grants it in WhisperShortcut Settings → Permissions.")
  }

  func testRecentInteractionsNotShared() {
    assertOnly(
      MCPFeatureHints.build(state(interactionsShared: false)),
      id: "recent_interactions", state: "off",
      howToEnable:
        "The user turns on \"Save usage data\" and \"AI apps may read my recent dictations\" in WhisperShortcut Settings.")
  }

  func testOffFeaturesStayInCatalogOrder() {
    let hints = MCPFeatureHints.build(state(
      autoPaste: false, frontWindowFallback: false, interactionsShared: false))
    XCTAssertEqual(
      hints.compactMap { $0["id"] as? String },
      ["clipboard.auto_paste", "dictate_prompt.screenshot_context", "recent_interactions"])
    XCTAssertEqual(hints.compactMap { $0["state"] as? String }, ["off", "off", "off"])
  }

  func testGetConfigurationListsNotYetEnabledWhenAutoPasteIsOff() throws {
    var environment = MCPTestEnv().tools().env
    environment.featureState = {
      MCPFeatureState(
        autoPaste: false, accessibility: true, frontWindowFallback: true, screenRecording: true,
        interactionsShared: true)
    }
    let result = MCPConfigTools(env: environment).call(
      name: "get_configuration", arguments: [:], access: .read)
    XCTAssertFalse(result.isError)
    XCTAssertTrue(result.text.contains("not_yet_enabled"))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
    let hints = try XCTUnwrap(object["not_yet_enabled"] as? [[String: Any]])
    XCTAssertEqual(hints.count, 1)
    XCTAssertEqual(hints.first?["id"] as? String, "clipboard.auto_paste")
    XCTAssertEqual(hints.first?["state"] as? String, "off")
  }
}

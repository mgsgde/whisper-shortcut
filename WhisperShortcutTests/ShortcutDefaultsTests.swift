import AppKit
import Foundation
import HotKey
import Testing

@testable import WhisperShortcut_AppStore

/// New installs must not get bare ⌘-digit shortcuts (they switch tabs in browsers, Slack, VS
/// Code), and the pinned legacy set for existing installs must be exactly what they had.
@Suite("Shortcut defaults")
struct ShortcutDefaultsTests {

  private func all(_ c: ShortcutConfig) -> [ShortcutDefinition] {
    [c.startRecording, c.startPrompting, c.openSettings, c.openChat, c.screenshotCapture,
     c.readAloud, c.readAloudPrompt, c.addToGlossary]
  }

  @Test("New-install defaults avoid bare ⌘-digits and do not collide")
  func newDefaults() {
    let defs = all(ShortcutConfig.default)
    #expect(!defs.contains { $0.modifiers == [.command] })
    #expect(Set(defs.map { "\($0.key)-\($0.modifiers.rawValue)" }).count == defs.count)
    #expect(ShortcutConfig.default.startRecording.modifiers == [.control, .option])
  }

  @Test("App Store availability disables only the hidden Read Aloud and Glossary slots")
  func availableInThisBuildDropsHiddenSlots() {
    var input = ShortcutConfig.default
    input.readAloud = ShortcutDefinition(
      key: .four, modifiers: [.control, .option], isEnabled: true, displayCharacter: "4")
    input.addToGlossary = ShortcutDefinition(
      key: .seven, modifiers: [.control, .option], isEnabled: true, displayCharacter: "7")

    let hidden = ShortcutConfig.availableInThisBuild(input, isAppStore: true)
    #expect(hidden.readAloud == ShortcutDefinition(
      key: input.readAloud.key, modifiers: input.readAloud.modifiers,
      isEnabled: false, displayCharacter: input.readAloud.displayCharacter))
    #expect(hidden.addToGlossary == ShortcutDefinition(
      key: input.addToGlossary.key, modifiers: input.addToGlossary.modifiers,
      isEnabled: false, displayCharacter: input.addToGlossary.displayCharacter))
    #expect(hidden.startRecording == input.startRecording)
    #expect(hidden.startPrompting == input.startPrompting)
    #expect(hidden.openSettings == input.openSettings)
    #expect(hidden.openChat == input.openChat)
    #expect(hidden.screenshotCapture == input.screenshotCapture)

    #expect(ShortcutConfig.availableInThisBuild(input, isAppStore: false) == input)
  }

  @Test("A hidden App Store Read Aloud binding does not reserve ⌃⌥4")
  func hiddenReadAloudDoesNotConflict() {
    let appStore = ShortcutConfig.availableInThisBuild(ShortcutConfig.default, isAppStore: true)
    #expect(ShortcutValidation.conflictingSlot(
      key: .four, modifiers: [.control, .option], in: appStore, excluding: "Toggle Dictation") == nil)

    let direct = ShortcutConfig.availableInThisBuild(ShortcutConfig.default, isAppStore: false)
    #expect(ShortcutValidation.conflictingSlot(
      key: .four, modifiers: [.control, .option], in: direct, excluding: "Toggle Dictation") == "Read Aloud")
  }

  @Test("App Store save leaves the hidden Read Aloud and Glossary bindings untouched")
  func appStoreSaveSkipsHiddenShortcutKeys() throws {
    let suiteName = "ShortcutDefaultsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let manager = ShortcutConfigManager(userDefaults: defaults)
    let readAloudKey = "shortcut_read_aloud"
    let glossaryKey = "shortcut_add_to_glossary"
    let readAloudPromptKey = "shortcut_read_aloud_prompt"
    let recordingKey = "shortcut_start_recording"

    // The direct download saved bindings for both; the App Store build then saves a config in
    // which they are disabled.
    var config = ShortcutConfig.default
    config.readAloud = ShortcutDefinition(key: .six, modifiers: [.control, .option], isEnabled: true)
    config.addToGlossary = ShortcutDefinition(key: .seven, modifiers: [.control, .option], isEnabled: true)
    config.readAloudPrompt = ShortcutDefinition(
      key: .eight, modifiers: [.control, .option, .shift], isEnabled: true)
    manager.saveConfiguration(config, isAppStore: false)
    let readAloudBefore = try #require(defaults.data(forKey: readAloudKey))
    let glossaryBefore = try #require(defaults.data(forKey: glossaryKey))
    let readAloudPromptBefore = try #require(defaults.data(forKey: readAloudPromptKey))

    let disabled = ShortcutConfig.availableInThisBuild(config, isAppStore: true)
    #expect(!disabled.readAloud.isEnabled)
    config = disabled
    config.startRecording = ShortcutDefinition(key: .nine, modifiers: [.control, .option])
    manager.saveConfiguration(config, isAppStore: true)

    #expect(defaults.data(forKey: readAloudKey) == readAloudBefore)
    #expect(defaults.data(forKey: glossaryKey) == glossaryBefore)
    #expect(defaults.data(forKey: readAloudPromptKey) == readAloudPromptBefore)
    // The other slots are still written.
    let saved = try JSONDecoder().decode(
      ShortcutDefinition.self, from: try #require(defaults.data(forKey: recordingKey)))
    #expect(saved.key == .nine)

    // The direct build writes the disabled state through like any other slot.
    manager.saveConfiguration(config, isAppStore: false)
    #expect(defaults.data(forKey: readAloudKey) != readAloudBefore)
  }

  @Test("Legacy defaults are the ⌘-digit set existing installs were running on")
  func legacyDefaults() {
    let legacy = ShortcutConfig.legacyCommandDigit
    #expect(legacy.startRecording == ShortcutDefinition(key: .one, modifiers: [.command]))
    #expect(legacy.openSettings.key == .zero && legacy.openSettings.modifiers == [.command])
    #expect(legacy.openChat == ShortcutConfig.default.openChat)
  }

  @Test("Read Aloud Prompt defaults to control-option-shift-4, enabled, and does not collide")
  func readAloudPromptDefault() {
    let prompt = ShortcutConfig.default.readAloudPrompt
    #expect(prompt == ShortcutDefinition(
      key: .four, modifiers: [.control, .option, .shift], isEnabled: true))
    let defs = all(ShortcutConfig.default)
    #expect(Set(defs.map { "\($0.key)-\($0.modifiers.rawValue)" }).count == defs.count)
    let others = defs.filter { $0.key != prompt.key || $0.modifiers != prompt.modifiers }
    #expect(others.count == defs.count - 1)
  }

  @Test("App Store availability disables Read Aloud Prompt")
  func readAloudPromptHiddenOnAppStore() {
    let input = ShortcutConfig.default
    #expect(input.readAloudPrompt.isEnabled)
    let hidden = ShortcutConfig.availableInThisBuild(input, isAppStore: true)
    #expect(!hidden.readAloudPrompt.isEnabled)
    #expect(hidden.readAloudPrompt.key == input.readAloudPrompt.key)
    #expect(hidden.readAloudPrompt.modifiers == input.readAloudPrompt.modifiers)
    #expect(ShortcutConfig.availableInThisBuild(input, isAppStore: false).readAloudPrompt.isEnabled)
  }

  @Test("Read Aloud Prompt save/load round trip")
  func readAloudPromptRoundTrip() throws {
    let suiteName = "ShortcutDefaultsTests.readAloudPrompt.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let manager = ShortcutConfigManager(userDefaults: defaults)
    let key = "shortcut_read_aloud_prompt"

    var config = ShortcutConfig.default
    config.readAloudPrompt = ShortcutDefinition(
      key: .eight, modifiers: [.control, .option, .shift], isEnabled: true, displayCharacter: "8")
    manager.saveConfiguration(config, isAppStore: false)

    let stored = try JSONDecoder().decode(
      ShortcutDefinition.self, from: try #require(defaults.data(forKey: key)))
    #expect(stored == config.readAloudPrompt)

    // This test bundle is the App Store target, so loadConfiguration forces the slot off.
    // The stored binding itself is unchanged.
    let loaded = manager.loadConfiguration()
    #expect(loaded.readAloudPrompt.key == .eight)
    #expect(loaded.readAloudPrompt.modifiers == [.control, .option, .shift])
    #expect(loaded.readAloudPrompt.displayCharacter == "8")
    #expect(!loaded.readAloudPrompt.isEnabled)
    let storedAfterLoad = try JSONDecoder().decode(
      ShortcutDefinition.self, from: try #require(defaults.data(forKey: key)))
    #expect(storedAfterLoad == config.readAloudPrompt)
  }
}

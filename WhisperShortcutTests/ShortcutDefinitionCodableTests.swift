import AppKit
import Foundation
import HotKey
import Testing

@testable import WhisperShortcut_AppStore

/// Persistence for a single hotkey binding. `ShortcutConfigManager` JSON-encodes this into
/// UserDefaults; a decode miss falls back to the shipped default and the user's combo is lost.
@Suite("ShortcutDefinition Codable")
struct ShortcutDefinitionCodableTests {

  @Test("A binding round-trips through JSONEncoder")
  func roundTrip() throws {
    let original = ShortcutDefinition(
      key: .one,
      modifiers: [.control, .option],
      isEnabled: true,
      displayCharacter: "1")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ShortcutDefinition.self, from: data)
    #expect(decoded == original)
    #expect(decoded.displayCharacter == "1")
  }

  @Test("A missing isEnabled defaults to enabled")
  func missingEnabledDefaultsTrue() throws {
    // The shape `ShortcutConfigManager.loadShortcut` reads: carbon key code + modifier rawValue.
    let encoded = ShortcutDefinition(key: .two, modifiers: [.command], isEnabled: true)
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(encoded)) as! [String: Any]
    object.removeValue(forKey: "isEnabled")
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(ShortcutDefinition.self, from: data)
    #expect(decoded.isEnabled)
    #expect(decoded.key == .two)
    #expect(decoded.modifiers == [.command])
  }

  @Test("Equality ignores displayCharacter")
  func equalityIgnoresDisplayCharacter() {
    let a = ShortcutDefinition(key: .z, modifiers: [.command], displayCharacter: "Y")
    let b = ShortcutDefinition(key: .z, modifiers: [.command], displayCharacter: "Z")
    #expect(a == b)
    #expect(Set([a, b]).count == 1)
  }

  @Test("A disabled binding displays as Disabled")
  func disabledDisplayString() {
    let disabled = ShortcutDefinition(
      key: .one, modifiers: [.control, .option], isEnabled: false)
    #expect(disabled.displayString == "Disabled")
    #expect(disabled.displayStringWithSeparator == "Disabled")
  }

  @Test("The full ShortcutConfig Codable round-trip keeps every slot")
  func configRoundTrip() throws {
    let original = ShortcutConfig.default
    let decoded = try JSONDecoder().decode(
      ShortcutConfig.self, from: JSONEncoder().encode(original))
    #expect(decoded == original)
  }
}

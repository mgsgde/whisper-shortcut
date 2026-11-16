import AppKit
import Foundation
import HotKey
import Testing
@testable import WhisperShortcut_AppStore

/// The Shortcuts tab's conflict lookup must see keys held by templates and the Template key,
/// not only the app's own slots.
@Suite("Template key conflicts in the Shortcuts tab")
struct TemplateKeyConflictTests {

  private func key(_ k: Key, _ m: NSEvent.ModifierFlags = .command, enabled: Bool = true)
    -> ShortcutDefinition
  {
    ShortcutDefinition(key: k, modifiers: m, isEnabled: enabled)
  }

  private func template(_ name: String, instructions: String = "Gliedere.", shortcut: ShortcutDefinition?)
    -> DictationTemplate
  {
    DictationTemplate(name: name, instructions: instructions, shortcut: shortcut)
  }

  @Test("A template's own key is a conflict that names the template")
  func templateKeyConflicts() throws {
    let anamnese = template("Anamnese", shortcut: key(.six))
    let conflict = try #require(
      SettingsViewModel.templateKeyConflict(key(.six), templates: [anamnese], pickerShortcut: nil))
    #expect(conflict.field == .templateShortcut(anamnese.id))
    #expect(conflict.label.contains("Anamnese"))
  }

  @Test("A different key or modifier is free")
  func otherKeyIsFree() {
    let t = template("Anamnese", shortcut: key(.six))
    #expect(SettingsViewModel.templateKeyConflict(key(.seven), templates: [t], pickerShortcut: nil) == nil)
    #expect(
      SettingsViewModel.templateKeyConflict(key(.six, [.command, .shift]), templates: [t], pickerShortcut: nil)
        == nil)
  }

  @Test("Disabled shortcuts and templates without instructions do not count")
  func inactiveOwnersIgnored() {
    let off = template("Aus", shortcut: key(.six, enabled: false))
    let empty = template("Leer", instructions: "  ", shortcut: key(.six))
    #expect(SettingsViewModel.templateKeyConflict(key(.six), templates: [off, empty], pickerShortcut: nil) == nil)
  }

  @Test("The Template key is a conflict and wins over a template on the same key")
  func pickerWins() throws {
    let t = template("Anamnese", shortcut: key(.six))
    let conflict = try #require(
      SettingsViewModel.templateKeyConflict(key(.six), templates: [t], pickerShortcut: key(.six)))
    #expect(conflict.field == .templatePickerShortcut)
  }

  @Test("The Template key without a usable template is not active, so no conflict")
  func pickerInactiveWithoutTemplates() {
    #expect(SettingsViewModel.templateKeyConflict(key(.six), templates: [], pickerShortcut: key(.six)) == nil)
  }
}

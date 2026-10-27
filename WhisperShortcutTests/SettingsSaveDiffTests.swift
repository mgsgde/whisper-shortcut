import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// `saveSettings()` writes only the slots that differ from the last persisted snapshot, so a
/// value changed elsewhere (Chat `/model`, `/pin`) is not overwritten by a stale Settings window.
/// Hermetic: the slots here are test slots that record writes in memory, never UserDefaults.
@Suite("Settings save diff")
@MainActor
struct SettingsSaveDiffTests {

  private final class Writes { var keys: [String] = [] }

  @Test("differs is false for equal data and true per slot kind when a value changes")
  func differsPerSlotKind() {
    var a = SettingsData()
    var b = a
    let bool = SettingsSlot.bool(\.chatCloseOnFocusLoss, key: "test.bool", default: false)
    let string = SettingsSlot.string(\.readAloudVoiceGemini, key: "test.string")
    let raw = SettingsSlot.rawValue(\.whisperLanguage, key: "test.raw", default: .auto)
    let custom = SettingsSlot.custom(\.selectedChatModel, load: { a.selectedChatModel }, save: { _ in })

    for slot in [bool, string, raw, custom] { #expect(!slot.differs(a, b)) }

    b.chatCloseOnFocusLoss.toggle()
    #expect(bool.differs(a, b))
    #expect(!string.differs(a, b))

    b = a
    b.readAloudVoiceGemini = "Kore"
    #expect(string.differs(a, b))
    #expect(!bool.differs(a, b))

    b = a
    b.whisperLanguage = WhisperLanguage.allCases.first { $0 != a.whisperLanguage } ?? .auto
    #expect(raw.differs(a, b) == (a.whisperLanguage != b.whisperLanguage))

    b = a
    a.selectedChatModel = SettingsDefaults.selectedChatModel
    b.selectedChatModel = PromptModel.allCases.first { $0 != a.selectedChatModel } ?? a.selectedChatModel
    #expect(custom.differs(a, b) == (a.selectedChatModel != b.selectedChatModel))
  }

  @Test("With persisted equal to data nothing is written; only the changed slot is")
  func slotsToSaveFilters() {
    let writes = Writes()
    let slots: [SettingsSlot] = [
      .custom(\.chatCloseOnFocusLoss, load: { false }, save: { _ in writes.keys.append("chat") }),
      .custom(\.fnKeyDictation, load: { false }, save: { _ in writes.keys.append("fn") }),
    ]
    let persisted = SettingsData()
    var data = persisted

    for slot in SettingsSlot.slotsToSave(slots, data: data, persisted: persisted) { slot.save(data) }
    #expect(writes.keys.isEmpty)

    data.fnKeyDictation.toggle()
    for slot in SettingsSlot.slotsToSave(slots, data: data, persisted: persisted) { slot.save(data) }
    #expect(writes.keys == ["fn"])
  }

  @Test("ShortcutConfig equality tracks a changed shortcut")
  func shortcutConfigEquatable() {
    var data = SettingsData()
    data.toggleDictation = ShortcutConfig.default.startRecording
    var changed = data
    #expect(SettingsViewModel.shortcutConfig(from: data) == SettingsViewModel.shortcutConfig(from: changed))
    changed.toggleDictation = nil
    #expect(SettingsViewModel.shortcutConfig(from: data) != SettingsViewModel.shortcutConfig(from: changed))
  }
}

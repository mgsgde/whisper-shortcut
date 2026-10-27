import Foundation

/// One persisted setting: how to read it into `SettingsData`, and how to write it back.
///
/// Settings used to be spelled out twice — once in `loadCurrentSettings()`, once in
/// `saveSettings()` — in two lists that had to stay in the same order and use matching keys.
/// Nothing enforced that, and the two sides had already drifted in idiom: several settings were
/// *read* through a migrating loader (which forwards a renamed/legacy value to its replacement)
/// but *written* with a raw `UserDefaults.set`, so the save path didn't know migration existed.
///
/// Declaring both halves together makes that class of drift unrepresentable: a slot cannot load
/// from one key and save to another, and adding a setting is one line instead of four.
struct SettingsSlot {
  let load: (inout SettingsData) -> Void
  let save: (SettingsData) -> Void
  /// Whether this slot's value differs between two snapshots. `SettingsViewModel.saveSettings()`
  /// writes only slots that differ from what it last loaded or saved, so a value changed elsewhere
  /// (Chat `/model`, `/pin`) is not overwritten by a stale copy held by a long-lived Settings window.
  let differs: (SettingsData, SettingsData) -> Bool
  /// Fired by `saveSettings()` after this slot is written, and only then.
  ///
  /// Model pickers used to `UserDefaults.set` the same key the slot already saves, then post
  /// `.modelChanged` or `.promptModelChanged` themselves. Dictate posted `.modelChanged` a second
  /// time from `saveSettings`, so one picker change notified twice, and a save that did not touch
  /// the model could still have been preceded by a notice from the picker. The notice now lives
  /// on the slot, with the same name and object as before, and a slot that did not change cannot
  /// post one.
  let onDidChange: ((SettingsData) -> Void)?

  /// The slots whose value in `data` differs from `persisted` — the ones a save must write.
  static func slotsToSave(_ slots: [SettingsSlot], data: SettingsData, persisted: SettingsData)
    -> [SettingsSlot]
  {
    slots.filter { $0.differs(data, persisted) }
  }
}

extension SettingsSlot {
  /// Full control over both halves — for settings whose load routes through a migrating loader
  /// (`PromptModel.loadChatSlotModel`, `TranscriptionModel.loadSelected`, …) or a preference
  /// namespace (`ReadAloudPreferences`, `ScreenshotSaveLocation`).
  static func custom<Value: Equatable>(
    _ keyPath: WritableKeyPath<SettingsData, Value>,
    load: @escaping () -> Value,
    save: @escaping (Value) -> Void,
    onDidChange: ((SettingsData) -> Void)? = nil
  ) -> SettingsSlot {
    SettingsSlot(
      load: { data in data[keyPath: keyPath] = load() },
      save: { data in save(data[keyPath: keyPath]) },
      differs: { lhs, rhs in lhs[keyPath: keyPath] != rhs[keyPath: keyPath] },
      onDidChange: onDidChange
    )
  }

  /// An enum persisted as its `String` raw value. Unknown/absent raw values fall back to
  /// `fallback` — no migration, so only use it for enums that have never been renamed.
  static func rawValue<Value: RawRepresentable & Equatable>(
    _ keyPath: WritableKeyPath<SettingsData, Value>,
    key: String,
    default fallback: Value
  ) -> SettingsSlot where Value.RawValue == String {
    .custom(
      keyPath,
      load: {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let parsed = Value(rawValue: raw)
        else { return fallback }
        return parsed
      },
      save: { UserDefaults.standard.set($0.rawValue, forKey: key) }
    )
  }

  /// A `Bool` persisted under `key`, falling back to `fallback` when never written.
  static func bool(
    _ keyPath: WritableKeyPath<SettingsData, Bool>,
    key: String,
    default fallback: Bool
  ) -> SettingsSlot {
    .custom(
      keyPath,
      load: { UserDefaults.standard.bool(forKey: key, default: fallback) },
      save: { UserDefaults.standard.set($0, forKey: key) }
    )
  }

  /// A `String` persisted under `key`. Empty string is the "unset" sentinel throughout the app
  /// (e.g. a Read Aloud voice of "" means "use the provider's default voice").
  static func string(
    _ keyPath: WritableKeyPath<SettingsData, String>,
    key: String,
    default fallback: String = ""
  ) -> SettingsSlot {
    .custom(
      keyPath,
      load: { UserDefaults.standard.string(forKey: key) ?? fallback },
      save: { UserDefaults.standard.set($0, forKey: key) }
    )
  }
}

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
}

extension SettingsSlot {
  /// Full control over both halves — for settings whose load routes through a migrating loader
  /// (`PromptModel.loadChatSlotModel`, `TranscriptionModel.loadSelected`, …) or a preference
  /// namespace (`ReadAloudPreferences`, `ScreenshotSaveLocation`).
  static func custom<Value>(
    _ keyPath: WritableKeyPath<SettingsData, Value>,
    load: @escaping () -> Value,
    save: @escaping (Value) -> Void
  ) -> SettingsSlot {
    SettingsSlot(
      load: { data in data[keyPath: keyPath] = load() },
      save: { data in save(data[keyPath: keyPath]) }
    )
  }

  /// An enum persisted as its `String` raw value. Unknown/absent raw values fall back to
  /// `fallback` — no migration, so only use it for enums that have never been renamed.
  static func rawValue<Value: RawRepresentable>(
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

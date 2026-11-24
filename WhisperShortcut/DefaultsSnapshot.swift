import Foundation

/// A fixed set of UserDefaults keys, saved under `storageKey` and put back later.
///
/// Two call sites share it, and each key belongs to exactly one of them.
/// `DictationOnlyDefaults` owns Offline Mode, language, dictate mode, punctuation and Fn.
/// `ModelSelectionReconciler` owns the model selections, including `selectedTranscriptionModel`.
///
/// Restore order when Dictation only turns off: `DictationOnlyDefaults.restore` runs first and
/// puts its own keys back, then calls `OfflineMode.switchTo`. That runs the reconciler, which
/// restores the model snapshot. The transcription model is not in the dictation snapshot, so the
/// two writes cannot land on the same key. A dictation snapshot saved before that split still
/// contains `selectedTranscriptionModel`; restoring those bytes writes it, and the model snapshot
/// (the owner) runs afterwards.
///
/// On disk the two shapes stay as they were. Dictation only stores `present` / `absent` (and
/// `applied`, which that call site adds). The model snapshot stores a string map and the
/// `__unset__` sentinel for a key that had no value. Both shapes still restore.
struct DefaultsSnapshot {
  static let presentKey = "present"
  static let absentKey = "absent"
  static let appliedKey = "applied"
  /// Stored in `applied` for a key the pass left unset. Same spelling as `absentKey`.
  static let absentMarker = "absent"
  /// Stored in the model snapshot for a key that had no value.
  static let unsetSentinel = "__unset__"

  let keys: [String]
  let storageKey: String

  init(keys: [String], storageKey: String) {
    self.keys = keys
    self.storageKey = storageKey
  }

  /// `present` / `absent` for `keys`. Does nothing when a snapshot is already stored.
  func savePresentAbsentIfNeeded(defaults: UserDefaults) {
    guard defaults.dictionary(forKey: storageKey) == nil else { return }
    var present: [String: Any] = [:]
    var absent: [String] = []
    for key in keys {
      if let value = defaults.object(forKey: key) { present[key] = value } else { absent.append(key) }
    }
    defaults.set([Self.presentKey: present, Self.absentKey: absent], forKey: storageKey)
  }

  struct PresentAbsent {
    var present: [String: Any]
    var absent: [String]
    var applied: [String: Any]?
    /// `keys`, then any key the stored snapshot has that this list no longer names.
    var capturedKeys: [String]
  }

  func loadPresentAbsent(defaults: UserDefaults) -> PresentAbsent? {
    guard let stored = defaults.dictionary(forKey: storageKey) else { return nil }
    let present = stored[Self.presentKey] as? [String: Any] ?? [:]
    let absent = stored[Self.absentKey] as? [String] ?? []
    var captured: [String] = []
    var seen = Set<String>()
    func add(_ key: String) {
      guard seen.insert(key).inserted else { return }
      captured.append(key)
    }
    for key in keys { add(key) }
    for key in present.keys.sorted() { add(key) }
    for key in absent { add(key) }
    return PresentAbsent(
      present: present, absent: absent, applied: stored[Self.appliedKey] as? [String: Any],
      capturedKeys: captured)
  }

  func stringMap(in defaults: UserDefaults) -> [String: String]? {
    defaults.dictionary(forKey: storageKey) as? [String: String]
  }

  func setStringMap(_ map: [String: String], defaults: UserDefaults) {
    defaults.set(map, forKey: storageKey)
  }

  /// Puts a `__unset__` map back and removes the snapshot. `onEach` runs after the write.
  func restoreUnsetSentinel(
    defaults: UserDefaults, onEach: (_ key: String, _ stored: String) -> Void = { _, _ in }
  ) {
    guard let snapshot = stringMap(in: defaults) else { return }
    for (key, value) in snapshot {
      if value == Self.unsetSentinel {
        defaults.removeObject(forKey: key)
      } else {
        defaults.set(value, forKey: key)
      }
      onEach(key, value)
    }
    defaults.removeObject(forKey: storageKey)
  }
}

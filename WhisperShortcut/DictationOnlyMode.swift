//
//  DictationOnlyMode.swift
//  WhisperShortcut
//
//  "Dictation only": the same app showing only dictation. One UserDefaults bool decides; the
//  rest of this file is pure functions that take that bool as a parameter, so what the mode
//  shows and hides is testable without switching the real mode on. The mode only hides: no
//  stored binding, setting or data is changed by turning it on or off. Spec:
//  plans/active/dictation-only-mode.md.
//

import Foundation

extension Notification.Name {
  /// Posted by `DictationOnlyMode.setEnabled` after the flag changed. Shortcuts re-register and
  /// the status menu refreshes on it.
  static let dictationOnlyModeChanged = Notification.Name("dictationOnlyModeChanged")
}

/// A status-menu row the mode decides about. Rows that always show (history, feedback, tour,
/// stop, status) are not listed: the mode never touches them.
enum StatusMenuRow: CaseIterable {
  case dictate
  case dictateLive
  case addToGlossary
  case dictatePrompt
  case readAloud
  case readAloudPrompt
  case screenshot
  case liveMeeting
  /// "Retry Meeting Transcription" and its ⌥ alternate.
  case meetingBacklog
  case chat
  case aiAppProposals
  case settings
  case updates
  case quit
}

/// A global shortcut slot the mode decides about.
enum ShortcutSlot: CaseIterable {
  case dictate
  case dictateLive
  case addToGlossary
  case dictatePrompt
  case readAloud
  case readAloudPrompt
  case screenshot
  case chat
  case openSettings
  /// Per-template shortcuts and the template picker.
  case templates
}

enum DictationOnlyMode {

  // MARK: - Flag

  /// Whether the mode is on. Off unless set; an unset key reads `false`.
  static var isEnabled: Bool {
    if let testOverride, TestHost.isActive { return testOverride }
    return UserDefaults.standard.bool(forKey: UserDefaultsKeys.dictationOnlyMode)
  }

  /// Test seam: forces `isEnabled` inside the XCTest host. Ignored outside it.
  nonisolated(unsafe) static var testOverride: Bool?

  /// Writes the flag and posts `.dictationOnlyModeChanged`. Refuses, changing nothing, while a
  /// live meeting or a recording is running: the switch hides things, it never stops anything.
  /// Returns whether the flag was written.
  @discardableResult
  static func setEnabled(
    _ enabled: Bool, meetingActive: Bool, recording: Bool,
    defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default
  ) -> Bool {
    guard !meetingActive, !recording else {
      DebugLogger.log("DICTATION-ONLY: switch refused (meeting=\(meetingActive), recording=\(recording))")
      return false
    }
    defaults.set(enabled, forKey: UserDefaultsKeys.dictationOnlyMode)
    DebugLogger.log("DICTATION-ONLY: \(enabled ? "on" : "off")")
    notificationCenter.post(name: .dictationOnlyModeChanged, object: nil)
    return true
  }

  // MARK: - What the mode shows

  /// Settings tabs shown while the mode is on: General, Dictate, Permissions & Privacy, About.
  /// Accounts is added while the selected transcription model is a cloud model: that tab is the
  /// only place to enter its key, and the Dictate tab in this mode has no key field.
  private static let visibleTabSet: Set<SettingsTab> = [.general, .speechToText, .permissions, .about]

  static func visibleTabs(
    _ all: [SettingsTab], enabled: Bool,
    selectedModelIsCloud: Bool = !TranscriptionModel.loadSelected().isOffline
  ) -> [SettingsTab] {
    guard enabled else { return all }
    var kept = visibleTabSet
    if selectedModelIsCloud { kept.insert(.accounts) }
    return all.filter { kept.contains($0) }
  }

  /// Status-menu rows shown. With the mode off, every row.
  static func menuRows(enabled: Bool) -> [StatusMenuRow] {
    let kept: Set<StatusMenuRow> = [.dictate, .dictateLive, .addToGlossary, .settings, .updates, .quit]
    return enabled ? StatusMenuRow.allCases.filter { kept.contains($0) } : StatusMenuRow.allCases
  }

  /// Whether a global shortcut registers: the dictation ones (Dictate, Dictate Live, Add to
  /// Glossary) and Open Settings, which opens a window the mode keeps.
  static func registersShortcut(_ slot: ShortcutSlot, enabled: Bool) -> Bool {
    guard enabled else { return true }
    switch slot {
    case .dictate, .dictateLive, .addToGlossary, .openSettings: return true
    case .dictatePrompt, .readAloud, .readAloudPrompt, .screenshot, .chat, .templates: return false
    }
  }

  /// Backstop for entry points the mode hides but Services, popups or stale windows can still
  /// reach. Returns true (and logs) when the caller must return early.
  static func blocks(_ feature: String) -> Bool {
    guard isEnabled else { return false }
    DebugLogger.log("DICTATION-ONLY: \(feature) ignored, mode is on")
    return true
  }

  /// Where a "go to Settings → X" link lands. A hidden tab is never opened. Accounts stays
  /// reachable while a cloud transcription model is selected, because that tab holds its key.
  /// With an offline model, a missing key or credential is a dictation problem, so Accounts goes
  /// to Dictate; anything else that is hidden goes to General.
  static func reachableTab(
    _ tab: SettingsTab, enabled: Bool,
    selectedModelIsCloud: Bool = !TranscriptionModel.loadSelected().isOffline
  ) -> SettingsTab {
    if visibleTabs([tab], enabled: enabled, selectedModelIsCloud: selectedModelIsCloud).contains(tab) {
      return tab
    }
    return tab == .accounts ? .speechToText : .general
  }

  // MARK: - Download not finished

  /// What a dictation key press says while the one-time download is not done. One text for every
  /// path (Fn and Live, the Dictate shortcut, the menu): no model name, no "Dictate Live".
  static func downloadPendingMessage(downloadRunning: Bool) -> String {
    downloadRunning
      ? String(localized: "The download is still running. You can dictate as soon as it has finished.")
      : String(localized: "Dictation needs a one-time download first. Start it in Settings → Dictate.")
  }

  // MARK: - What is running

  /// What the Settings switch and the onboarding card need to know before they flip the flag.
  struct Activity: Equatable {
    var meetingActive: Bool
    var recording: Bool
    static let idle = Activity(meetingActive: false, recording: false)
  }

  /// Set by `MenuBarController`, which owns the app state. Nil (tests, early launch) reads idle.
  nonisolated(unsafe) static var activityProvider: (() -> Activity)?

  static var currentActivity: Activity {
    // Test profile only (`TestProfileOverrides`, `--recording-running`).
    if TestProfileOverrides.current.recordingRunning { return Activity(meetingActive: false, recording: true) }
    return activityProvider?() ?? .idle
  }
}

/// The Settings → General switch. It only writes the flag through `DictationOnlyMode.setEnabled`;
/// it never calls `DictationOnlyDefaults.apply` (spec decision 4), so switching the mode on in
/// Settings changes no model, language or Offline Mode. Switching off restores what the
/// onboarding card changed, if it did.
enum DictationOnlySettingsSwitch {
  enum Outcome: Equatable {
    case changed
    /// A meeting or recording is running; nothing was written.
    case refusedWhileBusy
  }

  @MainActor
  static func change(
    to enabled: Bool, activity: DictationOnlyMode.Activity,
    defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default,
    restoreDefaults: @MainActor () -> Void = { DictationOnlyDefaults.restore() }
  ) -> Outcome {
    let changed = DictationOnlyMode.setEnabled(
      enabled, meetingActive: activity.meetingActive, recording: activity.recording,
      defaults: defaults, notificationCenter: notificationCenter)
    // Switching off gives back what the onboarding card changed (a no-op when it never did).
    if changed, !enabled { restoreDefaults() }
    return changed ? .changed : .refusedWhileBusy
  }
}

// MARK: - First-run defaults

/// The defaults the "Dictation only" onboarding card applies, once. Nothing calls this at launch
/// and the Settings switch never does: the switch only hides and shows. What `apply` is about to
/// change is saved first, so turning the mode off (`restore`) puts the user's own values back.
enum DictationOnlyDefaults {

  /// Every key `apply` or the 🌐 step can change. Offline Mode is part of it: `apply` switches it
  /// on. Fn dictation is not written here; the 🌐 step turns it on later and records that through
  /// `recordApplied`, which only works because `apply` (and its snapshot) already ran.
  private static let snapshotKeys = [
    UserDefaultsKeys.offlineModeEnabled, UserDefaultsKeys.selectedTranscriptionModel,
    UserDefaultsKeys.whisperLanguage, UserDefaultsKeys.dictateMode, UserDefaultsKeys.punctuationMode,
    UserDefaultsKeys.fnKeyDictation,
  ]
  private static let snapshotPresent = "present"
  private static let snapshotAbsent = "absent"
  /// Values this pass wrote, keyed like `present`. A missing key is the string "absent", not a
  /// removed entry, so `restore` can tell "the tour left it unset" from "the tour never recorded".
  private static let snapshotApplied = "applied"

  enum LanguageOutcome: Equatable {
    /// Was Auto-detect; now the Mac's language.
    case set(WhisperLanguage)
    /// An explicit language was already chosen; left alone.
    case kept(WhisperLanguage)
    /// The Mac's language is not one the model transcribes. Language is still Auto-detect and
    /// the caller has to ask for an explicit pick.
    case needsExplicitPick

    /// The language now stored, nil while the user still has to pick one.
    var language: WhisperLanguage? {
      switch self {
      case .set(let language), .kept(let language): return language
      case .needsExplicitPick: return nil
      }
    }
  }

  struct Result: Equatable {
    var alreadyApplied: Bool
    var language: LanguageOutcome?
    var dictateMode: DictateMode?
  }

  /// Applies, in order: Offline Mode on, Parakeet selected, language, Dictate mode, spoken
  /// punctuation; then marks the defaults as applied. A second call changes nothing.
  /// Inputs are injectable so tests never touch real defaults or the real Offline Mode switch.
  /// `notifySelectionsChanged` runs once after a pass that wrote, so listeners follow Parakeet
  /// rather than whatever model the Offline Mode reconciler picked on the way.
  @MainActor
  static func apply(
    defaults: UserDefaults = .standard,
    preferredLanguages: [String] = Locale.preferredLanguages,
    isAppleSilicon: Bool = LiveDictation.isAppleSilicon,
    isAppStore: Bool = DictationOnlyDefaults.isAppStoreBuild,
    switchOfflineOn: @MainActor () -> Void = { OfflineMode.switchTo(true, reason: "dictation-only defaults") },
    notifySelectionsChanged: @MainActor () -> Void = { ModelSelectionReconciler.postSelectionsChanged() }
  ) -> Result {
    if defaults.bool(forKey: UserDefaultsKeys.dictationOnlyDefaultsApplied) {
      return Result(alreadyApplied: true, language: nil, dictateMode: nil)
    }

    saveSnapshot(defaults: defaults)
    switchOfflineOn()

    let model = TranscriptionModel.parakeetUltra
    defaults.set(model.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModel)

    let language = applyLanguage(
      defaults: defaults, preferredLanguages: preferredLanguages,
      model: model.offlineModelType ?? .parakeetUltra)

    // Live needs Parakeet on Apple Silicon and pastes at the cursor (Accessibility), so it is
    // offered in the direct build only; everywhere else the plain mode.
    let mode: DictateMode = (!isAppStore && isAppleSilicon) ? .live : .dictate
    defaults.set(mode.rawValue, forKey: UserDefaultsKeys.dictateMode)

    // Spoken marks ("Komma", "Punkt") are recognised in German only. Anywhere else "Only when
    // spoken" would leave the text without any punctuation, so the model's own stays on. With no
    // language yet (`.needsExplicitPick`) nothing is written; the onboarding language step sets
    // it once the user picked (`punctuation(for:)`).
    if let picked = language.language {
      defaults.set(punctuation(for: picked).rawValue, forKey: UserDefaultsKeys.punctuationMode)
    }

    // After the writes, so `applied` is what this pass left, not what was there before.
    recordAppliedValues(defaults: defaults)
    defaults.set(true, forKey: UserDefaultsKeys.dictationOnlyDefaultsApplied)
    DebugLogger.log("DICTATION-ONLY: defaults applied (mode=\(mode.rawValue), language=\(language))")
    notifySelectionsChanged()
    return Result(alreadyApplied: false, language: language, dictateMode: mode)
  }

  /// Remembers a value written after `apply` (the 🌐 step turns Fn dictation on). No snapshot, or
  /// one from before `applied` existed, is left alone: inventing `applied` there would make
  /// `restore` treat keys the old snapshot never captured.
  static func recordApplied(key: String, value: Any, defaults: UserDefaults = .standard) {
    guard var snapshot = defaults.dictionary(forKey: UserDefaultsKeys.dictationOnlyDefaultsSnapshot),
      var applied = snapshot[snapshotApplied] as? [String: Any]
    else { return }
    applied[key] = value
    snapshot[snapshotApplied] = applied
    defaults.set(snapshot, forKey: UserDefaultsKeys.dictationOnlyDefaultsSnapshot)
  }

  private static func recordAppliedValues(defaults: UserDefaults) {
    guard var snapshot = defaults.dictionary(forKey: UserDefaultsKeys.dictationOnlyDefaultsSnapshot) else { return }
    var applied: [String: Any] = [:]
    for key in snapshotKeys {
      applied[key] = defaults.object(forKey: key) ?? snapshotAbsent
    }
    snapshot[snapshotApplied] = applied
    defaults.set(snapshot, forKey: UserDefaultsKeys.dictationOnlyDefaultsSnapshot)
  }

  /// Saves the current value of every key `apply` changes, "absent" kept apart from a value so
  /// `restore` can remove keys that did not exist. An existing snapshot is never overwritten.
  private static func saveSnapshot(defaults: UserDefaults) {
    guard defaults.dictionary(forKey: UserDefaultsKeys.dictationOnlyDefaultsSnapshot) == nil else { return }
    var present: [String: Any] = [:]
    var absent: [String] = []
    for key in snapshotKeys {
      if let value = defaults.object(forKey: key) { present[key] = value } else { absent.append(key) }
    }
    defaults.set(
      [snapshotPresent: present, snapshotAbsent: absent],
      forKey: UserDefaultsKeys.dictationOnlyDefaultsSnapshot)
  }

  /// Puts back what `apply` saved. A snapshot that records `applied` restores a key only while it
  /// still holds that value (both unset counts as equal); a key the user changed since stays, and
  /// is logged. Offline Mode is last and only switches when it is still the applied value and the
  /// before-value differs, so the model reconciler it runs sees the restored selections. An older
  /// snapshot without `applied` restores every key it captured, which is what it did before.
  /// Then clears the snapshot and the applied flag, so a later opt-in applies again. Without a
  /// snapshot (the Settings switch never applies) nothing changes. Returns whether a snapshot
  /// was restored.
  @MainActor
  @discardableResult
  static func restore(
    defaults: UserDefaults = .standard,
    switchOffline: @MainActor (Bool) -> Void = { OfflineMode.switchTo($0, reason: "dictation-only restore") }
  ) -> Bool {
    guard let snapshot = defaults.dictionary(forKey: UserDefaultsKeys.dictationOnlyDefaultsSnapshot) else {
      return false
    }
    let present = snapshot[snapshotPresent] as? [String: Any] ?? [:]
    let absent = snapshot[snapshotAbsent] as? [String] ?? []
    let offlineKey = UserDefaultsKeys.offlineModeEnabled
    var kept: [String] = []
    if let applied = snapshot[snapshotApplied] as? [String: Any] {
      for key in snapshotKeys where key != offlineKey {
        if let recorded = applied[key] {
          if matchesApplied(current: defaults.object(forKey: key), recorded: recorded) {
            writeBack(key, present: present, defaults: defaults)
          } else {
            kept.append(key)
          }
        } else if present[key] != nil || absent.contains(key) {
          writeBack(key, present: present, defaults: defaults)
        }
      }
      if let recorded = applied[offlineKey] {
        if matchesApplied(current: defaults.object(forKey: offlineKey), recorded: recorded) {
          switchOfflineBack(present: present, defaults: defaults, switchOffline: switchOffline)
        } else {
          kept.append(offlineKey)
        }
      } else {
        switchOfflineBack(present: present, defaults: defaults, switchOffline: switchOffline)
      }
    } else {
      // Keys added later (Fn) are not in this snapshot. Removing them would undo a choice the
      // tour never saved.
      for key in snapshotKeys where key != offlineKey {
        if present[key] != nil || absent.contains(key) { writeBack(key, present: present, defaults: defaults) }
      }
      switchOfflineBack(present: present, defaults: defaults, switchOffline: switchOffline)
    }
    defaults.removeObject(forKey: UserDefaultsKeys.dictationOnlyDefaultsSnapshot)
    defaults.removeObject(forKey: UserDefaultsKeys.dictationOnlyDefaultsApplied)
    if !kept.isEmpty {
      DebugLogger.log("DICTATION-ONLY: kept user changes (\(kept.joined(separator: ", ")))")
    }
    DebugLogger.log("DICTATION-ONLY: restored previous settings (\(present.count + absent.count) keys)")
    return true
  }

  /// The before-value, or removal when the key did not exist.
  private static func writeBack(_ key: String, present: [String: Any], defaults: UserDefaults) {
    if let value = present[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
  }

  @MainActor
  private static func switchOfflineBack(
    present: [String: Any], defaults: UserDefaults, switchOffline: @MainActor (Bool) -> Void
  ) {
    let offlineKey = UserDefaultsKeys.offlineModeEnabled
    let offlineBefore = (present[offlineKey] as? Bool) ?? false
    if defaults.bool(forKey: offlineKey) != offlineBefore { switchOffline(offlineBefore) }
  }

  /// `recorded` is either a property-list value or the "absent" marker. Unset on both sides matches.
  private static func matchesApplied(current: Any?, recorded: Any) -> Bool {
    if let marker = recorded as? String, marker == snapshotAbsent { return current == nil }
    guard let current else { return false }
    guard let left = current as? NSObject, let right = recorded as? NSObject else { return false }
    return left.isEqual(right)
  }

  private static func applyLanguage(
    defaults: UserDefaults, preferredLanguages: [String], model: OfflineModelType
  ) -> LanguageOutcome {
    let current = defaults.string(forKey: UserDefaultsKeys.whisperLanguage)
      .flatMap(WhisperLanguage.init(rawValue:)) ?? SettingsDefaults.whisperLanguage
    if current != .auto { return .kept(current) }
    guard
      let language = DictationLanguagePreselect.language(
        forPreferredIdentifier: preferredLanguages.first),
      model.supports(language)
    else { return .needsExplicitPick }
    defaults.set(language.rawValue, forKey: UserDefaultsKeys.whisperLanguage)
    return .set(language)
  }

  /// The punctuation this mode starts with for a dictation language: spoken marks where the app
  /// understands them (German), the model's own punctuation everywhere else.
  static func punctuation(for language: WhisperLanguage) -> PunctuationMode {
    language == .de ? .spokenOnly : .automatic
  }

  static var isAppStoreBuild: Bool {
    #if APP_STORE
    return true
    #else
    return false
    #endif
  }
}

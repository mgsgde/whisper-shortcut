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
  private static let visibleTabSet: Set<SettingsTab> = [.general, .speechToText, .permissions, .about]

  static func visibleTabs(_ all: [SettingsTab], enabled: Bool) -> [SettingsTab] {
    enabled ? all.filter { visibleTabSet.contains($0) } : all
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
}

// MARK: - First-run defaults

/// The defaults the "Dictation only" onboarding card applies, once. Nothing calls this at launch
/// and the Settings switch never does: the switch only hides and shows.
enum DictationOnlyDefaults {

  enum LanguageOutcome: Equatable {
    /// Was Auto-detect; now the Mac's language.
    case set(WhisperLanguage)
    /// An explicit language was already chosen; left alone.
    case kept(WhisperLanguage)
    /// The Mac's language is not one the model transcribes. Language is still Auto-detect and
    /// the caller has to ask for an explicit pick.
    case needsExplicitPick
  }

  struct Result: Equatable {
    var alreadyApplied: Bool
    var language: LanguageOutcome?
    var dictateMode: DictateMode?
  }

  /// Applies, in order: Offline Mode on, Parakeet selected, language, Dictate mode, spoken
  /// punctuation; then marks the defaults as applied. A second call changes nothing.
  /// Inputs are injectable so tests never touch real defaults or the real Offline Mode switch.
  @MainActor
  static func apply(
    defaults: UserDefaults = .standard,
    preferredLanguages: [String] = Locale.preferredLanguages,
    isAppleSilicon: Bool = LiveDictation.isAppleSilicon,
    isAppStore: Bool = DictationOnlyDefaults.isAppStoreBuild,
    switchOfflineOn: @MainActor () -> Void = { OfflineMode.switchTo(true, reason: "dictation-only defaults") }
  ) -> Result {
    if defaults.bool(forKey: UserDefaultsKeys.dictationOnlyDefaultsApplied) {
      return Result(alreadyApplied: true, language: nil, dictateMode: nil)
    }

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

    defaults.set(PunctuationMode.spokenOnly.rawValue, forKey: UserDefaultsKeys.punctuationMode)

    defaults.set(true, forKey: UserDefaultsKeys.dictationOnlyDefaultsApplied)
    DebugLogger.log("DICTATION-ONLY: defaults applied (mode=\(mode.rawValue), language=\(language))")
    return Result(alreadyApplied: false, language: language, dictateMode: mode)
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

  static var isAppStoreBuild: Bool {
    #if APP_STORE
    return true
    #else
    return false
    #endif
  }
}

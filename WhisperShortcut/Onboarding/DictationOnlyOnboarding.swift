//
//  DictationOnlyOnboarding.swift
//  WhisperShortcut
//
//  The decisions behind the "Dictation only" path of the Welcome Tour, kept free of views so they
//  can be tested: which card the first screen pre-selects, what Continue on it does, which steps
//  follow, where a restarted tour resumes, and what the last screen promises. The screens are in
//  DictationOnlySteps.swift. Spec: plans/active/dictation-only-mode.md.
//

import Foundation

// MARK: - First screen

/// The answer to "How do you want to use WhisperShortcut?".
enum OnboardingModeChoice: Equatable {
  case dictationOnly
  case allFeatures

  /// What the first screen shows as already chosen. A fresh install starts on "Dictation only"
  /// (visual only: nothing is written until Continue). A tour opened again shows what is in use.
  static func prefilled(modeOn: Bool, completedBefore: Bool) -> OnboardingModeChoice? {
    if modeOn { return .dictationOnly }
    return completedBefore ? .allFeatures : .dictationOnly
  }
}

/// What Continue on the first screen does with the choice.
enum OnboardingModeCommit {
  enum Outcome: Equatable {
    /// Mode on; `defaults` is what `DictationOnlyDefaults.apply` did (or that it ran before).
    case dictationOnly(defaults: DictationOnlyDefaults.Result)
    /// The existing tour continues. The flag is off and no default was touched.
    case allFeatures
    /// A recording or meeting is running, so the flag could not change. Nothing was written.
    case refusedWhileBusy
  }

  /// "Dictation only" turns the mode on and applies the first-run defaults once
  /// (`apply` is itself idempotent). "All features" never applies anything; it only turns the
  /// mode off again when a revisited tour finds it on, since that is what the card says.
  /// `setMode` is `DictationOnlyMode.setEnabled` with the current activity; it returns whether
  /// the flag was written.
  @MainActor
  static func commit(
    _ choice: OnboardingModeChoice,
    modeIsOn: Bool,
    setMode: (Bool) -> Bool,
    applyDefaults: () -> DictationOnlyDefaults.Result
  ) -> Outcome {
    switch choice {
    case .dictationOnly:
      if !modeIsOn, !setMode(true) { return .refusedWhileBusy }
      return .dictationOnly(defaults: applyDefaults())
    case .allFeatures:
      if modeIsOn, !setMode(false) { return .refusedWhileBusy }
      return .allFeatures
    }
  }
}

// MARK: - Steps

/// The steps after "Dictation only". Raw values start at 101 so they never collide with
/// `WelcomeStep` (0…7) in the one stored key `onboardingCurrentStep`; the old steps keep theirs.
enum DictationOnlyStep: Int, CaseIterable {
  /// Direct build only, and only while macOS still uses the 🌐 key for something else.
  case globeKey = 101
  case language = 102
  case permissions = 103
  /// Skipped when the model is already on this Mac.
  case download = 104
  case test = 105
  case glossary = 106
  case done = 107

  static func isDictationOnly(rawValue: Int) -> Bool {
    rawValue >= DictationOnlyStep.globeKey.rawValue
  }

  /// The steps in order. Decided once, when the path starts or a tour resumes; a step that stops
  /// applying while it is on screen (the key was freed, the download finished) stays put.
  static func steps(isAppStore: Bool, globeConflict: Bool, modelReady: Bool) -> [DictationOnlyStep] {
    allCases.filter { step in
      switch step {
      case .globeKey: return !isAppStore && globeConflict
      case .download: return !modelReady
      case .language, .permissions, .test, .glossary, .done: return true
      }
    }
  }
}

/// Where the tour stands: on a step of the existing flow, or on one of the dictation-only path.
enum OnboardingPosition: Equatable {
  case welcome(WelcomeStep)
  case dictationOnly(DictationOnlyStep)

  /// Resumes from the stored raw value. `WelcomeStep.resume` alone would read 101+ as `.done`.
  /// - Dictation-only value, mode on: that step, or the next one still in `steps`.
  /// - Dictation-only value, mode off (switched off in Settings meanwhile): the first screen.
  /// - Old value, mode on: 0 is the first screen; anything else is the start of the path.
  /// - Old value, mode off: unchanged behaviour.
  static func resume(stored: Int, modeOn: Bool, steps: [DictationOnlyStep]) -> OnboardingPosition {
    if DictationOnlyStep.isDictationOnly(rawValue: stored) {
      guard modeOn, let last = steps.last else { return .welcome(.intro) }
      return .dictationOnly(steps.first(where: { $0.rawValue >= stored }) ?? last)
    }
    if modeOn, stored != WelcomeStep.intro.rawValue, let first = steps.first {
      return .dictationOnly(first)
    }
    return .welcome(WelcomeStep.resume(from: stored))
  }
}

// MARK: - Last screen

/// Which key starts dictation, as the last screen names it.
enum DictationOnlyStartKey: Equatable {
  case fn
  case shortcut(String)
  /// Neither Fn nor an enabled Dictate shortcut.
  case none

  /// Fn counts only in the direct build, switched on, with the 🌐 key free and Accessibility
  /// granted (Fn is read through it). Otherwise the Dictate shortcut, when it is enabled.
  static func resolve(
    isAppStore: Bool, fnEnabled: Bool, globeConflict: Bool, accessibilityGranted: Bool,
    dictateShortcut: String?
  ) -> DictationOnlyStartKey {
    if !isAppStore, fnEnabled, !globeConflict, accessibilityGranted { return .fn }
    if let dictateShortcut { return .shortcut(dictateShortcut) }
    return .none
  }
}

/// A shortcut in the words printed on the keys, for the last screen: "⌥⌃1" becomes
/// "control + option + 1". Apple's keyboards print these names in English in every layout, so
/// they are not translated. Modifiers come in the order they sit on the keyboard.
enum DictationOnlyKeyNames {
  private static let modifiers: [(glyph: Character, name: String)] = [
    ("⌃", "control"), ("⌥", "option"), ("⇧", "shift"), ("⌘", "command"),
  ]

  static func spell(_ glyphs: String) -> String {
    let present = modifiers.filter { glyphs.contains($0.glyph) }.map(\.name)
    let key = String(glyphs.filter { char in !modifiers.contains { $0.glyph == char } })
      .trimmingCharacters(in: .whitespaces)
    return (present + (key.isEmpty ? [] : [key])).joined(separator: " + ")
  }
}

/// Where the text goes, as the last screen promises it. Live text only where Live really runs.
enum DictationOnlyDelivery: Equatable {
  /// Text appears at the cursor while speaking.
  case live
  /// Text appears at the cursor after the second key press.
  case atCursor
  /// Text is copied; the person pastes it with ⌘V.
  case copied

  static func resolve(
    isAppStore: Bool, dictateMode: DictateMode, appleSilicon: Bool,
    accessibilityGranted: Bool, autoPaste: Bool
  ) -> DictationOnlyDelivery {
    // Pasting at the cursor needs Accessibility, which the App Store build never asks for.
    if isAppStore || !accessibilityGranted { return .copied }
    if dictateMode == .live && appleSilicon { return .live }
    return autoPaste ? .atCursor : .copied
  }
}

// MARK: - Test sentence

/// A sentence to read aloud on the test step, in the dictation language (not the app's). Spoken
/// punctuation is understood in German only, so only the German one says "Komma" and "Punkt".
enum DictationOnlyTestSentence {
  static func sentence(for language: WhisperLanguage) -> String {
    switch language {
    case .de: return "Heute ist ein schöner Tag Komma und ich probiere das Diktieren aus Punkt"
    case .fr: return "Aujourd’hui, j’essaie la dictée pour la première fois."
    case .es: return "Hoy pruebo el dictado por primera vez."
    case .it: return "Oggi provo la dettatura per la prima volta."
    case .nl: return "Vandaag probeer ik voor het eerst te dicteren."
    default: return "Today is a good day to try dictation."
    }
  }

  /// Whether the sentence contains spoken punctuation, so the screen can say what it does.
  static func usesSpokenPunctuation(_ language: WhisperLanguage) -> Bool { language == .de }
}

import Foundation

extension OfflineModelType {
  /// Whether this model can transcribe `language`. Auto-detect is always allowed. Every Whisper
  /// model here is multilingual and covers the whole `WhisperLanguage` list; Parakeet covers its 25.
  func supports(_ language: WhisperLanguage) -> Bool {
    guard let code = language.languageCode else { return true }
    switch engine {
    case .whisperKit: return true
    case .parakeet: return Self.parakeetLanguageCodes.contains(code)
    }
  }
}

/// Sets the dictation language from the Mac's language when the user picks Offline in onboarding.
///
/// Auto-detect on a short offline dictation guesses wrong often enough to matter, and nobody
/// changes a setting they do not know exists: a pilot user on a German Mac (2026-11-02) finished
/// setup with the language still on Auto. The language is set only while it is still Auto, and
/// only to one the offline model can transcribe — a choice the user already made is never touched.
enum DictationLanguagePreselect {
  /// The `WhisperLanguage` for a macOS language identifier such as "de-DE", "pt-BR", "zh-Hans-CN"
  /// or "nb-NO". Nil when the app has no entry for that language.
  static func language(forPreferredIdentifier identifier: String?) -> WhisperLanguage? {
    guard let identifier, !identifier.isEmpty,
      var code = Locale.Language(identifier: identifier).languageCode?.identifier.lowercased()
    else { return nil }
    // macOS reports Norwegian as Bokmål or Nynorsk; Whisper has the one "no".
    if code == "nb" || code == "nn" { code = "no" }
    guard let language = WhisperLanguage(rawValue: code), language != .auto else { return nil }
    return language
  }

  /// What to set, or nil to leave the setting alone: the stored language is not Auto, the Mac's
  /// language is not in the list, or `model` cannot transcribe it.
  static func preselection(
    current: WhisperLanguage, preferredLanguages: [String], model: OfflineModelType
  ) -> WhisperLanguage? {
    guard current == .auto,
      let language = language(forPreferredIdentifier: preferredLanguages.first),
      model.supports(language)
    else { return nil }
    return language
  }

  /// The offline model onboarding's Offline answer ends up on: the one already selected, or the
  /// one the download card fetches (`OnboardingOfflineRow` uses `mostAccurate`).
  static var onboardingOfflineModel: OfflineModelType {
    TranscriptionModel.loadSelected().offlineModelType ?? OfflineModelType.mostAccurate
  }

  /// Applies `preselection` to the stored setting. Returns the language it set, nil if it left the
  /// setting alone.
  @discardableResult
  static func applyForOfflineOnboarding(defaults: UserDefaults = .standard) -> WhisperLanguage? {
    let current = defaults.string(forKey: UserDefaultsKeys.whisperLanguage)
      .flatMap(WhisperLanguage.init(rawValue:)) ?? SettingsDefaults.whisperLanguage
    let model = onboardingOfflineModel
    guard let language = preselection(
      current: current, preferredLanguages: Locale.preferredLanguages, model: model)
    else { return nil }
    defaults.set(language.rawValue, forKey: UserDefaultsKeys.whisperLanguage)
    DebugLogger.log(
      "ONBOARDING: chose Offline; dictation language Auto → \(language.rawValue) (Mac language, \(model.displayName))")
    return language
  }
}

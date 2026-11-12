import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The "Dictation only" path of the Welcome Tour and its Settings switch. Pure decisions only;
/// the screens themselves are not covered here.
@Suite("Dictation only onboarding")
@MainActor
struct DictationOnlyOnboardingTests {

  private func makeDefaults() -> UserDefaults {
    let name = "DictationOnlyOnboardingTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  // MARK: - Step list

  @Test("Direct build with a 🌐 conflict: globe key first, then the fixed order")
  func stepsDirectWithConflict() {
    let steps = DictationOnlyStep.steps(isAppStore: false, globeConflict: true, modelReady: false)
    #expect(steps == [.globeKey, .language, .permissions, .download, .test, .glossary, .done])
  }

  @Test("The globe step appears only on a conflict, and never in the App Store build")
  func globeOnlyOnConflict() {
    #expect(!DictationOnlyStep.steps(isAppStore: false, globeConflict: false, modelReady: false).contains(.globeKey))
    #expect(!DictationOnlyStep.steps(isAppStore: true, globeConflict: true, modelReady: false).contains(.globeKey))
    #expect(DictationOnlyStep.steps(isAppStore: false, globeConflict: true, modelReady: false).first == .globeKey)
  }

  @Test("App Store build: language, permissions, download, test, glossary, done")
  func stepsAppStore() {
    let steps = DictationOnlyStep.steps(isAppStore: true, globeConflict: false, modelReady: false)
    #expect(steps == [.language, .permissions, .download, .test, .glossary, .done])
  }

  @Test("The download step is left out when the model is already on this Mac")
  func downloadSkippedWhenReady() {
    let steps = DictationOnlyStep.steps(isAppStore: false, globeConflict: false, modelReady: true)
    #expect(steps == [.language, .permissions, .test, .glossary, .done])
  }

  @Test("New raw values never collide with the existing tour's")
  func rawValuesSeparate() {
    let old = Set(WelcomeStep.allCases.map(\.rawValue))
    for step in DictationOnlyStep.allCases {
      #expect(!old.contains(step.rawValue))
      #expect(DictationOnlyStep.isDictationOnly(rawValue: step.rawValue))
    }
    for step in WelcomeStep.allCases {
      #expect(!DictationOnlyStep.isDictationOnly(rawValue: step.rawValue))
    }
  }

  // MARK: - Resume

  private let allSteps = DictationOnlyStep.steps(isAppStore: false, globeConflict: true, modelReady: false)

  @Test("Old stored values with the mode off resume exactly as before")
  func resumeOldValuesModeOff() {
    for raw in [0, 1, 2, 3, 4, 5, 6, 7] {
      #expect(
        OnboardingPosition.resume(stored: raw, modeOn: false, steps: allSteps)
          == .welcome(WelcomeStep.resume(from: raw)))
    }
    #expect(OnboardingPosition.resume(stored: 3, modeOn: false, steps: allSteps) == .welcome(.permissions))
  }

  @Test("A stored dictation-only step resumes on that step")
  func resumeNewValue() {
    #expect(OnboardingPosition.resume(stored: 103, modeOn: true, steps: allSteps) == .dictationOnly(.permissions))
    #expect(OnboardingPosition.resume(stored: 107, modeOn: true, steps: allSteps) == .dictationOnly(.done))
  }

  @Test("A stored step no longer in the list resumes on the next one")
  func resumeSkippedStep() {
    let noDownload = DictationOnlyStep.steps(isAppStore: false, globeConflict: false, modelReady: true)
    #expect(OnboardingPosition.resume(stored: 104, modeOn: true, steps: noDownload) == .dictationOnly(.test))
    #expect(OnboardingPosition.resume(stored: 101, modeOn: true, steps: noDownload) == .dictationOnly(.language))
  }

  @Test("A dictation-only value is never read as the old Done step")
  func resumeNewValueModeOff() {
    #expect(OnboardingPosition.resume(stored: 105, modeOn: false, steps: allSteps) == .welcome(.intro))
  }

  @Test("Mode on with an old value: 0 is the first screen, anything else the start of the path")
  func resumeOldValueModeOn() {
    #expect(OnboardingPosition.resume(stored: 0, modeOn: true, steps: allSteps) == .welcome(.intro))
    #expect(OnboardingPosition.resume(stored: 3, modeOn: true, steps: allSteps) == .dictationOnly(.globeKey))
    #expect(OnboardingPosition.resume(stored: 7, modeOn: true, steps: allSteps) == .dictationOnly(.globeKey))
  }

  // MARK: - First screen

  final class Calls {
    var setMode: [Bool] = []
    var applied = 0
  }

  private func commit(
    _ choice: OnboardingModeChoice, modeIsOn: Bool, setModeSucceeds: Bool = true, calls: Calls
  ) -> OnboardingModeCommit.Outcome {
    OnboardingModeCommit.commit(
      choice, modeIsOn: modeIsOn,
      setMode: { enabled in
        calls.setMode.append(enabled)
        return setModeSucceeds
      },
      applyDefaults: {
        calls.applied += 1
        return DictationOnlyDefaults.Result(alreadyApplied: false, language: .set(.de), dictateMode: .live)
      })
  }

  @Test("All features leaves the flag off and applies no defaults")
  func allFeaturesTouchesNothing() {
    let calls = Calls()
    #expect(commit(.allFeatures, modeIsOn: false, calls: calls) == .allFeatures)
    #expect(calls.setMode.isEmpty)
    #expect(calls.applied == 0)
  }

  @Test("All features on a revisited tour turns the mode off, still without defaults")
  func allFeaturesTurnsModeOff() {
    let calls = Calls()
    #expect(commit(.allFeatures, modeIsOn: true, calls: calls) == .allFeatures)
    #expect(calls.setMode == [false])
    #expect(calls.applied == 0)
  }

  @Test("Dictation only turns the mode on and applies the defaults once")
  func dictationOnlyAppliesOnce() {
    let calls = Calls()
    let outcome = commit(.dictationOnly, modeIsOn: false, calls: calls)
    #expect(calls.setMode == [true])
    #expect(calls.applied == 1)
    if case .dictationOnly = outcome {} else { Issue.record("expected .dictationOnly, got \(outcome)") }
  }

  @Test("Refused while busy: nothing applied")
  func dictationOnlyRefused() {
    let calls = Calls()
    #expect(commit(.dictationOnly, modeIsOn: false, setModeSucceeds: false, calls: calls) == .refusedWhileBusy)
    #expect(calls.applied == 0)
  }

  @Test("First screen pre-selects nothing on a fresh install")
  func prefill() {
    #expect(OnboardingModeChoice.prefilled(modeOn: false, completedBefore: false) == .dictationOnly)
    #expect(OnboardingModeChoice.prefilled(modeOn: false, completedBefore: true) == .allFeatures)
    #expect(OnboardingModeChoice.prefilled(modeOn: true, completedBefore: true) == .dictationOnly)
  }

  // MARK: - Settings switch

  @Test("The Settings switch never applies defaults")
  func settingsSwitchNeverApplies() {
    let defaults = makeDefaults()
    let center = NotificationCenter()
    #expect(
      DictationOnlySettingsSwitch.change(to: true, activity: .idle, defaults: defaults, notificationCenter: center)
        == .changed)
    #expect(defaults.bool(forKey: UserDefaultsKeys.dictationOnlyMode))
    #expect(defaults.object(forKey: UserDefaultsKeys.dictationOnlyDefaultsApplied) == nil)
    #expect(defaults.object(forKey: UserDefaultsKeys.selectedTranscriptionModel) == nil)
    #expect(defaults.object(forKey: UserDefaultsKeys.whisperLanguage) == nil)
    #expect(defaults.object(forKey: UserDefaultsKeys.dictateMode) == nil)
    #expect(defaults.object(forKey: UserDefaultsKeys.punctuationMode) == nil)
    #expect(
      DictationOnlySettingsSwitch.change(to: false, activity: .idle, defaults: defaults, notificationCenter: center)
        == .changed)
    #expect(defaults.dictionaryRepresentation().keys.contains(UserDefaultsKeys.dictationOnlyDefaultsApplied) == false)
  }

  @Test("The Settings switch stays put while a recording or meeting runs")
  func settingsSwitchRefused() {
    let defaults = makeDefaults()
    let busy = DictationOnlyMode.Activity(meetingActive: false, recording: true)
    #expect(
      DictationOnlySettingsSwitch.change(to: true, activity: busy, defaults: defaults, notificationCenter: NotificationCenter())
        == .refusedWhileBusy)
    #expect(defaults.object(forKey: UserDefaultsKeys.dictationOnlyMode) == nil)
  }

  @Test("Links to hidden tabs land on Dictate or General")
  func reachableTabs() {
    #expect(DictationOnlyMode.reachableTab(.accounts, enabled: true) == .speechToText)
    #expect(DictationOnlyMode.reachableTab(.chat, enabled: true) == .general)
    #expect(DictationOnlyMode.reachableTab(.permissions, enabled: true) == .permissions)
    #expect(DictationOnlyMode.reachableTab(.accounts, enabled: false) == .accounts)
  }

  // MARK: - Defaults: punctuation per language

  @Test("English gets the model's own punctuation; no language yet writes none")
  func punctuationPerLanguage() {
    let english = makeDefaults()
    _ = DictationOnlyDefaults.apply(
      defaults: english, preferredLanguages: ["en-US"], isAppleSilicon: true, isAppStore: false,
      switchOfflineOn: {})
    #expect(english.string(forKey: UserDefaultsKeys.punctuationMode) == PunctuationMode.automatic.rawValue)

    let unknown = makeDefaults()
    _ = DictationOnlyDefaults.apply(
      defaults: unknown, preferredLanguages: ["uk-UA"], isAppleSilicon: true, isAppStore: false,
      switchOfflineOn: {})
    #expect(unknown.object(forKey: UserDefaultsKeys.punctuationMode) == nil)
    #expect(DictationOnlyDefaults.punctuation(for: .de) == .spokenOnly)
  }

  // MARK: - Try-it recording length

  @Test("Try-it records 3 seconds by default and what it is told otherwise")
  func tryItRecordLength() {
    #expect(OnboardingTryItController.defaultRecordSeconds == 3)
    #expect(OnboardingTryItController().recordSeconds == 3)
    #expect(OnboardingTryItController(recordSeconds: 8).recordSeconds == 8)
    #expect(DictationOnlyTestStep.recordSeconds == 8)
    #expect(OnboardingTryItController(recordSeconds: 0).recordSeconds == 1)
  }

  // MARK: - Last screen

  @Test("Live text is promised only where Live really runs")
  func deliveryPromise() {
    func resolve(appStore: Bool = false, mode: DictateMode = .live, silicon: Bool = true, ax: Bool = true, paste: Bool = true)
      -> DictationOnlyDelivery
    {
      DictationOnlyDelivery.resolve(
        isAppStore: appStore, dictateMode: mode, appleSilicon: silicon, accessibilityGranted: ax, autoPaste: paste)
    }
    #expect(resolve() == .live)
    #expect(resolve(silicon: false) == .atCursor)
    #expect(resolve(mode: .dictate) == .atCursor)
    #expect(resolve(appStore: true) == .copied)
    #expect(resolve(ax: false) == .copied)
    #expect(resolve(mode: .dictate, paste: false) == .copied)
  }

  @Test("The start key is Fn only when it can work, else the Dictate shortcut")
  func startKey() {
    #expect(
      DictationOnlyStartKey.resolve(
        isAppStore: false, fnEnabled: true, globeConflict: false, accessibilityGranted: true, dictateShortcut: "⌥⌘D")
        == .fn)
    #expect(
      DictationOnlyStartKey.resolve(
        isAppStore: false, fnEnabled: true, globeConflict: true, accessibilityGranted: true, dictateShortcut: "⌥⌘D")
        == .shortcut("⌥⌘D"))
    #expect(
      DictationOnlyStartKey.resolve(
        isAppStore: true, fnEnabled: true, globeConflict: false, accessibilityGranted: true, dictateShortcut: nil)
        == DictationOnlyStartKey.none)
  }

  @Test("Only the German test sentence uses spoken punctuation")
  func testSentence() {
    #expect(DictationOnlyTestSentence.sentence(for: .de).contains("Komma"))
    #expect(!DictationOnlyTestSentence.sentence(for: .en).contains("Komma"))
    #expect(DictationOnlyTestSentence.usesSpokenPunctuation(.de))
    #expect(!DictationOnlyTestSentence.usesSpokenPunctuation(.fr))
  }

  // MARK: - Model still downloading after the tour

  @Test("A Parakeet selection whose files are not on disk yet is kept by the reconciler, with or without a key")
  func pendingDownloadKeepsSelection() {
    let defaults = makeDefaults()
    let key = UserDefaultsKeys.selectedTranscriptionModel
    defaults.set(TranscriptionModel.parakeetUltra.rawValue, forKey: key)
    ModelSelectionReconciler.reconcileTranscription(
      key: key, fallback: SettingsDefaults.selectedTranscriptionModel, defaults: defaults)
    #expect(defaults.string(forKey: key) == TranscriptionModel.parakeetUltra.rawValue)
    // The meetings slot follows dictation while unset and is never written by the reconciler.
    ModelSelectionReconciler.reconcileTranscription(
      key: UserDefaultsKeys.selectedTranscriptionModelForMeetings,
      fallback: SettingsDefaults.selectedTranscriptionModel, skipWhenUnset: true, defaults: defaults)
    #expect(defaults.string(forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings) == nil)
  }

  @Test("Dictate Live with the model not downloaded is refused with a notice, never started as cloud Dictate")
  func liveRefusedWhileDownloading() {
    let reason = LiveDictation.unavailableReason(
      model: .parakeetUltra, downloaded: false, appleSilicon: true, duringMeeting: false)
    #expect(reason == .notDownloaded)
    #expect(
      LiveDictation.startDecision(mode: .live, unavailable: reason) == .refuse(.notDownloaded))
    #expect(
      LiveDictation.unavailableReason(
        model: .parakeetUltra, downloaded: true, appleSilicon: true, duringMeeting: false) == nil)
  }
}

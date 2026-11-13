import AppKit
import SwiftUI

/// Five steps, one decision. Raw values are the ones these steps had in the older eight-step tour
/// (`onboardingCurrentStep` persists them), so a tour started before an update resumes on the step
/// that matches; the gaps are the retired privacy, auto-paste and Smart Improvement steps.
enum WelcomeStep: Int, CaseIterable {
  case intro = 0
  /// "How should dictation run?" — offline model or one cloud account. Privacy lives here too.
  case dictationSetup = 2
  /// Microphone, Screen Recording, and (direct build) the auto-paste opt-in that needs Accessibility.
  case permissions = 3
  /// The first successful dictation, right after the microphone is granted.
  case tryIt = 4
  case done = 7

  /// Both builds show the same five steps; the App Store build only drops the auto-paste card
  /// from the permissions step (Guideline 2.4.5).
  static var activeSteps: [WelcomeStep] { allCases }

  /// Nearest active step for a persisted raw value — tolerates a stored step that no longer
  /// exists (e.g. a retired step from an older build).
  static func resume(from rawValue: Int) -> WelcomeStep {
    activeSteps.last(where: { $0.rawValue <= rawValue }) ?? .intro
  }

  var indexLabel: String {
    let steps = WelcomeStep.activeSteps
    let position = (steps.firstIndex(of: self) ?? 0) + 1
    return String(localized: "\(position) of \(steps.count)")
  }

  /// Continue is enabled. Dictation setup used to OR five Keychain flags, plus any downloaded
  /// offline model. That counted an Anthropic key and a ChatGPT-plan sign-in, missed a Gemini
  /// credential once the key row had overwritten the flag with a raw Keychain read, and let the
  /// user pass a step the Done page then called "Needs a model". Advance only when the selected
  /// transcription model can run. Offline is already inside that check: `hasRequiredCredential`
  /// for an offline model means its file is on disk.
  ///
  /// `fnSetupResolved` is `GlobeKeyUsage.fnSetupMayContinue`: the permissions step holds the Fn
  /// toggle, and leaving it with Fn on while macOS still owns the 🌐 key ends in a Fn press that
  /// opens the emoji picker and dictates nothing.
  ///
  /// `dictationChoice` is the card the user picked. Under Offline the selected model must itself
  /// be an installed offline model: a saved cloud key must not let Continue through under a card
  /// that promises the audio never leaves this Mac (`OnboardingDictationGate`).
  func canAdvance(
    micStatus: PermissionStatus, fnSetupResolved: Bool = true,
    dictationChoice: DictationChoice? = nil
  ) -> Bool {
    switch self {
    case .dictationSetup:
      let model = TranscriptionModel.loadSelected()
      return OnboardingDictationGate.canAdvance(
        choice: dictationChoice, selectedIsOffline: model.provider == .offline,
        selectedCanRun: model.hasRequiredCredential)
    case .permissions:
      return (micStatus == .granted || micStatus == .denied) && fnSetupResolved
    case .intro, .tryIt, .done:
      return true
    }
  }
}

/// The one rule behind both Continue and the step's status line, kept pure so it can be tested.
enum OnboardingDictationGate {
  static func canAdvance(
    choice: DictationChoice?, selectedIsOffline: Bool, selectedCanRun: Bool
  ) -> Bool {
    if choice == .offline { return selectedIsOffline && selectedCanRun }
    return selectedCanRun
  }
}

/// Published copy of `WelcomeStep.dictationSetup.canAdvance` so Continue and the step's
/// "Ready to continue." line update together. The per-provider `@State` booleans used to be
/// that signal; they were written when a key was saved, OAuth finished, or a download completed.
@MainActor
final class OnboardingSetupState: ObservableObject {
  @Published private(set) var dictationCanAdvance: Bool

  init() {
    dictationCanAdvance = WelcomeStep.dictationSetup.canAdvance(
      micStatus: .notDetermined, dictationChoice: DictationChoice.inferred())
  }

  func refresh(choice: DictationChoice?) {
    dictationCanAdvance = WelcomeStep.dictationSetup.canAdvance(
      micStatus: .notDetermined, dictationChoice: choice)
  }
}

/// Builds the "Dictation only" step list from this Mac's state. Called when the path starts and
/// when a tour resumes, never while a step is on screen (`DictationOnlyStep.steps`).
@MainActor
enum DictationOnlyFlow {
  static func currentSteps() -> [DictationOnlyStep] {
    DictationOnlyStep.steps(
      isAppStore: DictationOnlyDefaults.isAppStoreBuild,
      globeConflict: GlobeKeyUsage.current.conflictsWithFnDictation,
      modelReady: ModelManager.shared.isModelAvailable(DictationOnlyDownloadStep.model))
  }

  /// Compiles the model (Core ML / ANE, ~25 s on the first load) while the person is still in the
  /// tour, so the first "Try dictation" does not wait for it. `warmOfflineModel` never downloads
  /// and joins a load that is already running (`LocalSpeechService.initializeModel`).
  static func warmModel(reason: String) {
    let model = DictationOnlyDownloadStep.model
    DebugLogger.log("ONBOARDING: warming \(model.displayName) (\(reason))")
    ConnectionPrewarmer.warmOfflineModel(model)
  }

  /// Starts the one-time download as soon as the path is chosen, so it runs while the person
  /// picks a language and allows the microphone. The download step shows its progress.
  static func startDownloadEarly() {
    let model = DictationOnlyDownloadStep.model
    let manager = ModelManager.shared
    guard !manager.isModelAvailable(model), !manager.downloadingModels.contains(model) else { return }
    Task {
      do {
        try await manager.downloadModel(model)
        warmModel(reason: "early download finished")
      } catch {
        // The download step checks free space and offers the download again.
        DebugLogger.logWarning("ONBOARDING: dictation-only early download stopped: \(error.logDescription)")
      }
    }
  }
}

struct WelcomeView: View {
  /// Key codes (layout-independent, NSEvent.keyCode).
  private static let keyCodeLeftArrow: UInt16 = 123
  private static let keyCodeRightArrow: UInt16 = 124

  /// Resume on the step the user last reached. Persisted in `onboardingCurrentStep` so a
  /// mid-tour app restart (e.g. macOS "Quit & Reopen" after granting a permission) continues
  /// where they left off. A fresh tour (stored value 0 / unset) starts on the first screen.
  /// While `dictationStep` is set, the "Dictation only" path is on screen and `step` stays
  /// `.intro`, the screen Back returns to.
  @State private var step: WelcomeStep
  @State private var dictationStep: DictationOnlyStep?
  /// Fixed when the path starts or resumes (`DictationOnlyStep.steps`).
  @State private var dictationSteps: [DictationOnlyStep]
  /// The answer on the first screen.
  @State private var modeChoice: OnboardingModeChoice?
  /// The last Continue on the first screen was refused (a recording or meeting is running).
  @State private var modeChoiceRefused = false
  /// The test step's dictation came back with text; until then its Start button is the primary.
  @State private var testSucceeded = false
  @State private var keyDownMonitor: Any?
  /// Re-read of "can the selected transcription model run" after a key, OAuth, or download.
  @StateObject private var setup = OnboardingSetupState()
  /// Gates the permissions step's Continue button. Updated by `PermissionsOverview`'s
  /// `onMicStatusChange` callback and the periodic refresh below.
  @State private var micStatus: PermissionStatus = PermissionStatusChecker.status(for: .microphone)
  @State private var axStatus: PermissionStatus = PermissionStatusChecker.status(for: .accessibility)
  /// The answer to "How should dictation run?". Kept here, not in the step, so Back/Continue
  /// does not forget it. Pre-filled from what is already set up when the tour is revisited.
  @State private var dictationChoice: DictationChoice? = DictationChoice.inferred()
  /// Fn toggle and 🌐 setting, for the permissions step's Continue (see `fnSetupResolved`). In the
  /// App Store build the 🌐 setting always reads `.unknown`, which never blocks.
  @AppStorage(UserDefaultsKeys.fnKeyDictation) private var fnEnabled = SettingsDefaults.fnKeyDictation
  @AppStorage(UserDefaultsKeys.whisperLanguage) private var dictationLanguage: WhisperLanguage =
    SettingsDefaults.whisperLanguage
  @ObservedObject private var globeKey = GlobeKeyStatus.shared
  /// For the download step's footer: Continue steps back while nothing downloads yet.
  @ObservedObject private var modelManager = ModelManager.shared

  init() {
    let defaults = UserDefaults.standard
    let modeOn = DictationOnlyMode.isEnabled
    var steps = DictationOnlyFlow.currentSteps()
    // Test profile only (`--onboarding-step`): the step asked for is on the path even when this
    // Mac's state would skip it (the 🌐 step with the key already free).
    if case .dictationOnly(let forced)? = TestProfileOverrides.current.onboardingStep, !steps.contains(forced) {
      let current = steps
      steps = DictationOnlyStep.allCases.filter { current.contains($0) || $0 == forced }
    }
    switch OnboardingPosition.resume(
      stored: defaults.integer(forKey: UserDefaultsKeys.onboardingCurrentStep), modeOn: modeOn, steps: steps)
    {
    case .welcome(let welcomeStep):
      _step = State(initialValue: welcomeStep)
      _dictationStep = State(initialValue: nil)
    case .dictationOnly(let dictationStep):
      _step = State(initialValue: .intro)
      _dictationStep = State(initialValue: dictationStep)
    }
    _dictationSteps = State(initialValue: steps)
    _modeChoice = State(
      initialValue: OnboardingModeChoice.prefilled(
        modeOn: modeOn, completedBefore: defaults.bool(forKey: UserDefaultsKeys.hasCompletedOnboarding)))
  }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        if let dictationStep {
          dictationOnlyContent(dictationStep)
        } else {
          switch step {
          case .intro:
            WelcomeModeChoiceStep(choice: $modeChoice, refused: modeChoiceRefused)
          case .dictationSetup:
            WelcomeDictationSetupStep(choice: $dictationChoice, setup: setup)
          case .permissions:
            WelcomePermissionsStep(micStatus: $micStatus, fnSetupResolved: fnSetupResolved)
          case .tryIt:
            WelcomeTryItStep()
          case .done:
            WelcomeDoneStep()
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 40)
      .padding(.top, 32)
      .padding(.bottom, 16)

      Divider()

      footerBar
    }
    .frame(minWidth: 720, minHeight: 640)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      refreshState()
      installArrowKeyMonitor()
      reportStep()
    }
    .onChange(of: step) { _, _ in
      persistStep()
      reportStep()
    }
    .onChange(of: dictationStep) { _, _ in
      persistStep()
      reportStep()
    }
    .onChange(of: modeChoice) { _, _ in modeChoiceRefused = false }
    .onDisappear { removeArrowKeyMonitor() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshState()
    }
  }

  @ViewBuilder
  private func dictationOnlyContent(_ current: DictationOnlyStep) -> some View {
    switch current {
    case .globeKey:
      DictationOnlyGlobeKeyStep()
    case .language:
      DictationOnlyLanguageStep()
    case .permissions:
      DictationOnlyPermissionsStep(micStatus: $micStatus, axStatus: $axStatus)
    case .download:
      DictationOnlyDownloadStep()
    case .test:
      DictationOnlyTestStep(onSuccess: { testSucceeded = true })
    case .glossary:
      DictationOnlyGlossaryStep()
    case .done:
      DictationOnlyDoneStep()
    }
  }

  /// Persist progress so a mid-tour restart resumes here (see `onboardingCurrentStep`).
  private func persistStep() {
    UserDefaults.standard.set(
      dictationStep?.rawValue ?? step.rawValue, forKey: UserDefaultsKeys.onboardingCurrentStep)
  }

  private func reportStep() {
    if let dictationStep {
      TelemetryService.shared.onboardingStepReached(dictationStep)
    } else {
      TelemetryService.shared.onboardingStepReached(step)
    }
  }

  /// Left/right arrows step backward/forward through the onboarding steps.
  /// Skipped while a text field is being edited so arrows keep moving the cursor.
  private func installArrowKeyMonitor() {
    guard keyDownMonitor == nil else { return }
    keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard let window = event.window, window.isKeyWindow,
        window === WelcomeWindowController.shared.window,
        !(window.firstResponder is NSTextView)
      else { return event }
      // Arrow keys always carry .numericPad/.function — only real modifiers should opt out.
      let modifiers = event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
      guard modifiers.isEmpty else { return event }
      switch event.keyCode {
      case Self.keyCodeLeftArrow:
        goBack()
        return nil
      case Self.keyCodeRightArrow:
        // Navigation only: respect step gating and never trigger Finish.
        guard canAdvance, !isLastStep else { return nil }
        advance()
        return nil
      default:
        return event
      }
    }
  }

  private func removeArrowKeyMonitor() {
    if let monitor = keyDownMonitor {
      NSEvent.removeMonitor(monitor)
      keyDownMonitor = nil
    }
  }

  private var footerBar: some View {
    HStack(spacing: 12) {
      Spacer()
      stepIndicator
      Spacer()
      // Keep the Back button always rendered so the footer geometry never
      // changes between steps; hide it visually on the intro step instead.
      Button("Back", action: goBack)
        .buttonStyle(.bordered)
        .opacity(isFirstScreen ? 0 : 1)
        .disabled(isFirstScreen)
        .accessibilityHidden(isFirstScreen)
        .pointerCursorOnHover()
      nextButton
        .disabled(!canAdvance)
        // A greyed-out button alone does not say why; the orange line above the footer does.
        .help(canAdvance ? "" : String(localized: "Finish this step first — the orange note above says what is missing."))
        .pointerCursorOnHover()
    }
    .padding(.horizontal, 40)
    .padding(.top, 18)
    .padding(.bottom, 24)
  }

  /// One primary button per screen: while the screen's own main button still has something to
  /// do (allow the microphone, free the key, run the test), Continue steps back to bordered.
  @ViewBuilder
  private var nextButton: some View {
    let button = Button(nextButtonTitle, action: advance)
    if hasPendingPrimaryInContent {
      button.buttonStyle(.bordered)
    } else {
      button.buttonStyle(.borderedProminent)
    }
  }

  private var hasPendingPrimaryInContent: Bool {
    switch dictationStep {
    case .globeKey: return globeKey.usage.conflictsWithFnDictation
    case .permissions:
      return micStatus != .granted || (!DictationOnlyDefaults.isAppStoreBuild && axStatus != .granted)
    case .test: return !testSucceeded
    // Not started, failed or short of space: the screen's own button (Download, Check again)
    // is what to click next.
    case .download:
      let model = DictationOnlyDownloadStep.model
      return !modelManager.isModelAvailable(model) && !modelManager.downloadingModels.contains(model)
    case .language, .glossary, .done, .none: return false
    }
  }

  private var stepIndicator: some View {
    let (position, count) = indicatorPosition
    return HStack(spacing: 6) {
      ForEach(1...count, id: \.self) { index in
        Circle()
          .fill(index <= position ? Color.accentColor : Color.secondary.opacity(0.3))
          .frame(width: 7, height: 7)
      }
      Text(String(localized: "\(position) of \(count)"))
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
    }
  }

  /// The first screen counts as step 1 of either path; the dots follow the path picked there.
  private var indicatorPosition: (Int, Int) {
    let dictationPath = dictationStep != nil || (step == .intro && modeChoice == .dictationOnly)
    if dictationPath {
      let count = dictationSteps.count + 1
      let index = dictationStep.flatMap { dictationSteps.firstIndex(of: $0) }.map { $0 + 2 } ?? 1
      return (index, count)
    }
    let steps = WelcomeStep.activeSteps
    return ((steps.firstIndex(of: step) ?? 0) + 1, steps.count)
  }

  private var isFirstScreen: Bool { dictationStep == nil && step == .intro }

  private var isLastStep: Bool {
    if let dictationStep { return dictationStep == .done }
    return step == .done
  }

  private var nextButtonTitle: String {
    isLastStep ? String(localized: "Finish") : String(localized: "Continue")
  }

  private var canAdvance: Bool {
    if let dictationStep {
      switch dictationStep {
      case .language: return DictationOnlyLanguageStep.isUsable(dictationLanguage)
      case .permissions: return micStatus == .granted || micStatus == .denied
      case .globeKey, .download, .test, .glossary, .done: return true
      }
    }
    switch step {
    case .intro:
      return modeChoice != nil
    case .dictationSetup:
      return setup.dictationCanAdvance
    default:
      return step.canAdvance(micStatus: micStatus, fnSetupResolved: fnSetupResolved)
    }
  }

  private var fnSetupResolved: Bool {
    GlobeKeyUsage.fnSetupMayContinue(fnEnabled: fnEnabled, usage: globeKey.usage)
  }

  private func advance() {
    if let dictationStep {
      if dictationStep == .done {
        WelcomeWindowController.shared.finish()
        return
      }
      if let idx = dictationSteps.firstIndex(of: dictationStep), idx + 1 < dictationSteps.count {
        self.dictationStep = dictationSteps[idx + 1]
      }
      return
    }
    if step == .intro {
      commitModeChoice()
      return
    }
    if step == .done {
      WelcomeWindowController.shared.finish()
      return
    }
    let steps = WelcomeStep.activeSteps
    if let idx = steps.firstIndex(of: step), idx + 1 < steps.count {
      step = steps[idx + 1]
    }
  }

  /// Continue on the first screen. "Dictation only" turns the mode on, applies its defaults once
  /// and starts the download; "All features" goes on with the existing tour, untouched.
  private func commitModeChoice() {
    guard let modeChoice else { return }
    let activity = DictationOnlyMode.currentActivity
    let outcome = OnboardingModeCommit.commit(
      modeChoice,
      modeIsOn: DictationOnlyMode.isEnabled,
      setMode: { enabled in
        DictationOnlyMode.setEnabled(
          enabled, meetingActive: activity.meetingActive, recording: activity.recording)
      },
      applyDefaults: { DictationOnlyDefaults.apply(preferredLanguages: TestProfileOverrides.current.preferredLanguages) })
    switch outcome {
    case .refusedWhileBusy:
      modeChoiceRefused = true
    case .allFeatures:
      modeChoiceRefused = false
      step = .dictationSetup
    case .dictationOnly(let result):
      modeChoiceRefused = false
      DebugLogger.log("ONBOARDING: chose dictation only (defaults: \(result))")
      DictationOnlyFlow.startDownloadEarly()
      let steps = DictationOnlyFlow.currentSteps()
      dictationSteps = steps
      testSucceeded = false
      dictationStep = steps.first
    }
  }

  private func goBack() {
    if let dictationStep {
      if let idx = dictationSteps.firstIndex(of: dictationStep), idx > 0 {
        self.dictationStep = dictationSteps[idx - 1]
      } else {
        // Back to the first screen; the mode stays on until another answer is committed there.
        self.dictationStep = nil
        step = .intro
      }
      return
    }
    let steps = WelcomeStep.activeSteps
    if let idx = steps.firstIndex(of: step), idx > 0 {
      step = steps[idx - 1]
    }
  }

  private func refreshState() {
    setup.refresh(choice: dictationChoice)
    micStatus = PermissionStatusChecker.status(for: .microphone)
    axStatus = PermissionStatusChecker.status(for: .accessibility)
    globeKey.refresh()
  }
}

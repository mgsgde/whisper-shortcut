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
  func canAdvance(micStatus: PermissionStatus) -> Bool {
    switch self {
    case .dictationSetup:
      return TranscriptionModel.loadSelected().hasRequiredCredential
    case .permissions:
      return micStatus == .granted || micStatus == .denied
    case .intro, .tryIt, .done:
      return true
    }
  }
}

/// Published copy of `WelcomeStep.dictationSetup.canAdvance` so Continue and the step's
/// "Ready to continue." line update together. The per-provider `@State` booleans used to be
/// that signal; they were written when a key was saved, OAuth finished, or a download completed.
@MainActor
final class OnboardingSetupState: ObservableObject {
  @Published private(set) var dictationCanAdvance: Bool

  init() {
    dictationCanAdvance = WelcomeStep.dictationSetup.canAdvance(micStatus: .notDetermined)
  }

  func refresh() {
    dictationCanAdvance = WelcomeStep.dictationSetup.canAdvance(micStatus: .notDetermined)
  }
}

struct WelcomeView: View {
  /// Key codes (layout-independent, NSEvent.keyCode).
  private static let keyCodeLeftArrow: UInt16 = 123
  private static let keyCodeRightArrow: UInt16 = 124

  /// Resume on the step the user last reached. Persisted in `onboardingCurrentStep` so a
  /// mid-tour app restart (e.g. macOS "Quit & Reopen" after granting a permission) continues
  /// where they left off. Defaults to `.intro` for a fresh tour (stored value 0 / unset).
  @State private var step: WelcomeStep =
    WelcomeStep.resume(from: UserDefaults.standard.integer(forKey: UserDefaultsKeys.onboardingCurrentStep))
  @State private var keyDownMonitor: Any?
  /// Re-read of "can the selected transcription model run" after a key, OAuth, or download.
  @StateObject private var setup = OnboardingSetupState()
  /// Gates the permissions step's Continue button. Updated by `PermissionsOverview`'s
  /// `onMicStatusChange` callback and the periodic refresh below.
  @State private var micStatus: PermissionStatus = PermissionStatusChecker.status(for: .microphone)
  /// The answer to "How should dictation run?". Kept here, not in the step, so Back/Continue
  /// does not forget it. Pre-filled from what is already set up when the tour is revisited.
  @State private var dictationChoice: DictationChoice? = DictationChoice.inferred()

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        switch step {
        case .intro:
          WelcomeIntroStep()
        case .dictationSetup:
          WelcomeDictationSetupStep(choice: $dictationChoice, setup: setup)
        case .permissions:
          WelcomePermissionsStep(micStatus: $micStatus)
        case .tryIt:
          WelcomeTryItStep()
        case .done:
          WelcomeDoneStep()
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
      TelemetryService.shared.onboardingStepReached(step)
    }
    .onChange(of: step) { newStep in
      // Persist progress so a mid-tour restart resumes here (see `onboardingCurrentStep`).
      UserDefaults.standard.set(newStep.rawValue, forKey: UserDefaultsKeys.onboardingCurrentStep)
      TelemetryService.shared.onboardingStepReached(newStep)
    }
    .onDisappear { removeArrowKeyMonitor() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshState()
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
        guard canAdvance, step != .done else { return nil }
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
        .opacity(step == .intro ? 0 : 1)
        .disabled(step == .intro)
        .accessibilityHidden(step == .intro)
        .pointerCursorOnHover()
      Button(nextButtonTitle, action: advance)
        .buttonStyle(.borderedProminent)
        .disabled(!canAdvance)
        .pointerCursorOnHover()
    }
    .padding(.horizontal, 40)
    .padding(.top, 18)
    .padding(.bottom, 24)
  }

  private var stepIndicator: some View {
    HStack(spacing: 6) {
      ForEach(WelcomeStep.activeSteps, id: \.rawValue) { s in
        Circle()
          .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
          .frame(width: 7, height: 7)
      }
      Text(step.indexLabel)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
    }
  }

  private var nextButtonTitle: String {
    step == .done ? String(localized: "Finish") : String(localized: "Continue")
  }

  private var canAdvance: Bool {
    switch step {
    case .dictationSetup:
      return setup.dictationCanAdvance
    default:
      return step.canAdvance(micStatus: micStatus)
    }
  }

  private func advance() {
    if step == .done {
      WelcomeWindowController.shared.finish()
      return
    }
    let steps = WelcomeStep.activeSteps
    if let idx = steps.firstIndex(of: step), idx + 1 < steps.count {
      step = steps[idx + 1]
    }
  }

  private func goBack() {
    let steps = WelcomeStep.activeSteps
    if let idx = steps.firstIndex(of: step), idx > 0 {
      step = steps[idx - 1]
    }
  }

  private func refreshState() {
    setup.refresh()
    micStatus = PermissionStatusChecker.status(for: .microphone)
  }
}

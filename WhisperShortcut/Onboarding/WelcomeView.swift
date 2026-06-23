import AppKit
import SwiftUI

enum WelcomeStep: Int, CaseIterable {
  case intro
  case privacy
  case apiKeys
  case permissions
  case smartImprovement
  case done

  var indexLabel: String {
    "\(rawValue + 1) of \(WelcomeStep.allCases.count)"
  }
}

struct WelcomeView: View {
  /// Key codes (layout-independent, NSEvent.keyCode).
  private static let keyCodeLeftArrow: UInt16 = 123
  private static let keyCodeRightArrow: UInt16 = 124

  @State private var step: WelcomeStep = .intro
  @State private var keyDownMonitor: Any?
  @State private var hasGeminiKey: Bool = KeychainManager.shared.hasValidGoogleAPIKey()
  @State private var hasOpenAIKey: Bool = KeychainManager.shared.hasValidOpenAIAPIKey()
  @State private var hasXAIKey: Bool = KeychainManager.shared.hasValidXAIAPIKey()
  /// True once an offline Whisper model is downloaded, which lets a user finish
  /// setup and dictate with no provider key at all (the key step's other exit).
  @State private var offlineReady: Bool = ModelManager.shared.isModelAvailable(.whisperBase)
  /// Gates the permissions step's Continue button. Updated by `PermissionsOverview`'s
  /// `onMicStatusChange` callback and the periodic refresh below.
  @State private var micStatus: PermissionStatus = PermissionStatusChecker.status(for: .microphone)
  @AppStorage(UserDefaultsKeys.contextLoggingEnabled) private var saveUsageData = true

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        switch step {
        case .intro:
          WelcomeIntroStep()
        case .privacy:
          WelcomePrivacyStep()
        case .apiKeys:
          WelcomeAPIKeysStep(
            hasGeminiKey: $hasGeminiKey,
            hasOpenAIKey: $hasOpenAIKey,
            hasXAIKey: $hasXAIKey,
            offlineReady: $offlineReady
          )
        case .permissions:
          WelcomePermissionsStep(micStatus: $micStatus)
        case .smartImprovement:
          WelcomeSmartImprovementStep(saveUsageData: $saveUsageData)
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
    .frame(minWidth: 720, minHeight: 540)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      refreshState()
      installArrowKeyMonitor()
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
      if step != .intro {
        Button("Back", action: goBack)
          .buttonStyle(.bordered)
          .pointerCursorOnHover()
      }
      Button(nextButtonTitle, action: advance)
        .buttonStyle(.borderedProminent)
        .disabled(!canAdvance)
        .pointerCursorOnHover()
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
  }

  private var stepIndicator: some View {
    HStack(spacing: 6) {
      ForEach(WelcomeStep.allCases, id: \.rawValue) { s in
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
    step == .done ? "Finish" : "Continue"
  }

  private var canAdvance: Bool {
    switch step {
    case .apiKeys:
      return hasGeminiKey || hasOpenAIKey || hasXAIKey || offlineReady
    case .permissions:
      return micStatus == .granted
    default:
      return true
    }
  }

  private func advance() {
    if step == .done {
      WelcomeWindowController.shared.finish()
      return
    }
    if let next = WelcomeStep(rawValue: step.rawValue + 1) {
      step = next
    }
  }

  private func goBack() {
    if let prev = WelcomeStep(rawValue: step.rawValue - 1) {
      step = prev
    }
  }

  private func refreshState() {
    hasGeminiKey = KeychainManager.shared.hasValidGoogleAPIKey()
    hasOpenAIKey = KeychainManager.shared.hasValidOpenAIAPIKey()
    hasXAIKey = KeychainManager.shared.hasValidXAIAPIKey()
    offlineReady = ModelManager.shared.isModelAvailable(.whisperBase)
    micStatus = PermissionStatusChecker.status(for: .microphone)
  }
}

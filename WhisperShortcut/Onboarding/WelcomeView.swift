import AppKit
import SwiftUI

enum WelcomeStep: Int, CaseIterable {
  case intro
  case privacy
  case apiKeys
  case microphone
  case accessibility
  case done

  var indexLabel: String {
    "\(rawValue + 1) of \(WelcomeStep.allCases.count)"
  }
}

struct WelcomeView: View {
  @State private var step: WelcomeStep = .intro
  @State private var hasGeminiKey: Bool = KeychainManager.shared.hasValidGoogleAPIKey()
  @State private var hasOpenAIKey: Bool = KeychainManager.shared.hasValidOpenAIAPIKey()
  @State private var hasXAIKey: Bool = KeychainManager.shared.hasValidXAIAPIKey()
  @State private var micStatus: PermissionStatus = PermissionStatusChecker.status(for: .microphone)
  @State private var axStatus: PermissionStatus = PermissionStatusChecker.status(for: .accessibility)

  private let refreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

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
            hasXAIKey: $hasXAIKey
          )
        case .microphone:
          WelcomeMicStep(status: $micStatus)
        case .accessibility:
          WelcomeAccessibilityStep(status: $axStatus)
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
    .onAppear { refreshState() }
    .onReceive(refreshTimer) { _ in refreshState() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshState()
    }
  }

  private var footerBar: some View {
    HStack(spacing: 12) {
      if canSkip {
        Button("Skip", action: advance)
          .buttonStyle(.borderless)
          .pointerCursorOnHover()
      }
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

  private var canSkip: Bool {
    step == .accessibility
  }

  private var nextButtonTitle: String {
    switch step {
    case .done: return "Finish"
    case .accessibility: return "Continue"
    default: return "Continue"
    }
  }

  private var canAdvance: Bool {
    switch step {
    case .apiKeys:
      return hasGeminiKey || hasOpenAIKey || hasXAIKey
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
    micStatus = PermissionStatusChecker.status(for: .microphone)
    axStatus = PermissionStatusChecker.status(for: .accessibility)
  }
}

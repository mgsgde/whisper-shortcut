import AppKit
import SwiftUI

/// Privacy & Permissions tab — read-only status view for every macOS permission and
/// provider API key the app uses. Purely additive: this tab never triggers the existing
/// permission request flows in AudioRecorder / AccessibilityPermissionManager / ChatView.
/// Microphone is the one exception: when it's `.notDetermined` the user can request the
/// system prompt directly from this tab via `AVCaptureDevice.requestAccess`.
struct PrivacyPermissionsTab: View {
  @ObservedObject var viewModel: SettingsViewModel

  @State private var micStatus: PermissionStatus = .notDetermined
  @State private var axStatus: PermissionStatus = .denied
  @State private var screenStatus: PermissionStatus = .notDetermined
  @State private var hasGeminiKey: Bool = false
  @State private var hasOpenAIKey: Bool = false
  @State private var hasXAIKey: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SectionHeader(
        title: "Privacy & Permissions",
        subtitle: "What this app can do on your Mac, and what data leaves your device."
      )

      Spacer().frame(height: SettingsConstants.sectionSpacing)

      privacyPromiseBlock

      SpacedSectionDivider()

      SectionHeader(
        title: "macOS Permissions",
        subtitle: "Status reflects what System Settings has granted to WhisperShortcut."
      )

      Spacer().frame(height: 12)

      VStack(spacing: 14) {
        permissionRow(
          name: "Microphone",
          description: "Required to record audio for dictation and prompt modes.",
          required: true,
          status: micStatus,
          actions: micActions
        )
        Divider()
        permissionRow(
          name: "Accessibility",
          description: "Optional. Used only for auto-paste — inserting dictated text at your cursor by simulating a ⌘V keystroke. Off by default; enable auto-paste in Settings → General.",
          required: false,
          status: axStatus,
          actions: defaultActions(for: .accessibility)
        )
        Divider()
        permissionRow(
          name: "Screen Recording",
          description:
            "Optional. Lets you attach screenshots to chat messages and include screen context in Dictate Prompt requests.",
          required: false,
          status: screenStatus,
          actions: defaultActions(for: .screenRecording),
          // macOS caches the Screen Recording grant per process, so a running app keeps
          // showing the old status after you enable it — only a relaunch picks up the change.
          hint: screenStatus == .granted
            ? nil
            : "Just enabled it in System Settings? macOS only reflects the change after you quit and reopen WhisperShortcut."
        )
      }

      SpacedSectionDivider()

      SectionHeader(
        title: "Provider API Keys",
        subtitle:
          "Any single key unlocks every feature. Stored in the macOS Keychain. Configure in the General tab."
      )

      Spacer().frame(height: 12)

      VStack(spacing: 14) {
        apiKeyRow(provider: "Google Gemini", configured: hasGeminiKey)
        Divider()
        apiKeyRow(provider: "OpenAI", configured: hasOpenAIKey)
        Divider()
        apiKeyRow(
          provider: "xAI (Grok)",
          description: "Dictate Prompt is not available with Grok.",
          configured: hasXAIKey
        )
      }

      SpacedSectionDivider()

      SupportFeedbackSection(viewModel: viewModel)
    }
    .onAppear { refresh() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refresh()
    }
  }

  // MARK: - Privacy Promise

  @ViewBuilder
  private var privacyPromiseBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "lock.shield")
          .font(.title3)
          .foregroundStyle(.tint)
        Text(PrivacyCopy.promiseTitle)
          .font(.headline)
      }
      ForEach(PrivacyCopy.promiseBullets, id: \.self) { bullet in
        promiseBullet(bullet)
      }
      HStack(spacing: 12) {
        Button {
          if let url = URL(string: AppConstants.privacyPolicyURL) {
            NSWorkspace.shared.open(url)
          }
        } label: {
          Label("View full privacy policy", systemImage: "doc.text")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .pointerCursorOnHover()

        Button {
          relaunchWelcomeTour()
        } label: {
          Label("Show Welcome Tour again", systemImage: "sparkles")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .pointerCursorOnHover()
      }
      .padding(.top, 4)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func promiseBullet(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
      Text(text)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
  }

  // MARK: - Permission Row

  @ViewBuilder
  private func permissionRow(
    name: String,
    description: String,
    required: Bool,
    status: PermissionStatus,
    actions: AnyView,
    hint: String? = nil
  ) -> some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(name)
            .font(.callout)
            .fontWeight(.semibold)
          if required {
            Text("Required")
              .font(.caption2)
              .fontWeight(.medium)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.accentColor.opacity(0.15))
              .foregroundColor(.accentColor)
              .clipShape(Capsule())
          } else {
            Text("Optional")
              .font(.caption2)
              .fontWeight(.medium)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.secondary.opacity(0.15))
              .foregroundColor(.secondary)
              .clipShape(Capsule())
          }
          statusBadge(status)
        }
        Text(description)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let hint = hint {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
              .font(.caption)
              .foregroundStyle(.yellow)
            Text(hint)
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.top, 2)
        }
      }
      Spacer(minLength: 8)
      actions
    }
  }

  // MARK: - API Key Row

  @ViewBuilder
  private func apiKeyRow(provider: String, description: String? = nil, configured: Bool)
    -> some View
  {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(provider)
            .font(.callout)
            .fontWeight(.semibold)
          apiKeyBadge(configured: configured)
        }
        if let description {
          Text(description)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      Button(action: openGeneralTab) {
        Label(configured ? "Manage in General" : "Set in General",
              systemImage: "key.fill")
          .font(.callout)
      }
      .buttonStyle(.bordered)
      .pointerCursorOnHover()
    }
  }

  // MARK: - Status Badge

  @ViewBuilder
  private func statusBadge(_ status: PermissionStatus) -> some View {
    HStack(spacing: 5) {
      Image(systemName: "circle.fill")
        .font(.system(size: 8))
        .foregroundStyle(statusColor(status))
      Text(statusLabel(status))
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(
      Capsule().fill(statusColor(status).opacity(0.12))
    )
  }

  @ViewBuilder
  private func apiKeyBadge(configured: Bool) -> some View {
    HStack(spacing: 5) {
      Image(systemName: "circle.fill")
        .font(.system(size: 8))
        .foregroundStyle(configured ? .green : .gray)
      Text(configured ? "Configured" : "Not configured")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(
      Capsule().fill((configured ? Color.green : Color.gray).opacity(0.12))
    )
  }

  private func statusColor(_ status: PermissionStatus) -> Color {
    switch status {
    case .granted: return .green
    case .denied: return .red
    case .notDetermined: return .yellow
    case .notApplicable: return .gray
    }
  }

  private func statusLabel(_ status: PermissionStatus) -> String {
    switch status {
    case .granted: return "Granted"
    case .denied: return "Denied"
    case .notDetermined: return "Not requested"
    case .notApplicable: return "Not applicable"
    }
  }

  // MARK: - Actions

  private var micActions: AnyView {
    AnyView(
      HStack(spacing: 8) {
        if micStatus == .notDetermined {
          Button {
            PermissionStatusChecker.requestMicrophoneAccess { _ in
              refresh()
            }
          } label: {
            Label("Continue", systemImage: "mic")
              .font(.callout)
          }
          .buttonStyle(.borderedProminent)
          .pointerCursorOnHover()
        }
        Button {
          PermissionStatusChecker.openSystemSettings(for: .microphone)
        } label: {
          Label("Open System Settings", systemImage: "arrow.up.right.square")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .pointerCursorOnHover()
      }
    )
  }

  private func defaultActions(for kind: PermissionKind) -> AnyView {
    AnyView(
      Button {
        PermissionStatusChecker.openSystemSettings(for: kind)
      } label: {
        Label("Open System Settings", systemImage: "arrow.up.right.square")
          .font(.callout)
      }
      .buttonStyle(.bordered)
      .pointerCursorOnHover()
    )
  }

  // MARK: - Refresh + Navigation

  private func refresh() {
    micStatus = PermissionStatusChecker.status(for: .microphone)
    axStatus = PermissionStatusChecker.status(for: .accessibility)
    screenStatus = PermissionStatusChecker.status(for: .screenRecording)
    hasGeminiKey = KeychainManager.shared.hasValidGoogleAPIKey()
    hasOpenAIKey = KeychainManager.shared.hasValidOpenAIAPIKey()
    hasXAIKey = KeychainManager.shared.hasValidXAIAPIKey()
  }

  private func openGeneralTab() {
    NotificationCenter.default.post(name: .privacyTabRequestSwitchToGeneral, object: nil)
  }

  private func relaunchWelcomeTour() {
    SettingsManager.shared.closeSettings()
    WelcomeWindowController.shared.show()
  }
}

extension Notification.Name {
  /// Posted by the Privacy & Permissions tab when the user clicks an API-key action that
  /// should focus the General tab (where keys are actually managed). `SettingsView`
  /// listens and updates its selected tab.
  static let privacyTabRequestSwitchToGeneral = Notification.Name("WhisperShortcut.privacyTabRequestSwitchToGeneral")

  /// Posted by failure-path dialogs (e.g. AccessibilityPermissionManager, screen-capture
  /// failure in ChatView) to open the Settings window and switch to the Privacy &
  /// Permissions tab. `SettingsView` observes this and updates `selectedTab`.
  static let openPrivacyPermissionsTab = Notification.Name("WhisperShortcut.openPrivacyPermissionsTab")
}

import AppKit
import SwiftUI

/// The single, reusable macOS-permissions overview: one row per permission with live status,
/// an action button, and a Quit & Reopen affordance. Used in three places so the user always
/// sees the same picture and acts in one spot:
///   1. Onboarding (`WelcomePermissionsStep`)
///   2. The Permissions settings tab (`PermissionsTab`)
///   3. The destination when a feature is blocked by a missing permission (error routing)
///
/// Status is read via `PermissionStatusChecker` (never prompts) and refreshed on appear and
/// whenever the app reactivates — so returning from System Settings updates the UI live.
struct PermissionsOverview: View {
  enum Mode { case onboarding, settings }

  let mode: Mode
  /// Accessibility is shown only where auto-paste applies (settings, non-App-Store). It is
  /// intentionally omitted from onboarding: requesting it up front would imply the app needs it
  /// for core functionality, which it doesn't (App Store Guideline 2.4.5).
  var includeAccessibility: Bool = false
  /// Reports the microphone status after every refresh so a host (e.g. onboarding) can gate on it.
  var onMicStatusChange: ((PermissionStatus) -> Void)? = nil

  @State private var micStatus: PermissionStatus = .notDetermined
  @State private var axStatus: PermissionStatus = .denied
  @State private var screenStatus: PermissionStatus = .notDetermined

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      permissionRow(
        name: "Microphone",
        description: "Records what you say for dictation and Dictate Prompt. Audio is sent only to the provider you chose, then deleted.",
        required: true,
        status: micStatus,
        actions: micActions
      )

      if includeAccessibility {
        Divider()
        permissionRow(
          name: "Accessibility",
          description: "Optional. Used only for auto-paste — inserting dictated text at your cursor by simulating a ⌘V keystroke. Off by default; enable auto-paste in Settings → General.",
          required: false,
          status: axStatus,
          actions: accessibilityActions
        )
      }

      Divider()
      permissionRow(
        name: "Screen Recording",
        description: "Optional. Lets you attach screenshots to chat messages and include screen context in Dictate Prompt requests.",
        required: false,
        status: screenStatus,
        actions: screenActions,
        // macOS caches the Screen Recording grant per process: a running app keeps showing the
        // old status until relaunch. Point users at the Quit & Reopen button below.
        hint: screenStatus == .granted
          ? nil
          : "Just enabled it in System Settings? macOS only applies the change after you quit and reopen WhisperShortcut — use the button below."
      )

      // Relaunch affordance: Screen Recording / Accessibility grants only take effect after a full
      // restart — the single biggest place users get stuck ("granted it, still doesn't work").
      // Omitted during onboarding: relaunching mid-setup would restart the whole flow.
      if mode == .settings {
        HStack(spacing: 10) {
          Button(action: relaunchApp) {
            Label("Quit & Reopen WhisperShortcut", systemImage: "arrow.clockwise")
              .font(.callout)
          }
          .buttonStyle(.bordered)
          .pointerCursorOnHover()
          Text("Needed for Screen Recording or Accessibility changes to take effect.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear(perform: refresh)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refresh()
    }
  }

  // MARK: - Actions (native request first, then deep-link)

  /// Fixed width for the right-hand action column so every row's buttons share one trailing edge,
  /// stack vertically, and never truncate their labels regardless of how the description text wraps.
  private static let actionColumnWidth: CGFloat = 220

  /// Right-aligned, equal-width button column shared by all permission rows.
  private func actionStack<Content: View>(@ViewBuilder _ content: () -> Content) -> AnyView {
    AnyView(
      VStack(alignment: .trailing, spacing: 8) {
        content()
      }
      .frame(width: Self.actionColumnWidth)
    )
  }

  private var micActions: AnyView {
    actionStack {
      if micStatus == .notDetermined {
        Button {
          PermissionStatusChecker.requestMicrophoneAccess { _ in refresh() }
        } label: {
          actionLabel("Grant Access", systemImage: "mic")
        }
        .buttonStyle(.borderedProminent)
        .pointerCursorOnHover()
      }
      openSettingsButton(for: .microphone)
    }
  }

  private var screenActions: AnyView {
    actionStack {
      if screenStatus != .granted {
        Button(action: requestScreenRecording) {
          actionLabel("Grant Access", systemImage: "rectangle.inset.filled.and.person.filled")
        }
        .buttonStyle(.borderedProminent)
        .pointerCursorOnHover()
      }
      openSettingsButton(for: .screenRecording)
    }
  }

  private var accessibilityActions: AnyView {
    actionStack {
      if axStatus != .granted {
        Button {
          AccessibilityPermissionManager.requestAccessibilityAtOptIn()
          refresh()
        } label: {
          actionLabel("Grant Access", systemImage: "accessibility")
        }
        .buttonStyle(.borderedProminent)
        .pointerCursorOnHover()
      }
      openSettingsButton(for: .accessibility)
    }
  }

  /// Screen Recording has no completion-handler request API: `CGRequestScreenCaptureAccess()`
  /// shows the native prompt + pre-registers the app the first time, then silently no-ops. So we
  /// fire it, and if still not granted shortly after, deep-link into System Settings.
  private func requestScreenRecording() {
    let granted = PermissionStatusChecker.requestScreenRecordingAccess()
    refresh()
    guard !granted else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      refresh()
      if PermissionStatusChecker.status(for: .screenRecording) != .granted {
        PermissionStatusChecker.openSystemSettings(for: .screenRecording)
      }
    }
  }

  private func openSettingsButton(for kind: PermissionKind) -> some View {
    Button {
      PermissionStatusChecker.openSystemSettings(for: kind)
    } label: {
      actionLabel("Open System Settings", systemImage: "arrow.up.right.square")
    }
    .buttonStyle(.bordered)
    .pointerCursorOnHover()
  }

  /// Shared button label: full-width within the action column, single line, centered — so
  /// every action button is the same size and reads cleanly without truncation.
  private func actionLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.callout)
      .lineLimit(1)
      .frame(maxWidth: .infinity)
  }

  /// Quits and relaunches the app in one click — the restart macOS requires for Screen Recording /
  /// Accessibility grants to take effect.
  ///
  /// `NSWorkspace.openApplication` returns success while the current process is still alive but
  /// does not spawn a second instance; terminating then leaves nothing running. A short-lived
  /// detached shell (`sleep` + `open -n`) outlives this process and starts a fresh instance after quit.
  private func relaunchApp() {
    let bundlePath = Bundle.main.bundleURL.path
    let quotedPath = "'" + bundlePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let command = "( /bin/sleep 0.6 && /usr/bin/open -n \(quotedPath) ) >/dev/null 2>&1 &"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardInput = nil
    process.standardOutput = nil
    process.standardError = nil

    do {
      try process.run()
    } catch {
      DebugLogger.logError("PERMISSIONS: relaunch helper failed: \(error.localizedDescription)")
      return
    }

    DebugLogger.log("PERMISSIONS: relaunch scheduled via open -n in 0.6s; terminating current process")
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.shouldTerminate)
    UserDefaults.standard.synchronize()
    NSApp.terminate(nil)
  }

  // MARK: - Refresh

  private func refresh() {
    micStatus = PermissionStatusChecker.status(for: .microphone)
    axStatus = PermissionStatusChecker.status(for: .accessibility)
    screenStatus = PermissionStatusChecker.status(for: .screenRecording)
    onMicStatusChange?(micStatus)
  }

  // MARK: - Row

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
          Text(required ? "Required" : "Optional")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((required ? Color.accentColor : Color.secondary).opacity(0.15))
            .foregroundColor(required ? .accentColor : .secondary)
            .clipShape(Capsule())
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
    .background(Capsule().fill(statusColor(status).opacity(0.12)))
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
}

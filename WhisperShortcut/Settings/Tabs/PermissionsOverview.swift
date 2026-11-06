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
        name: PermissionKind.microphone.displayName,
        description: "Records what you say for dictation and Dictate Prompt. Audio is sent only to the provider you chose, then deleted.",
        required: true,
        status: micStatus,
        actions: primaryAction(for: .microphone, status: micStatus, required: true),
        hint: micStatus == .denied
          ? "macOS won't ask again — enable it in System Settings → Microphone, then return here. You can skip this and grant it later."
          : nil
      )

      if includeAccessibility {
        Divider()
        permissionRow(
          name: PermissionKind.accessibility.displayName,
          description: "Optional. Used only for auto-paste — inserting dictated text at your cursor by simulating a ⌘V keystroke. Auto-paste is on once you grant this; switch it off in Settings → General → Clipboard Behavior.",
          required: false,
          status: axStatus,
          actions: primaryAction(for: .accessibility, status: axStatus, required: false)
        )
      }

      Divider()
      permissionRow(
        name: PermissionKind.screenRecording.displayName,
        description: "Optional. Lets you attach screenshots to chat messages and include screen context in Dictate Prompt requests.",
        required: false,
        status: screenStatus,
        actions: primaryAction(for: .screenRecording, status: screenStatus, required: false),
        // macOS caches the Screen Recording grant per process: a running app keeps showing the
        // old status until relaunch. Point users at the Quit & Reopen button below.
        hint: screenStatus == .denied
          ? mode == .settings
            ? "Just enabled it in System Settings? macOS only applies the change after you quit and reopen WhisperShortcut — use the button below."
            : "macOS may offer to quit and reopen WhisperShortcut — that's fine, the tour continues where you left off."
          : nil
      )

      // Relaunch affordance: a Screen Recording grant only takes effect after a full restart.
      // Accessibility updates live. Omitted during onboarding: relaunching mid-setup would
      // restart the whole flow.
      if mode == .settings {
        HStack(spacing: 10) {
          Button(action: relaunchApp) {
            Label("Quit & Reopen WhisperShortcut", systemImage: "arrow.clockwise")
              .font(.callout)
          }
          .buttonStyle(.bordered)
          .pointerCursorOnHover()
          Text("Needed after turning on Screen Recording.")
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

  /// Fixed width for the right-hand action column so every row's button shares one trailing edge
  /// and never truncates its label — including the German "In Systemeinstellungen einschalten".
  private static let actionColumnWidth: CGFloat = 250

  /// One button per row. Granted rows leave the column empty. Not-yet-requested rows ask macOS.
  /// Denied rows open System Settings. Onboarding highlights only the required microphone row.
  private func primaryAction(for kind: PermissionKind, status: PermissionStatus, required: Bool) -> AnyView {
    let prominent = required || mode == .settings
    let title: String
    let systemImage: String
    let action: () -> Void

    switch status {
    case .granted, .notApplicable:
      return AnyView(EmptyView().frame(width: Self.actionColumnWidth))
    case .notDetermined:
      title = String(localized: "Allow…")
      systemImage = "checkmark.shield"
      action = {
        switch kind {
        case .microphone:
          PermissionStatusChecker.requestMicrophoneAccess { _ in refresh() }
        case .screenRecording:
          PermissionStatusChecker.requestThenOpenSystemSettings(for: .screenRecording)
          refresh()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            refresh()
          }
        case .accessibility:
          AccessibilityPermissionManager.requestAccessibilityAtOptIn(for: .autoPaste)
          refresh()
        }
      }
    case .denied:
      title = String(localized: "Turn On in System Settings")
      systemImage = "arrow.up.right.square"
      action = {
        PermissionStatusChecker.requestThenOpenSystemSettings(for: kind)
        refresh()
      }
    }

    let button = Button(action: action) {
      actionLabel(title, systemImage: systemImage)
    }
    .pointerCursorOnHover()

    if prominent {
      return AnyView(button.buttonStyle(.borderedProminent).frame(width: Self.actionColumnWidth))
    }
    return AnyView(button.buttonStyle(.bordered).frame(width: Self.actionColumnWidth))
  }

  /// Shared button label: full-width within the action column, single line, centered — so
  /// every action button is the same size and reads cleanly without truncation.
  private func actionLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.callout)
      .lineLimit(1)
      .frame(maxWidth: .infinity)
  }

  /// Quits and relaunches the app in one click — the restart macOS requires for a Screen Recording
  /// grant to take effect. Accessibility updates live.
  ///
  /// `NSWorkspace.openApplication` returns success while the current process is still alive but
  /// does not spawn a second instance; terminating then leaves nothing running. A short-lived
  /// detached shell (`sleep` + `open -n`) outlives this process and starts a fresh instance after quit.
  private func relaunchApp() {
    let bundlePath = Bundle.main.bundleURL.path
    let quotedPath = "'" + bundlePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    // A sidecar must come back as one (it would otherwise register hotkeys next to the release).
    let sidecarArgs = AppConstants.isSidecarInstance ? " --args --sidecar" : ""
    let command = "( /bin/sleep 0.6 && /usr/bin/open -n \(quotedPath)\(sidecarArgs) ) >/dev/null 2>&1 &"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardInput = nil
    process.standardOutput = nil
    process.standardError = nil

    do {
      try process.run()
    } catch {
      DebugLogger.logError("PERMISSIONS: relaunch helper failed: \(error.logDescription)")
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
    description: LocalizedStringKey,
    required: Bool,
    status: PermissionStatus,
    actions: AnyView,
    hint: LocalizedStringKey? = nil
  ) -> some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(verbatim: name)
            .font(.callout)
            .fontWeight(.semibold)
          Text(required ? ("Required" as LocalizedStringKey) : "Optional")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((required ? Color.accentColor : Color.secondary).opacity(0.15))
            .foregroundColor(required ? .accentColor : .secondary)
            .clipShape(Capsule())
          PermissionStatusBadge(status: status)
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
}

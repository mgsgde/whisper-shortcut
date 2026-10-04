import AppKit
import SwiftUI

/// One-time invitation to share usage statistics, for installs that finished onboarding before
/// the onboarding card existed — they were never asked. New installs answer the question in
/// onboarding and are never asked again here.
///
/// Shown at most once per install, and only while the user is already focused on this app
/// (Settings or Chat opening, or the status-item menu closing), never at launch: a menu-bar app
/// launches at login, and a window then would steal focus from whatever the user is doing.
///
/// Runs as an app-modal window, like the review prompt's `NSAlert`: Settings and Chat skip their
/// close-on-focus-loss while `NSApp.modalWindow` is set, so neither disappears behind it.
final class UsageStatisticsNotice: NSObject, NSWindowDelegate {
  static let shared = UsageStatisticsNotice()

  private var window: NSWindow?

  /// Pure, so it is testable without a window. `isAvailable` is false under Offline Mode or the
  /// administrator key — the notice then waits rather than being spent.
  static func isDue(defaults: UserDefaults, isAvailable: Bool) -> Bool {
    isAvailable
      && defaults.bool(forKey: UserDefaultsKeys.telemetryPreExistingInstall)
      // Any stored value means the user already chose in Settings, either way.
      && defaults.object(forKey: UserDefaultsKeys.telemetryEnabled) == nil
      && !defaults.bool(forKey: UserDefaultsKeys.usageStatisticsNoticeShown)
  }

  /// Shows the notice if it is due. Returns true while the notice is (or was just) on screen, so
  /// callers skip the review prompt for this focus event instead of stacking two modals.
  @MainActor
  @discardableResult
  func showIfDue() -> Bool {
    if window != nil { return true }
    guard Self.isDue(defaults: .standard, isAvailable: TelemetryService.shared.isAvailable) else { return false }
    // Spent on display, before the modal loop: a crash or quit mid-notice must not re-ask.
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.usageStatisticsNoticeShown)

    let hosting = NSHostingController(rootView: UsageStatisticsNoticeView(onChoice: { [weak self] share in
      self?.finish(share: share)
    }))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: hosting.view.fittingSize),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.title = UsageStatisticsCopy.toggleTitle
    window.contentViewController = hosting
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    self.window = window

    DebugLogger.log("TELEMETRY: Showing one-time usage statistics notice")
    NSApp.activate(ignoringOtherApps: true)
    NSApp.runModal(for: window)
    return true
  }

  @MainActor
  private func finish(share: Bool) {
    if share {
      UserDefaults.standard.set(true, forKey: UserDefaultsKeys.telemetryEnabled)
      TelemetryService.shared.consentChanged(true)
    }
    // Declining writes nothing beyond the "shown" flag: no stored `false`, no ping.
    DebugLogger.log("TELEMETRY: Notice answered — \(share ? "sharing on" : "declined")")
    window?.close()
  }

  func windowWillClose(_ notification: Notification) {
    // Every exit ends here — either button, the close button, or Escape.
    NSApp.stopModal()
    window = nil
  }
}

struct UsageStatisticsNoticeView: View {
  let onChoice: (Bool) -> Void
  @State private var showingPreview = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .top, spacing: 16) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 64, height: 64)

        VStack(alignment: .leading, spacing: 10) {
          Text("Share anonymous usage statistics?")
            .font(.title3)
            .fontWeight(.semibold)

          Text(
            "New in this version: WhisperShortcut can tell me how often each feature is used and whether it worked. Counts only, like “12 dictations, 1 failed”. Never your words, audio, or which apps you use. No ID, no tracking."
          )
          .fixedSize(horizontal: false, vertical: true)

          Text(
            "I build this app alone, and right now the only usage I can see is my own. Your counts show me what actually breaks."
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

          Button("See exactly what is sent") { showingPreview = true }
            .buttonStyle(.link)
            .pointerCursorOnHover()
        }
      }

      HStack(spacing: 12) {
        Text("You can change this anytime in Settings → Privacy & Permissions.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button("No Thanks") { onChoice(false) }
          .keyboardShortcut(.cancelAction)
          .controlSize(.large)
        Button("Share Statistics") { onChoice(true) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
      }
    }
    .padding(.horizontal, 28)
    .padding(.top, 32)
    .padding(.bottom, 24)
    .frame(width: 540)
    .sheet(isPresented: $showingPreview) {
      UsageStatisticsPreviewSheet(onDismiss: { showingPreview = false })
    }
  }
}

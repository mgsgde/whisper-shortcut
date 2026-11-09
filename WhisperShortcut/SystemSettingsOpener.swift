import AppKit

/// Opens a System Settings pane in front of WhisperShortcut. Our Settings, Chat and Welcome
/// windows sit at `.floating`, which would keep System Settings hidden behind them. Lower them to
/// `.normal` for as long as another app is in front, and restore them when we become active again.
@MainActor
enum SystemSettingsOpener {
  private static var lowered: [NSWindow] = []
  private static var observer: NSObjectProtocol?

  static func open(_ url: URL) {
    open(url, reloadingPrivacyList: false)
  }

  /// With `reloadingPrivacyList`, for the Accessibility and Screen Recording panes, which list an
  /// app only after `tccd` registered it. Two things can make the list come up without
  /// WhisperShortcut on a fresh Mac. (a) A deep link into an already running System Settings only
  /// navigates; the privacy list is not reloaded, so an entry added since it was first shown stays
  /// missing. A sandboxed app cannot quit System Settings, so a running one is bounced through the
  /// Privacy & Security root pane first, then sent to the target pane. Not yet verified on a fresh
  /// Mac. (b) The pane was opened right after the permission request, before `tccd` had written
  /// the new entry. Waiting 0.5 s before opening gives it time.
  static func open(_ url: URL, reloadingPrivacyList: Bool) {
    guard reloadingPrivacyList else {
      lowerFloatingWindows()
      NSWorkspace.shared.open(url)
      return
    }
    let running = !NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.apple.systempreferences"
    ).isEmpty
    if running, let root = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
      DebugLogger.log(
        "SYSTEM-SETTINGS: already running — opening Privacy & Security first so the list reloads")
      lowerFloatingWindows()
      NSWorkspace.shared.open(root)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        MainActor.assumeIsolated { NSWorkspace.shared.open(url) }
      }
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        MainActor.assumeIsolated {
          lowerFloatingWindows()
          NSWorkspace.shared.open(url)
        }
      }
    }
  }

  /// `NSWorkspace.open` returns before System Settings is frontmost, so `didBecomeActive` can
  /// arrive while we are still active. Wait until we actually resign, then restore on the
  /// activation that follows.
  private static func lowerFloatingWindows() {
    for window in NSApp.windows where window.level == .floating && window.isVisible {
      window.level = .normal
      lowered.append(window)
    }
    guard observer == nil, !lowered.isEmpty else { return }
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { watchForReturn() }
    }
  }

  private static func watchForReturn() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { restore() }
    }
  }

  private static func restore() {
    for window in lowered where window.level == .normal { window.level = .floating }
    lowered.removeAll()
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }
}

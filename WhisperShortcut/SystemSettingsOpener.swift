import AppKit

/// Opens a System Settings pane in front of WhisperShortcut. Our Settings, Chat and Welcome
/// windows sit at `.floating`, which would keep System Settings hidden behind them. Lower them to
/// `.normal` for as long as another app is in front, and restore them when we become active again.
@MainActor
enum SystemSettingsOpener {
  private static var lowered: [NSWindow] = []
  private static var observer: NSObjectProtocol?

  static func open(_ url: URL) {
    lowerFloatingWindows()
    NSWorkspace.shared.open(url)
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

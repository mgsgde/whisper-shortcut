import AppKit
import SwiftUI

final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
  static let shared = WelcomeWindowController()

  private init() {
    let hosting = NSHostingController(rootView: WelcomeView())
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Welcome to WhisperShortcut"
    window.contentViewController = hosting
    window.isReleasedWhenClosed = false
    window.center()
    // Keep the onboarding window above all other windows (matches the Settings window),
    // so it never gets buried behind Settings or other apps during the tour.
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    super.init(window: window)
    window.delegate = self
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  func show() {
    // Rebuild the hosted view so `WelcomeView` re-reads the persisted step on each
    // presentation: a fresh launch (incl. macOS "Quit & Reopen") resumes mid-tour, while
    // a finished/dismissed tour has been reset to the intro.
    window?.contentViewController = NSHostingController(rootView: WelcomeView())
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    window?.center()
  }

  func finish() {
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasCompletedOnboarding)
    UserDefaults.standard.set(0, forKey: UserDefaultsKeys.onboardingCurrentStep)
    // Keys may have just been entered during onboarding — adapt model selections to them.
    ModelSelectionReconciler.reconcileAll()
    window?.close()
  }

  func windowWillClose(_ notification: Notification) {
    // Closing the window does NOT complete onboarding — only the final step's button does
    // (via `finish()`). Whether the window closes because of an app quit (e.g. macOS
    // "Quit & Reopen" after granting a permission mid-tour) or because the user dismissed
    // it, the saved step is kept and the tour reappears on the next launch until it has
    // been walked through to the end.
    //
    // Keys may have been entered before closing — adapt model selections to them.
    ModelSelectionReconciler.reconcileAll()
  }
}

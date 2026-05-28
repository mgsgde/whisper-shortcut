import AppKit
import SwiftUI

final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
  static let shared = WelcomeWindowController()

  private init() {
    let hosting = NSHostingController(rootView: WelcomeView())
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Welcome to WhisperShortcut"
    window.contentViewController = hosting
    window.isReleasedWhenClosed = false
    window.center()
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    super.init(window: window)
    window.delegate = self
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    window?.center()
  }

  func finish() {
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasCompletedOnboarding)
    window?.close()
  }

  func windowWillClose(_ notification: Notification) {
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasCompletedOnboarding)
  }
}

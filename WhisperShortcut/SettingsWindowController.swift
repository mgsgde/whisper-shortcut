import Cocoa
import SwiftUI

class SettingsWindowController: NSWindowController {

  init() {
    print("🔧 Creating SettingsWindowController...")

    // Create SwiftUI hosting window
    let settingsView = SettingsView()
    let hostingController = NSHostingController(rootView: settingsView)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "WhisperShortcut Settings"
    window.center()
    window.contentViewController = hostingController
    window.level = .floating
    window.isMovableByWindowBackground = false
    window.collectionBehavior = [.managed, .fullScreenNone]

    super.init(window: window)
    window.delegate = self

    print("🔧 SettingsWindowController created successfully")
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  func showWindow() {
    // Step 1: Temporarily become a regular app
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    // Step 2: Show the window
    window?.makeKeyAndOrderFront(nil)

    // Step 3: Ensure window gets focus
    DispatchQueue.main.async {
      self.window?.makeKeyAndOrderFront(nil)
    }
  }
}

// MARK: - NSWindowDelegate
extension SettingsWindowController: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    print("🔧 Settings window closing")

    // Step 4: Return to menu bar app when window closes
    DispatchQueue.main.async {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}

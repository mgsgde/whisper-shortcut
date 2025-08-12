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

    super.init(window: window)
    window.delegate = self

    print("🔧 SettingsWindowController created successfully")
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }
}

// MARK: - NSWindowDelegate
extension SettingsWindowController: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    print("🔧 Settings window closing")
  }
}

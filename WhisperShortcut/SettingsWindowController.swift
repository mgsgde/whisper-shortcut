import Cocoa
import SwiftUI

class SettingsWindowController: NSWindowController {

  init() {
    print("🔧 Creating SettingsWindowController...")

    // Create SwiftUI hosting window
    let settingsView = SettingsView()
    let hostingController = NSHostingController(rootView: settingsView)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
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

    // Set minimum size and let window auto-resize to content
    window.contentMinSize = NSSize(width: 520, height: 600)
    window.contentMaxSize = NSSize(width: 800, height: 1000)

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

    // Step 3: Ensure window gets focus and auto-resize to content
    DispatchQueue.main.async {
      self.window?.makeKeyAndOrderFront(nil)
      self.window?.contentView?.window?.setFrameAutosaveName("SettingsWindow")
      self.window?.contentView?.window?.setContentSize(
        self.window?.contentView?.fittingSize ?? NSSize(width: 520, height: 600))
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

import Cocoa
import SwiftUI

class SettingsWindowController: NSWindowController {

  // MARK: - Constants
  private enum Constants {
    static let windowWidth: CGFloat = 520
    static let windowHeight: CGFloat = 600
    static let maxWidth: CGFloat = 800
    static let maxHeight: CGFloat = 1000
    static let windowTitle = "WhisperShortcut Settings"
    static let frameAutosaveName = "SettingsWindow"
  }

  init() {
    print("🔧 Creating SettingsWindowController...")

    // Create SwiftUI hosting window
    let settingsView = SettingsView()
    let hostingController = NSHostingController(rootView: settingsView)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: Constants.windowWidth, height: Constants.windowHeight),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = Constants.windowTitle
    window.center()
    window.contentViewController = hostingController
    window.level = .floating
    window.isMovableByWindowBackground = false
    window.collectionBehavior = [.managed, .fullScreenNone]

    // Set minimum size and let window auto-resize to content
    window.contentMinSize = NSSize(width: Constants.windowWidth, height: Constants.windowHeight)
    window.contentMaxSize = NSSize(width: Constants.maxWidth, height: Constants.maxHeight)

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
      self.window?.contentView?.window?.setFrameAutosaveName(Constants.frameAutosaveName)
      self.window?.contentView?.window?.setContentSize(
        self.window?.contentView?.fittingSize
          ?? NSSize(width: Constants.windowWidth, height: Constants.windowHeight)
      )
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

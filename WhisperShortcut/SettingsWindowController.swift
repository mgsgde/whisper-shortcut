import Cocoa
import SwiftUI

class SettingsWindowController: NSWindowController {

  // MARK: - Constants
  private enum Constants {
    static let windowWidth: CGFloat = 720
    static let windowHeight: CGFloat = 750
    static let maxWidth: CGFloat = 1000
    static let maxHeight: CGFloat = 1000
    static let windowTitle = "Settings"
    static let frameAutosaveName = "SettingsWindow"
  }

  init() {

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

    // Set fixed size - no auto-resize
    window.contentMinSize = NSSize(width: Constants.windowWidth, height: Constants.windowHeight)
    window.contentMaxSize = NSSize(width: Constants.windowWidth, height: Constants.maxHeight)

    super.init(window: window)
    window.delegate = self

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

    // Step 3: Ensure window gets focus with fixed size
    DispatchQueue.main.async {
      self.window?.makeKeyAndOrderFront(nil)
      self.window?.contentView?.window?.setFrameAutosaveName(Constants.frameAutosaveName)
    }
  }
}

// MARK: - NSWindowDelegate
extension SettingsWindowController: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {

    // Step 4: Return to menu bar app when window closes
    DispatchQueue.main.async {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}

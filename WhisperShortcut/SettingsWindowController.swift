import Cocoa
import SwiftUI

class SettingsWindowController: NSWindowController {

  // MARK: - Constants
  private enum Constants {
    // Responsive sizing based on Apple's HIG
    static let preferredWidth: CGFloat = 900
    static let preferredHeight: CGFloat = 700

    // Size constraints following macOS patterns
    static let minWidth: CGFloat = 800
    static let minHeight: CGFloat = 600
    static let maxWidth: CGFloat = 1200
    static let maxHeight: CGFloat = 900

    // Responsive percentages (more flexible than fixed)
    static let widthPercentage: CGFloat = 0.75  // 75% of screen width
    static let heightPercentage: CGFloat = 0.70  // 70% of screen height

    static let windowTitle = "Settings"
    static let frameAutosaveName = "SettingsWindow"
  }

  init() {
    // Create SwiftUI hosting window
    let settingsView = SettingsView()
    let hostingController = NSHostingController(rootView: settingsView)

    // Calculate optimal window size using best practices
    let windowSize = Self.calculateOptimalWindowSize()

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )

    // Configure window following macOS best practices
    Self.configureWindow(window)
    window.contentViewController = hostingController

    super.init(window: window)
    window.delegate = self
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  // MARK: - Best Practice Methods

  private static func calculateOptimalWindowSize() -> NSSize {
    guard let screen = NSScreen.main else {
      return NSSize(width: Constants.preferredWidth, height: Constants.preferredHeight)
    }

    // Get the screen's usable area (accounting for Dock, menu bar, etc.)
    let usableFrame = screen.visibleFrame

    // Calculate responsive size with fallbacks
    let responsiveWidth = min(
      max(usableFrame.width * Constants.widthPercentage, Constants.minWidth),
      Constants.maxWidth
    )

    let responsiveHeight = min(
      max(usableFrame.height * Constants.heightPercentage, Constants.minHeight),
      Constants.maxHeight
    )

    // Ensure window doesn't exceed screen bounds
    let finalWidth = min(responsiveWidth, usableFrame.width - 40)  // 20px margin on each side
    let finalHeight = min(responsiveHeight, usableFrame.height - 40)

    return NSSize(width: finalWidth, height: finalHeight)
  }

  private static func configureWindow(_ window: NSWindow) {
    // Set window properties following macOS best practices
    window.title = Constants.windowTitle
    window.center()
    window.level = .floating
    window.isMovableByWindowBackground = false

    // Collection behavior for proper window management
    window.collectionBehavior = [.managed, .fullScreenNone, .participatesInCycle]

    // Set size constraints with reasonable limits
    window.contentMinSize = NSSize(width: Constants.minWidth, height: Constants.minHeight)
    window.contentMaxSize = NSSize(width: Constants.maxWidth, height: Constants.maxHeight)

    // Enable window restoration (remembers position/size)
    window.setFrameAutosaveName(Constants.frameAutosaveName)
  }

  private func centerWindowOnScreen() {
    guard let screen = NSScreen.main?.visibleFrame else { return }

    let currentFrame = window?.frame ?? NSRect.zero
    let newX = screen.midX - currentFrame.width / 2
    let newY = screen.midY - currentFrame.height / 2

    let newFrame = NSRect(
      x: newX,
      y: newY,
      width: currentFrame.width,
      height: currentFrame.height
    )

    window?.setFrame(newFrame, display: true, animate: true)
  }

  func showWindow() {
    // For LSUIElement apps, we can't change activation policy
    // Just activate and show the window
    NSApp.activate(ignoringOtherApps: true)

    // Show window with proper focus
    window?.makeKeyAndOrderFront(nil)

    // Ensure proper positioning and sizing
    DispatchQueue.main.async { [weak self] in
      self?.centerWindowOnScreen()
      self?.window?.makeKeyAndOrderFront(nil)
    }
  }
}

// MARK: - NSWindowDelegate
extension SettingsWindowController: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    // For LSUIElement apps, no need to change activation policy
    // The app remains a menu bar app automatically
  }

  // Handle window resize events for better responsiveness
  func windowDidResize(_ notification: Notification) {
    // Could add additional logic here for dynamic content adjustment
  }

  // Ensure window stays within screen bounds
  func windowWillMove(_ notification: Notification) {
    // Could add logic to prevent window from moving off-screen
  }
}

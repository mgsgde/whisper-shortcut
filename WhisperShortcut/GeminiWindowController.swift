import Cocoa
import SwiftUI

class GeminiWindowController: NSWindowController {

  // MARK: - Constants
  private enum Constants {
    static let preferredWidth: CGFloat = 580
    static let preferredHeight: CGFloat = 760

    static let minWidth: CGFloat = 440
    static let minHeight: CGFloat = 540
    static let maxWidth: CGFloat = 900
    static let maxHeight: CGFloat = 1200

    static let windowTitle = "Whisper Shortcut"
    static let frameAutosaveName = "GeminiWindow"

    // Bottom-right margin from screen edge
    static let screenMargin: CGFloat = 24
  }

  init() {
    let chatView = GeminiChatView()
    let hostingController = NSHostingController(rootView: chatView)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: Constants.preferredWidth, height: Constants.preferredHeight),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )

    window.title = Constants.windowTitle
    Self.applyLevelAndCollectionBehavior(to: window)
    window.contentMinSize = NSSize(width: Constants.minWidth, height: Constants.minHeight)
    window.contentMaxSize = NSSize(width: Constants.maxWidth, height: Constants.maxHeight)
    window.setFrameAutosaveName(Constants.frameAutosaveName)
    window.contentViewController = hostingController

    super.init(window: window)
    window.delegate = self

    // Position bottom-right on first launch (autosave overrides on subsequent opens)
    if !hasStoredFrame() {
      positionBottomRight()
    }
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  func showWindow() {
    ensureWindowOnCurrentScreen()
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  // MARK: - Private

  private static func applyLevelAndCollectionBehavior(to window: NSWindow) {
    window.level = .floating
    // Always show in current space (including fullscreen) so opening from fullscreen does not switch spaces.
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .participatesInCycle]
  }

  private func hasStoredFrame() -> Bool {
    UserDefaults.standard.object(forKey: "NSWindow Frame \(Constants.frameAutosaveName)") != nil
  }

  private func positionBottomRight() {
    guard let screen = NSScreen.main, let window = window else { return }
    positionBottomRight(on: screen, window: window)
  }

  private func positionBottomRight(on screen: NSScreen, window: NSWindow) {
    let usable = screen.visibleFrame
    let x = usable.maxX - window.frame.width - Constants.screenMargin
    let y = usable.minY + Constants.screenMargin
    window.setFrameOrigin(NSPoint(x: x, y: y))
  }

  /// If the window would appear on a different screen than the one the user is on, move it to the current screen (bottom-right).
  private func ensureWindowOnCurrentScreen() {
    guard let window = window,
          let currentScreen = NSScreen.main else { return }
    let windowFrame = window.frame
    let onCurrentScreen = currentScreen.visibleFrame.intersects(windowFrame)
    if !onCurrentScreen {
      positionBottomRight(on: currentScreen, window: window)
    }
  }
}

// MARK: - NSWindowDelegate
extension GeminiWindowController: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {}
}

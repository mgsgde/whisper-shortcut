import Cocoa
import SwiftUI

/// Window controller for the Meeting Chat split view (chat left, live transcript right).
class MeetingGeminiWindowController: NSWindowController {

  // MARK: - Constants
  private enum Constants {
    static let minWidth: CGFloat = 700
    static let minHeight: CGFloat = 540
    static let maxWidth: CGFloat = 1600
    static let maxHeight: CGFloat = 1600

    static let windowTitle = "Meeting – WhisperShortcut"
    static let frameAutosaveName = "MeetingGeminiWindowV1"
  }

  init() {
    let splitView = MeetingChatSplitView()
    let hostingController = NSHostingController(rootView: splitView)
    hostingController.sizingOptions = []

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: Constants.minWidth, height: Constants.minHeight),
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
    shouldCascadeWindows = false
    window.delegate = self
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  func showWindow() {
    if !hasStoredFrame(), let window = window, let screen = NSScreen.main {
      applyDefaultFrame(on: screen, window: window)
    }
    ensureWindowOnCurrentScreen()
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    NotificationCenter.default.post(name: .geminiFocusInput, object: nil)
  }

  // MARK: - Private

  private static func applyLevelAndCollectionBehavior(to window: NSWindow) {
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .participatesInCycle]
  }

  private func hasStoredFrame() -> Bool {
    UserDefaults.standard.object(forKey: "NSWindow Frame \(Constants.frameAutosaveName)") != nil
  }

  /// Default frame: full screen (visible frame of the main display).
  private func applyDefaultFrame(on screen: NSScreen, window: NSWindow) {
    let frame = screen.visibleFrame
    window.setFrame(frame, display: true, animate: false)
  }

  private func ensureWindowOnCurrentScreen() {
    guard let window = window,
          let currentScreen = NSScreen.main else { return }
    let onCurrentScreen = currentScreen.visibleFrame.intersects(window.frame)
    if !onCurrentScreen {
      applyDefaultFrame(on: currentScreen, window: window)
    }
  }
}

// MARK: - NSWindowDelegate
extension MeetingGeminiWindowController: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    // No special cleanup; store is independent
  }
}

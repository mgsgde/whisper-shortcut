import Cocoa
import SwiftUI

/// Custom NSWindow subclass that routes Cmd+W to tab-close instead of window-close.
private class GeminiWindow: NSWindow {
  override func performClose(_ sender: Any?) {
    NotificationCenter.default.post(name: .geminiCloseTab, object: nil)
  }
}

class GeminiWindowController: NSWindowController {

  /// Key codes (layout-independent, NSEvent.keyCode).
  private static let keyCodeUpArrow: UInt16 = 126
  private static let keyCodeDownArrow: UInt16 = 125
  private static let keyCodeN: UInt16 = 45
  private static let keyCodeW: UInt16 = 13

  private var keyDownMonitor: Any?
  private var needsDefaultFrame: Bool = false

  // MARK: - Constants
  private enum Constants {
    static let minWidth: CGFloat = 440
    static let minHeight: CGFloat = 540
    static let maxWidth: CGFloat = 1200
    static let maxHeight: CGFloat = 1600

    static let windowTitle = "WhisperShortcut"
    static let frameAutosaveName = "GeminiWindowV4"
  }

  init() {
    let chatView = GeminiChatView()
    let hostingController = NSHostingController(rootView: chatView)
    hostingController.sizingOptions = []

    let window = GeminiWindow(
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
    needsDefaultFrame = !hasStoredFrame()
    window.delegate = self
    setupCmdArrowScrollMonitor()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  func showWindow() {
    if needsDefaultFrame, let window = window, let screen = NSScreen.main {
      applyDefaultFrame(on: screen, window: window)
      needsDefaultFrame = false
    }
    ensureWindowOnCurrentScreen()
    setupCmdArrowScrollMonitor()  // Re-add monitor if it was removed when window closed
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

  /// Positions the window to fill the left third of the given screen at full height.
  private func applyDefaultFrame(on screen: NSScreen, window: NSWindow) {
    let usable = screen.visibleFrame
    let w = min(max(usable.width / 3, Constants.minWidth), Constants.maxWidth)
    let h = min(max(usable.height, Constants.minHeight), Constants.maxHeight)
    let frame = NSRect(x: usable.minX, y: usable.minY, width: w, height: h)
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

  /// Cmd+Up/Down scroll the chat; Cmd+N/W create/close tabs.
  /// Safe to call multiple times — skips if a monitor is already registered.
  private func setupCmdArrowScrollMonitor() {
    guard keyDownMonitor == nil else { return }
    keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let win = self.window, win.isKeyWindow else { return event }
      guard event.modifierFlags.contains(.command) else { return event }
      switch event.keyCode {
      case Self.keyCodeN:
        NotificationCenter.default.post(name: .geminiNewChat, object: nil)
        return nil
      case Self.keyCodeW:
        NotificationCenter.default.post(name: .geminiCloseTab, object: nil)
        return nil
      case Self.keyCodeUpArrow:
        NotificationCenter.default.post(name: .geminiScrollToTop, object: nil)
        return nil
      case Self.keyCodeDownArrow:
        NotificationCenter.default.post(name: .geminiScrollToBottom, object: nil)
        return nil
      default:
        return event
      }
    }
  }

  private func removeCmdArrowScrollMonitor() {
    if let monitor = keyDownMonitor {
      NSEvent.removeMonitor(monitor)
      keyDownMonitor = nil
    }
  }
}

// MARK: - NSWindowDelegate
extension GeminiWindowController: NSWindowDelegate {
  func windowDidResignKey(_ notification: Notification) {
    let closeOnFocusLoss: Bool
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.geminiCloseOnFocusLoss) != nil {
      closeOnFocusLoss = UserDefaults.standard.bool(forKey: UserDefaultsKeys.geminiCloseOnFocusLoss)
    } else {
      closeOnFocusLoss = SettingsDefaults.geminiCloseOnFocusLoss
    }
    if closeOnFocusLoss {
      window?.close()
    }
  }

  func windowWillClose(_ notification: Notification) {
    removeCmdArrowScrollMonitor()
  }
}

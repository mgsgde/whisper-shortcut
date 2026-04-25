import Cocoa
import SwiftUI

/// Custom NSWindow subclass that routes Cmd+W to tab-close instead of window-close.
private class ChatWindow: NSWindow {
  override func performClose(_ sender: Any?) {
    NotificationCenter.default.post(name: .chatCloseTab, object: nil)
  }
}

class ChatWindowController: NSWindowController {

  /// Key codes (layout-independent, NSEvent.keyCode).
  private static let keyCodeUpArrow: UInt16 = 126
  private static let keyCodeDownArrow: UInt16 = 125
  private static let keyCodeN: UInt16 = 45
  private static let keyCodeW: UInt16 = 13
  private static let keyCodeT: UInt16 = 17
  private static let keyCodeBackslash: UInt16 = 42
  private static let keyCodeB: UInt16 = 11

  private var keyDownMonitor: Any?
  private var needsDefaultFrame: Bool = false

  /// Timestamp until which `windowDidResignKey` will NOT auto-close the window.
  /// Set when opening via the global shortcut so a brief focus transition does not dismiss the window.
  private var suppressCloseUntil: Date = .distantPast

  // MARK: - Constants
  private enum Constants {
    static let minWidth: CGFloat = 700
    static let minHeight: CGFloat = 540
    static let maxWidth: CGFloat = 1600
    static let maxHeight: CGFloat = 1600

    static let windowTitle = "WhisperShortcut"
    static let frameAutosaveName = "ChatWindowV5"
  }

  init() {
    let rootView = ChatRootView()
    let hostingController = NSHostingController(rootView: rootView)
    hostingController.sizingOptions = []

    let window = ChatWindow(
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
    NotificationCenter.default.post(name: .chatFocusInput, object: nil)
  }

  /// Temporarily suppresses close-on-focus-loss for the given duration.
  /// Used by the shortcut path to prevent the window from closing during the copy → show → prefill sequence.
  func suppressCloseOnFocusLoss(for duration: TimeInterval = 0.5) {
    suppressCloseUntil = Date(timeIntervalSinceNow: duration)
  }

  // MARK: - Private

  private static func applyLevelAndCollectionBehavior(to window: NSWindow) {
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .participatesInCycle]
  }

  private func hasStoredFrame() -> Bool {
    UserDefaults.standard.object(forKey: "NSWindow Frame \(Constants.frameAutosaveName)") != nil
  }

  /// Positions the window to fill the left half of the given screen at full height.
  private func applyDefaultFrame(on screen: NSScreen, window: NSWindow) {
    let usable = screen.visibleFrame
    let w = min(max(usable.width / 2, Constants.minWidth), Constants.maxWidth)
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
      let isShift = event.modifierFlags.contains(.shift)
      switch event.keyCode {
      case Self.keyCodeN:
        NotificationCenter.default.post(name: .chatNewChat, object: nil)
        return nil
      case Self.keyCodeT where isShift:
        NotificationCenter.default.post(name: .chatReopenLastClosedTab, object: nil)
        return nil
      case Self.keyCodeW:
        NotificationCenter.default.post(name: .chatCloseTab, object: nil)
        return nil
      case Self.keyCodeUpArrow:
        NotificationCenter.default.post(name: .chatScrollToTop, object: nil)
        return nil
      case Self.keyCodeDownArrow:
        NotificationCenter.default.post(name: .chatScrollToBottom, object: nil)
        return nil
      case Self.keyCodeBackslash, Self.keyCodeB:
        NotificationCenter.default.post(name: .chatToggleSidebar, object: nil)
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
extension ChatWindowController: NSWindowDelegate {
  func windowDidResignKey(_ notification: Notification) {
    // Don't close while a modal sheet/panel (e.g. file picker) is active
    if NSApp.modalWindow != nil { return }
    // Don't close during the shortcut copy → show → prefill sequence
    if Date() < suppressCloseUntil { return }
    let closeOnFocusLoss: Bool
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.chatCloseOnFocusLoss) != nil {
      closeOnFocusLoss = UserDefaults.standard.bool(forKey: UserDefaultsKeys.chatCloseOnFocusLoss)
    } else {
      closeOnFocusLoss = SettingsDefaults.chatCloseOnFocusLoss
    }
    if closeOnFocusLoss {
      window?.close()
    }
  }

  func windowWillClose(_ notification: Notification) {
    removeCmdArrowScrollMonitor()
  }
}

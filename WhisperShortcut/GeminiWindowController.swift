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

    static let windowTitle = "Gemini"
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
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  /// Applies floating and fullscreen preferences to the window (at init or when user changes settings).
  func applyWindowPreferences() {
    guard let window = window else { return }
    Self.applyLevelAndCollectionBehavior(to: window)
  }

  // MARK: - Private

  private static func geminiWindowFloating() -> Bool {
    UserDefaults.standard.object(forKey: UserDefaultsKeys.geminiWindowFloating) != nil
      ? UserDefaults.standard.bool(forKey: UserDefaultsKeys.geminiWindowFloating)
      : SettingsDefaults.geminiWindowFloating
  }

  private static func geminiWindowShowInFullscreen() -> Bool {
    UserDefaults.standard.object(forKey: UserDefaultsKeys.geminiWindowShowInFullscreen) != nil
      ? UserDefaults.standard.bool(forKey: UserDefaultsKeys.geminiWindowShowInFullscreen)
      : SettingsDefaults.geminiWindowShowInFullscreen
  }

  private static func applyLevelAndCollectionBehavior(to window: NSWindow) {
    window.level = geminiWindowFloating() ? .floating : .normal
    if geminiWindowShowInFullscreen() {
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .participatesInCycle]
    } else {
      window.collectionBehavior = [.managed, .fullScreenNone, .participatesInCycle]
    }
  }

  private func hasStoredFrame() -> Bool {
    UserDefaults.standard.object(forKey: "NSWindow Frame \(Constants.frameAutosaveName)") != nil
  }

  private func positionBottomRight() {
    guard let screen = NSScreen.main,
          let window = window else { return }
    let usable = screen.visibleFrame
    let x = usable.maxX - Constants.preferredWidth - Constants.screenMargin
    let y = usable.minY + Constants.screenMargin
    window.setFrameOrigin(NSPoint(x: x, y: y))
  }
}

// MARK: - NSWindowDelegate
extension GeminiWindowController: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {}
}

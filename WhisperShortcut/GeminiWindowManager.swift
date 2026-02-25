import Cocoa

class GeminiWindowManager {
  static let shared = GeminiWindowManager()
  private var windowController: GeminiWindowController?

  private init() {}

  func toggle() {
    if isWindowOpen() {
      close()
    } else {
      show()
    }
  }

  func show() {
    if windowController == nil {
      windowController = GeminiWindowController()
    }
    windowController?.showWindow()
  }

  func close() {
    windowController?.window?.close()
  }

  func isWindowOpen() -> Bool {
    guard let window = windowController?.window else { return false }
    return window.isVisible
  }

  /// Applies current window preferences (floating, show in fullscreen) to the Gemini window if open.
  func applyWindowPreferences() {
    windowController?.applyWindowPreferences()
  }
}

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
}

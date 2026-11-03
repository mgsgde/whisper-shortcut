import Cocoa

/// Selected text a macOS Service placed on its pasteboard, trimmed the way the rest of the app
/// treats a selection.
enum SelectionServiceText {
  static func text(from pasteboard: NSPasteboard) -> String? {
    guard let trimmed = pasteboard.string(forType: .string)?
      .trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

/// macOS Services that receive the user's selected text directly.
///
/// Services exist so the app can read a selection without the Accessibility permission and without
/// posting a synthetic Cmd+C, which the App Store rejects under Guideline 2.4.5. `Info.plist` is
/// shared, so both the direct download and the App Store build offer the same three services.
final class SelectionServicesProvider: NSObject {
  private weak var controller: MenuBarController?

  init(controller: MenuBarController) {
    self.controller = controller
  }

  @objc func readAloudService(
    _ pboard: NSPasteboard,
    userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    guard let text = SelectionServiceText.text(from: pboard) else {
      error.pointee = "No text selected." as NSString
      DebugLogger.logWarning("SERVICES: readAloudService — no text on the pasteboard")
      return
    }
    DebugLogger.log("SERVICES: readAloudService (\(text.count) chars)")
    controller?.readAloudFromService(text: text)
  }

  @objc func addToGlossaryService(
    _ pboard: NSPasteboard,
    userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    guard let text = SelectionServiceText.text(from: pboard) else {
      error.pointee = "No text selected." as NSString
      DebugLogger.logWarning("SERVICES: addToGlossaryService — no text on the pasteboard")
      return
    }
    DebugLogger.log("SERVICES: addToGlossaryService (\(text.count) chars)")
    controller?.addToGlossaryFromService(text: text)
  }

  @objc func dictatePromptService(
    _ pboard: NSPasteboard,
    userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    guard let text = SelectionServiceText.text(from: pboard) else {
      error.pointee = "No text selected." as NSString
      DebugLogger.logWarning("SERVICES: dictatePromptService — no text on the pasteboard")
      return
    }
    DebugLogger.log("SERVICES: dictatePromptService (\(text.count) chars)")
    controller?.dictatePromptFromService(text: text)
  }
}

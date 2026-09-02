import Testing
import AppKit
@testable import WhisperShortcut_AppStore

@Suite("Clipboard restore")
struct ClipboardManagerTests {

  @Test("Restore puts the captured snapshot back when nothing else wrote")
  func restoreWhenUnchanged() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("original", forType: .string)

    manager.captureRestorePointIfNeeded()
    manager.copyToClipboard(text: "dictated")
    #expect(manager.getClipboardText() == "dictated")
    #expect(manager.restorePendingSnapshot())
    #expect(manager.getClipboardText() == "original")
  }

  @Test("Restore is skipped when the pasteboard changed after the write")
  func skipRestoreWhenChanged() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("original", forType: .string)

    manager.captureRestorePointIfNeeded()
    manager.copyToClipboard(text: "dictated")
    pasteboard.clearContents()
    pasteboard.setString("user copied this", forType: .string)
    #expect(!manager.restorePendingSnapshot())
    #expect(manager.getClipboardText() == "user copied this")
  }
}

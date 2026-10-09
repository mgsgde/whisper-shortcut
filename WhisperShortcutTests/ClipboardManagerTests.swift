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

/// The App Store clipboard path tells the user's copies from the app's own writes by this value.
@Suite("Clipboard own-write tracking")
struct ClipboardOwnWriteTests {

  @Test("The app's own result copy is recognised; a later user copy is not")
  func ownWriteRecognised() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)
    #expect(manager.lastOwnWriteChangeCount == nil)

    manager.copyToClipboard(text: "result")
    let own = pasteboard.changeCount
    #expect(manager.lastOwnWriteChangeCount == own)
    #expect(!DictatePromptSelectionDecision.clipboardIsFreshSelection(
      currentChangeCount: pasteboard.changeCount, lastConsumedChangeCount: own - 1,
      lastOwnWriteChangeCount: manager.lastOwnWriteChangeCount))

    pasteboard.clearContents()
    pasteboard.setString("user copied this", forType: .string)
    #expect(DictatePromptSelectionDecision.clipboardIsFreshSelection(
      currentChangeCount: pasteboard.changeCount, lastConsumedChangeCount: own,
      lastOwnWriteChangeCount: manager.lastOwnWriteChangeCount))
  }

  @Test("Dropping a restore point does not forget the app's own write")
  func discardKeepsOwnWrite() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)
    manager.copyToClipboard(text: "result")
    manager.discardRestorePoint()
    #expect(manager.lastOwnWriteChangeCount == pasteboard.changeCount)
  }
}

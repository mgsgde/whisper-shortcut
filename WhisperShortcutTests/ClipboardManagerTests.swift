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

@Suite("Dictate Prompt selection capture")
struct SelectionCaptureTests {

  @Test("A synthetic ⌘C that copied nothing yields no selection, not the stale clipboard")
  func staleClipboardIgnored() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("previous patient's note", forType: .string)

    manager.markSelectionCopyStart()
    // ⌘C with nothing selected writes nothing.
    #expect(manager.takeCopiedSelectionText() == nil)
  }

  @Test("A synthetic ⌘C that copied text yields that text")
  func copiedSelectionUsed() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("old", forType: .string)

    manager.markSelectionCopyStart()
    pasteboard.clearContents()
    pasteboard.setString("selected text", forType: .string)
    #expect(manager.takeCopiedSelectionText() == "selected text")
  }

  @Test("Without a marked copy the clipboard is read as-is, and the mark is consumed")
  func unmarkedFallsBack() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("copied on purpose", forType: .string)
    #expect(manager.takeCopiedSelectionText() == "copied on purpose")

    manager.markSelectionCopyStart()
    #expect(manager.takeCopiedSelectionText() == nil)
    #expect(manager.takeCopiedSelectionText() == "copied on purpose")
  }
}

import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Paste target policy")
struct PasteTargetPolicyTests {
  private let own = PasteTarget(pid: 100, bundleId: "com.example.ws")
  private let notes = PasteTarget(pid: 200, bundleId: "com.example.notes")
  private let mail = PasteTarget(pid: 300, bundleId: "com.example.mail")

  @Test("Same app in front as at record time: paste")
  func sameAppPastes() {
    #expect(PasteTargetPolicy.action(frontmost: notes, recorded: notes, own: own) == .pasteNow)
  }

  @Test("User switched to another app: leave it on the clipboard, do not steal focus")
  func differentAppStaysOnClipboard() {
    #expect(PasteTargetPolicy.action(frontmost: mail, recorded: notes, own: own) == .clipboardOnly)
  }

  @Test("Nothing in front but a recorded app exists: activate it")
  func nothingInFrontActivates() {
    #expect(PasteTargetPolicy.action(frontmost: nil, recorded: notes, own: own) == .activateRecordedThenPaste)
  }

  @Test("WhisperShortcut in front but a recorded app exists: activate it")
  func ownAppInFrontActivates() {
    #expect(PasteTargetPolicy.action(frontmost: own, recorded: notes, own: own) == .activateRecordedThenPaste)
  }

  @Test("Never paste into WhisperShortcut itself unless its text field still has focus")
  func neverPastesIntoSelf() {
    #expect(PasteTargetPolicy.action(frontmost: own, recorded: own, own: own) == .clipboardOnly)
    #expect(PasteTargetPolicy.action(frontmost: notes, recorded: own, own: own) == .clipboardOnly)
    #expect(PasteTargetPolicy.action(frontmost: own, recorded: nil, own: own) == .clipboardOnly)
  }

  @Test("Dictated into our own text field (Chat input) and it still has focus: paste")
  func pastesIntoOwnFocusedTextField() {
    #expect(
      PasteTargetPolicy.action(frontmost: own, recorded: own, own: own, ownTextFieldStillFocused: true)
        == .pasteNow)
    // Focus left for another app: still no ⌘V, and no focus grab back into our window.
    #expect(
      PasteTargetPolicy.action(frontmost: notes, recorded: own, own: own, ownTextFieldStillFocused: true)
        == .clipboardOnly)
  }

  @Test("Nothing recorded: paste into whatever is in front, unless that is us")
  func nothingRecorded() {
    #expect(PasteTargetPolicy.action(frontmost: mail, recorded: nil, own: own) == .pasteNow)
    #expect(PasteTargetPolicy.action(frontmost: nil, recorded: nil, own: own) == .clipboardOnly)
  }

  @Test("A relaunched app (new pid, same bundle id) is still the same app")
  func bundleIdMatches() {
    let relaunched = PasteTarget(pid: 999, bundleId: "com.example.notes")
    #expect(PasteTargetPolicy.action(frontmost: relaunched, recorded: notes, own: own) == .pasteNow)
  }
}

@Suite("Clipboard paste guard")
struct ClipboardPasteGuardTests {
  @Test("Untouched pasteboard: paste")
  func unchangedPastes() {
    #expect(
      ClipboardPasteGuard.pasteAllowed(
        changeCountAtWrite: 7, currentChangeCount: 7, expectedText: "neu", currentText: "neu"))
  }

  @Test("Pasteboard written by someone else: no paste")
  func movedCountBlocks() {
    #expect(
      !ClipboardPasteGuard.pasteAllowed(
        changeCountAtWrite: 7, currentChangeCount: 8, expectedText: "neu", currentText: "neu"))
  }

  @Test("Same count but other text: no paste")
  func otherTextBlocks() {
    #expect(
      !ClipboardPasteGuard.pasteAllowed(
        changeCountAtWrite: 7, currentChangeCount: 7, expectedText: "neu", currentText: "alt"))
    #expect(
      !ClipboardPasteGuard.pasteAllowed(
        changeCountAtWrite: 7, currentChangeCount: 7, expectedText: "neu", currentText: nil))
  }

  @Test("Restore only while nothing wrote since our write")
  func restoreDecision() {
    #expect(ClipboardPasteGuard.restoreAllowed(changeCountAtWrite: 7, currentChangeCount: 7))
    #expect(!ClipboardPasteGuard.restoreAllowed(changeCountAtWrite: 7, currentChangeCount: 9))
  }

  @Test("Delayed action: a stale closure does nothing, the newest restores or discards")
  func delayedAction() {
    // Stale (a newer paste started meanwhile): never touches the pasteboard or restore point,
    // whether or not the count moved.
    #expect(
      ClipboardPasteGuard.delayedAction(
        generation: 1, latestGeneration: 2, changeCountAtWrite: 7, currentChangeCount: 9) == .ignore)
    #expect(
      ClipboardPasteGuard.delayedAction(
        generation: 1, latestGeneration: 2, changeCountAtWrite: 7, currentChangeCount: 7) == .ignore)
    // Newest, pasteboard unchanged: restore.
    #expect(
      ClipboardPasteGuard.delayedAction(
        generation: 2, latestGeneration: 2, changeCountAtWrite: 7, currentChangeCount: 7) == .restore)
    // Newest, something else wrote: discard.
    #expect(
      ClipboardPasteGuard.delayedAction(
        generation: 2, latestGeneration: 2, changeCountAtWrite: 7, currentChangeCount: 9) == .discard)
  }
}

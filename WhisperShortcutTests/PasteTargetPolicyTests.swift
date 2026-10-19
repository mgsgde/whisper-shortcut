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

  @Test("Never paste into WhisperShortcut itself")
  func neverPastesIntoSelf() {
    #expect(PasteTargetPolicy.action(frontmost: own, recorded: own, own: own) == .clipboardOnly)
    #expect(PasteTargetPolicy.action(frontmost: notes, recorded: own, own: own) == .clipboardOnly)
    #expect(PasteTargetPolicy.action(frontmost: own, recorded: nil, own: own) == .clipboardOnly)
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

  @Test("The hint text is the agreed copy")
  func hintText() {
    #expect(PasteTargetPolicy.copiedHint == "Copied – press ⌘V to paste")
  }
}

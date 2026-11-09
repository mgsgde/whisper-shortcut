import AppKit
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Live piece delivery proof")
@MainActor
struct LivePieceDeliveryTests {

  @Test("A written live piece is unread until someone pastes it, then the text comes back")
  func readMarksDelivery() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)
    manager.copyLivePiece(text: "hello piece")
    #expect(!manager.livePieceWasRead())
    #expect(pasteboard.string(forType: .string) == "hello piece")
    #expect(manager.livePieceWasRead())
    #expect(manager.livePieceReadLatencyMs != nil)
  }

  @Test("The transient and concealed markers are present and bookkeeping matches the pasteboard")
  func markersAndChangeCount() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)
    manager.copyLivePiece(text: "x")
    let types = pasteboard.types ?? []
    #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
    #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
    #expect(manager.lastOwnWriteChangeCount == pasteboard.changeCount)
  }

  @Test("Waiting times out when nothing reads, and returns early when a read happens")
  func waitBehaviour() async {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)
    manager.copyLivePiece(text: "a")
    #expect(await manager.waitForLivePieceRead(timeout: 0.1) == false)
    _ = pasteboard.string(forType: .string)
    #expect(await manager.waitForLivePieceRead(timeout: 0.1) == true)
  }

  @Test("A new piece starts unread")
  func newPieceStartsUnread() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)
    manager.copyLivePiece(text: "one")
    _ = pasteboard.string(forType: .string)
    manager.copyLivePiece(text: "two")
    #expect(!manager.livePieceWasRead())
  }
}

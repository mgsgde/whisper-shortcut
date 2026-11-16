import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The recorder row holds a "Currently used by X" warning while the user decides. When the other
/// row is cleared or moved meanwhile, the warning must not stay.
@Suite("Pending shortcut conflict revalidation")
struct PendingConflictResolutionTests {
  private let readAloud = ShortcutConflict(field: .readAloudPromptShortcut, label: "Read Aloud Prompt")
  private let chat = ShortcutConflict(field: .toggleChat, label: "Chat")

  @Test("The other row no longer holds the key: assign the pending shortcut")
  func freedKeyIsAssigned() {
    #expect(PendingConflictResolution.resolve(held: readAloud, now: nil) == .assign)
  }

  @Test("The same row still holds it: keep the warning")
  func sameOwnerKeepsWarning() {
    #expect(PendingConflictResolution.resolve(held: readAloud, now: readAloud) == .keep)
  }

  @Test("Another row holds it now: the warning follows the new owner")
  func newOwnerUpdatesWarning() {
    #expect(PendingConflictResolution.resolve(held: readAloud, now: chat) == .update(chat))
  }
}

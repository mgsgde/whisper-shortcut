import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Session-file pruning.
///
/// The store caps how many sessions it keeps on disk. Meetings, pinned chats and the current
/// session are exempt from deletion — and the bug this suite pins is that they used to consume
/// the cap anyway. With 49 meetings on file the cap left zero slots for ordinary chats, so every
/// save deleted them all: pressing Cmd+N destroyed the chat the user had just been reading.
@MainActor
@Suite("Chat session pruning")
struct ChatSessionPruningTests {

  /// Each test gets its own scoped store file so the suite never touches the real chat history.
  private static func makeStore() -> (ChatSessionStore, URL) {
    let scope = "prunetest-\(UUID().uuidString)"
    let store = ChatSessionStore(scope: scope)
    let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("gemini-sessions-\(scope).json")
    return (store, url)
  }

  private static func cleanUp(_ store: ChatSessionStore, _ url: URL) {
    store.flushToDisk()
    try? FileManager.default.removeItem(at: url)
  }

  @Test("A wall of meetings does not evict ordinary chats")
  func meetingsDoNotStarveChats() {
    let (store, url) = Self.makeStore()
    defer { Self.cleanUp(store, url) }

    // More meetings than the whole cap. Meetings are never pruned, so before the fix they
    // filled the budget and left nothing for chats.
    for i in 0..<60 {
      store.save(
        ChatSession(
          lastUpdated: Date(timeIntervalSince1970: 1_000 + Double(i)),
          title: "meeting \(i)",
          isMeeting: true))
    }

    // The chat the user is reading, then Cmd+N.
    var chat = store.createNewSession()
    chat.messages = [ChatMessage(role: .user, content: "keep me")]
    chat.title = "Grok Release Status"
    store.save(chat)
    _ = store.createNewSession()

    let survivor = store.session(by: chat.id)
    #expect(survivor != nil)
    #expect(survivor?.messages.count == 1)
    #expect(store.allSessions().filter { $0.isMeeting }.count == 60)
  }

  @Test("The cap still bounds how many ordinary chats are kept")
  func prunableChatsAreStillCapped() {
    let (store, url) = Self.makeStore()
    defer { Self.cleanUp(store, url) }

    let current = store.load().id
    for i in 0..<80 {
      store.save(
        ChatSession(
          lastUpdated: Date(timeIntervalSince1970: 2_000 + Double(i)),
          title: "chat \(i)"))
    }

    let prunable = store.allSessions().filter { !$0.isMeeting && !$0.pinned && $0.id != current }
    #expect(prunable.count == 50)
    // The most recent survive; the oldest are the ones dropped.
    #expect(prunable.contains { $0.title == "chat 79" })
    #expect(!prunable.contains { $0.title == "chat 0" })
  }

  @Test("A pinned chat survives even when the cap is full of newer chats")
  func pinnedChatsAreExempt() {
    let (store, url) = Self.makeStore()
    defer { Self.cleanUp(store, url) }

    let pinned = ChatSession(
      lastUpdated: Date(timeIntervalSince1970: 1), title: "pinned", pinned: true)
    store.save(pinned)
    for i in 0..<70 {
      store.save(
        ChatSession(
          lastUpdated: Date(timeIntervalSince1970: 3_000 + Double(i)),
          title: "chat \(i)"))
    }

    #expect(store.session(by: pinned.id) != nil)
  }
}

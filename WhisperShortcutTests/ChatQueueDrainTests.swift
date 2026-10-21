import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The global send queue must not let one busy chat hold up an idle one, and it must
/// drop items whose session has been deleted. FIFO within a single session stays.
@MainActor
@Suite("Chat queue drain")
struct ChatQueueDrainTests {

  private func queued(_ sessionId: UUID, _ content: String) -> ChatViewModel.QueuedChatMessage {
    ChatViewModel.QueuedChatMessage(sessionId: sessionId, content: content, attachedParts: [])
  }

  @Test func idleSessionSendsWhileAnotherIsBusy() {
    let busy = UUID()
    let idle = UUID()
    let queue = [queued(busy, "a1"), queued(idle, "b1"), queued(busy, "a2")]
    let (remaining, next) = ChatViewModel.drainNextQueuedMessage(
      queue,
      isSending: { $0 == busy },
      sessionExists: { _ in true })
    #expect(next?.content == "b1")
    #expect(remaining.map(\.content) == ["a1", "a2"])
  }

  @Test func fifoWithinASession() {
    let idle = UUID()
    let queue = [queued(idle, "1"), queued(idle, "2")]
    let (remaining, next) = ChatViewModel.drainNextQueuedMessage(
      queue,
      isSending: { _ in false },
      sessionExists: { _ in true })
    #expect(next?.content == "1")
    #expect(remaining.map(\.content) == ["2"])
  }

  @Test func busyHeadStaysQueuedWhenNothingElseCanSend() {
    let busy = UUID()
    let queue = [queued(busy, "a")]
    let (remaining, next) = ChatViewModel.drainNextQueuedMessage(
      queue,
      isSending: { $0 == busy },
      sessionExists: { _ in true })
    #expect(next == nil)
    #expect(remaining.map(\.content) == ["a"])
  }

  @Test func missingSessionsAreDropped() {
    let gone = UUID()
    let live = UUID()
    let queue = [queued(gone, "x"), queued(live, "y"), queued(gone, "z")]
    let (remaining, next) = ChatViewModel.drainNextQueuedMessage(
      queue,
      isSending: { _ in false },
      sessionExists: { $0 == live })
    #expect(next?.content == "y")
    #expect(remaining.isEmpty)
  }
}

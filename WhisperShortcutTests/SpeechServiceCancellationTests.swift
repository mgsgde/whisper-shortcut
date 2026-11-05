import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Unstructured task cancellation")
struct SpeechServiceCancellationTests {

  /// Streaming dictate chunks call `transcribe(cancellable: false)`; the session cancels the
  /// task that awaits it, which must reach the work inside.
  @Test("Cancelling the awaiting task cancels the wrapped unstructured task")
  func cancellationReachesWrappedTask() async {
    let started = AsyncStream<Void>.makeStream()
    let inner = Task<String, Error> {
      started.continuation.yield()
      try await Task.sleep(for: .seconds(30))
      return "finished"
    }
    let awaiting = Task { try await SpeechService.value(of: inner) }
    var iterator = started.stream.makeAsyncIterator()
    await iterator.next()
    awaiting.cancel()

    do {
      _ = try await awaiting.value
      Issue.record("Expected cancellation")
    } catch {
      #expect(error is CancellationError)
    }
    #expect(inner.isCancelled)
  }
}

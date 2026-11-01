import Foundation

/// Coalesces a burst of values into one async commit after `delay`, with an
/// immediate flush for disappear / window-close. Used by the API-key field so a
/// paste is one Keychain write, not one per character on the main actor.
@MainActor
final class DebouncedAsyncCommit<Value: Sendable> {
  let delay: Duration
  private var task: Task<Void, Never>?
  private let commit: @MainActor (Value) async -> Void

  init(delay: Duration, commit: @escaping @MainActor (Value) async -> Void) {
    self.delay = delay
    self.commit = commit
  }

  func schedule(_ value: Value) {
    task?.cancel()
    task = Task { @MainActor in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await commit(value)
    }
  }

  func flush(_ value: Value) async {
    task?.cancel()
    task = nil
    await commit(value)
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}

import Foundation

enum WallClockDeadline {
  /// Serialises work, timer and cancellation onto one continuation. A racer that settles before
  /// the continuation is armed parks its result; `arm` then resumes with it immediately.
  /// Settle precedes cancel so a cooperative CancellationError cannot race the intended outcome.
  private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var settled = false
    private var pending: Result<T, Error>?

    func arm(_ continuation: CheckedContinuation<T, Error>) {
      lock.lock()
      if let pending {
        lock.unlock()
        continuation.resume(with: pending)
        return
      }
      self.continuation = continuation
      lock.unlock()
    }

    func settle(_ result: Result<T, Error>) {
      lock.lock()
      guard !settled else { lock.unlock(); return }
      settled = true
      if let continuation {
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
      } else {
        pending = result
        lock.unlock()
      }
    }
  }

  static func run<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let once = Once<T>()
    let work = Task { try await operation() }
    let timer = Task {
      try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
      once.settle(.failure(TranscriptionError.requestTimeout))
      work.cancel()
    }
    Task {
      let result: Result<T, Error>
      do { result = .success(try await work.value) } catch { result = .failure(error) }
      timer.cancel()
      once.settle(result)
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in once.arm(continuation) }
    } onCancel: {
      once.settle(.failure(CancellationError()))
      timer.cancel()
      work.cancel()
    }
  }
}

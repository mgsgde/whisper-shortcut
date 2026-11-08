import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Locks the retry policy the two chunk pipelines share (`ChunkTranscriptionService`,
/// `ChunkTTSService`). It used to exist as two hand-kept copies, and every rule below is one a copy
/// could plausibly have gotten wrong without anything failing loudly: a non-retryable error burning
/// five attempts against an API that will never say yes, a retryable one giving up on the first, or
/// the attempt budget being off by one.
@Suite("Chunk retry policy")
struct ChunkRetryPolicyTests {

  private func policy(maxRetries: Int, retryDelay: TimeInterval = 0.01) -> ChunkRetryPolicy {
    ChunkRetryPolicy(
      maxRetries: maxRetries,
      retryDelay: retryDelay,
      coordinator: RateLimitCoordinator(logPrefix: "TEST-RATE-LIMIT"),
      logPrefix: "TEST")
  }

  /// An actor so the counter is safe to bump from the policy's async work closure.
  private actor Attempts {
    private(set) var count = 0
    func bump() -> Int {
      count += 1
      return count
    }
  }

  @Test("Retries a retryable failure and returns the eventual success")
  func retriesUntilSuccess() async throws {
    let attempts = Attempts()
    let result = try await policy(maxRetries: 5).run(label: "Chunk 1") {
      let n = await attempts.bump()
      if n < 3 { throw TranscriptionError.serviceUnavailable }
      return "recovered on \(n)"
    }
    #expect(result == "recovered on 3")
    #expect(await attempts.count == 3)
  }

  @Test("Gives up after maxRetries attempts and rethrows the last error")
  func exhaustsAttempts() async {
    let attempts = Attempts()
    await #expect(throws: TranscriptionError.serverError(503)) {
      try await policy(maxRetries: 3).run(label: "Chunk 2") { () -> String in
        _ = await attempts.bump()
        throw TranscriptionError.serverError(503)
      }
    }
    // Exactly maxRetries — not maxRetries + 1, and not one short.
    #expect(await attempts.count == 3)
  }

  struct FastFail: Sendable {
    let note: String
    let error: TranscriptionError
  }

  @Test("A non-retryable error or a rate limit with no delay fails on the first attempt", arguments: [
    FastFail(note: "invalid API key", error: .invalidAPIKey),
    // `isRetryable` is false for `.rateLimited(nil)`: a spend cap will not clear on its own, so
    // retrying only burns requests against an already-capped project.
    FastFail(note: "rate limit with no retry delay", error: .rateLimited(retryAfter: nil)),
  ])
  func nonRetryableFailsFast(_ row: FastFail) async {
    let attempts = Attempts()
    await #expect(throws: row.error) {
      try await policy(maxRetries: 5).run(label: row.note) { () -> String in
        _ = await attempts.bump()
        throw row.error
      }
    }
    #expect(await attempts.count == 1, "\(row.note)")
  }

  @Test("beforeRetry fires once per retry, never before the first attempt")
  func beforeRetryFiresPerRetry() async throws {
    let attempts = Attempts()
    let notified = Attempts()
    _ = try await policy(maxRetries: 5).run(
      label: "Chunk 5",
      beforeRetry: { _, _ in _ = await notified.bump() }
    ) {
      let n = await attempts.bump()
      if n < 3 { throw TranscriptionError.networkError("transient") }
      return "ok"
    }
    // Three attempts → two retries → two notifications.
    #expect(await attempts.count == 3)
    #expect(await notified.count == 2)
  }
}

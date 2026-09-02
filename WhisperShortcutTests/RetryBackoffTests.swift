import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins the retry policy the app's four retry loops now share.
///
/// The rule that matters most is the permanent one: a rate/quota error with no `retryAfter` is a
/// spending cap, not a spike. It used to be written three different ways and was missing from the
/// OpenAI Dictate Prompt loop entirely, so a capped key burned a doomed retry on every prompt.
@Suite("Retry backoff")
struct RetryBackoffTests {

  // MARK: - Permanent vs transient

  @Test("A rate limit without a retryAfter is permanent")
  func rateLimitWithoutDelayIsPermanent() {
    #expect(RetryBackoff.isPermanentRateLimit(TranscriptionError.rateLimited(retryAfter: nil)))
    #expect(RetryBackoff.isPermanentRateLimit(TranscriptionError.quotaExceeded(retryAfter: nil)))
  }

  @Test("A rate limit WITH a retryAfter is transient and must still be retried")
  func rateLimitWithDelayIsTransient() {
    #expect(!RetryBackoff.isPermanentRateLimit(TranscriptionError.rateLimited(retryAfter: 3)))
    #expect(!RetryBackoff.isPermanentRateLimit(TranscriptionError.quotaExceeded(retryAfter: 30)))
  }

  @Test("Ordinary failures are not mistaken for a spending cap")
  func otherErrorsAreNotPermanentRateLimits() {
    #expect(!RetryBackoff.isPermanentRateLimit(TranscriptionError.invalidAPIKey))
    #expect(!RetryBackoff.isPermanentRateLimit(TranscriptionError.serverError(503)))
    #expect(!RetryBackoff.isPermanentRateLimit(TranscriptionError.networkError("offline")))
    struct Other: Error {}
    #expect(!RetryBackoff.isPermanentRateLimit(Other()))
  }

  /// OpenAI reports "no credit on the account" as a 429 with `insufficient_quota`. The raw-HTTP
  /// loop has no `TranscriptionError` to inspect yet, so it matches on the body.
  @Test("An insufficient_quota body is a billing block, not a rate-limit spike")
  func insufficientQuotaBodyIsPermanent() {
    let body = #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}"#
    #expect(RetryBackoff.isPermanentRateLimit(responseBody: body))
    #expect(!RetryBackoff.isPermanentRateLimit(responseBody: #"{"error":{"code":"rate_limit_exceeded"}}"#))
    #expect(!RetryBackoff.isPermanentRateLimit(responseBody: ""))
  }

  // MARK: - Delay

  @Test("An API-supplied retryAfter always wins, with its buffer")
  func retryAfterWins() {
    // Guessing shorter than the server's own answer just earns another 429.
    #expect(RetryBackoff.delay(attempt: 1, retryAfter: 7, base: 1, exponential: true) == 7)
    #expect(RetryBackoff.delay(attempt: 4, retryAfter: 7, base: 99, exponential: true) == 7)
    #expect(RetryBackoff.delay(attempt: 1, retryAfter: 7, base: 1, exponential: true, buffer: 2) == 9)
  }

  @Test("Without a retryAfter, exponential backoff doubles per attempt")
  func exponentialBackoff() {
    #expect(RetryBackoff.delay(attempt: 1, retryAfter: nil, base: 2, exponential: true) == 2)
    #expect(RetryBackoff.delay(attempt: 2, retryAfter: nil, base: 2, exponential: true) == 4)
    #expect(RetryBackoff.delay(attempt: 3, retryAfter: nil, base: 2, exponential: true) == 8)
  }

  @Test("Non-exponential callers get their fixed delay unchanged")
  func fixedBackoff() {
    #expect(RetryBackoff.delay(attempt: 1, retryAfter: nil, base: 1.5, exponential: false) == 1.5)
    #expect(RetryBackoff.delay(attempt: 5, retryAfter: nil, base: 1.5, exponential: false) == 1.5)
  }

  /// A loop that starts counting at 0 rather than 1 must not be punished with a fractional first
  /// delay — the clamp keeps the first wait equal to `base` either way.
  @Test("Attempt numbering below 1 still yields the base delay")
  func attemptClamping() {
    #expect(RetryBackoff.delay(attempt: 0, retryAfter: nil, base: 2, exponential: true) == 2)
    #expect(RetryBackoff.delay(attempt: -3, retryAfter: nil, base: 2, exponential: true) == 2)
  }

  @Test("A Wi-Fi blip before the first token is retryable; a cancel or bad key is not")
  func transientPreFirstToken() {
    #expect(RetryBackoff.isTransientPreFirstToken(URLError(.notConnectedToInternet)))
    #expect(RetryBackoff.isTransientPreFirstToken(URLError(.networkConnectionLost)))
    #expect(RetryBackoff.isTransientPreFirstToken(TranscriptionError.serverError(503)))
    #expect(RetryBackoff.isTransientPreFirstToken(TranscriptionError.networkError("connection lost")))
    #expect(!RetryBackoff.isTransientPreFirstToken(URLError(.cancelled)))
    #expect(!RetryBackoff.isTransientPreFirstToken(CancellationError()))
    #expect(!RetryBackoff.isTransientPreFirstToken(TranscriptionError.invalidAPIKey))
    #expect(!RetryBackoff.isTransientPreFirstToken(
      TranscriptionError.networkError("API key is invalid. Check Settings.")))
  }
}

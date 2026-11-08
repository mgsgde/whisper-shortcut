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

  @Test("Rate limits without retryAfter are permanent; with retryAfter transient; other errors are neither")
  func permanentRateLimitClassification() {
    #expect(RetryBackoff.isPermanentRateLimit(TranscriptionError.rateLimited(retryAfter: nil)))
    #expect(RetryBackoff.isPermanentRateLimit(TranscriptionError.quotaExceeded(retryAfter: nil)))
    // A retryAfter makes it transient and it must still be retried.
    #expect(!RetryBackoff.isPermanentRateLimit(TranscriptionError.rateLimited(retryAfter: 3)))
    #expect(!RetryBackoff.isPermanentRateLimit(TranscriptionError.quotaExceeded(retryAfter: 30)))
    // Ordinary failures are not mistaken for a spending cap.
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

  @Test("Delay: retryAfter wins (with buffer), exponential doubles, fixed stays, attempts below 1 clamp")
  func delay() {
    // Guessing shorter than the server's own answer just earns another 429.
    #expect(RetryBackoff.delay(attempt: 1, retryAfter: 7, base: 1, exponential: true) == 7)
    #expect(RetryBackoff.delay(attempt: 4, retryAfter: 7, base: 99, exponential: true) == 7)
    #expect(RetryBackoff.delay(attempt: 1, retryAfter: 7, base: 1, exponential: true, buffer: 2) == 9)
    #expect(RetryBackoff.delay(attempt: 1, retryAfter: nil, base: 2, exponential: true) == 2)
    #expect(RetryBackoff.delay(attempt: 2, retryAfter: nil, base: 2, exponential: true) == 4)
    #expect(RetryBackoff.delay(attempt: 3, retryAfter: nil, base: 2, exponential: true) == 8)
    // Non-exponential callers get their fixed delay unchanged.
    #expect(RetryBackoff.delay(attempt: 1, retryAfter: nil, base: 1.5, exponential: false) == 1.5)
    #expect(RetryBackoff.delay(attempt: 5, retryAfter: nil, base: 1.5, exponential: false) == 1.5)
    // A loop counting from 0 must not get a fractional first delay: the clamp keeps it at `base`.
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

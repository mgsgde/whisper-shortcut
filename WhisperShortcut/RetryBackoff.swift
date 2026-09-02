import Foundation

/// The two retry decisions that must be made identically everywhere: *may* this error be retried,
/// and *how long* do we wait first.
///
/// The app has four retry loops and they legitimately differ in control flow — `GeminiAPIClient`'s
/// request loop escalates its own attempt budget and posts rate-limit UI notifications, its stream
/// loop may only retry before the first event is yielded, `ChunkRetryPolicy` pauses sibling chunks
/// through a coordinator, and `SpeechService.performWithRetryOn429` returns a raw HTTP response for
/// the caller to interpret. What they must NOT differ on is the policy, and they did: the
/// "permanent rate limit" rule below existed in three different spellings and was missing entirely
/// from the fourth, so a spend-capped key burned a doomed retry on every Dictate Prompt.
enum RetryBackoff {

  /// A rate/quota error carrying **no** `retryAfter` is a permanent block, not a transient spike —
  /// a monthly spending-cap 429 (`RESOURCE_EXHAUSTED`) will not clear until the user raises the cap.
  /// Retrying only delays the error the user needs to see and burns more requests against an
  /// already-capped project.
  static func isPermanentRateLimit(_ error: Error) -> Bool {
    guard let te = error as? TranscriptionError else { return false }
    switch te {
    case .rateLimited(nil, _), .quotaExceeded(nil):
      return true
    default:
      return false
    }
  }

  /// The same judgement for a raw HTTP 429 whose body has not been mapped to a `TranscriptionError`
  /// yet. OpenAI reports "no credit on the account" as a 429 with `insufficient_quota`, which is a
  /// billing problem and never resolves on its own.
  static func isPermanentRateLimit(responseBody: String) -> Bool {
    responseBody.contains("insufficient_quota")
  }

  /// How long to wait before the next attempt.
  ///
  /// An API-supplied `retryAfter` always wins — it is the server telling us when it will be ready,
  /// and guessing shorter just earns another 429. `buffer` is added on top of it because the
  /// server's own clock and ours are not the same. Without a `retryAfter`, transient server errors
  /// get exponential backoff (they usually clear, but not instantly) and everything else gets a
  /// short fixed delay.
  static func delay(
    attempt: Int,
    retryAfter: TimeInterval?,
    base: TimeInterval,
    exponential: Bool,
    buffer: TimeInterval = 0
  ) -> TimeInterval {
    if let retryAfter { return retryAfter + buffer }
    guard exponential else { return base }
    return base * pow(2.0, Double(max(0, attempt - 1)))
  }

  /// Sleeps for `seconds`. Non-throwing so a cancelled sleep does not turn into a thrown error in
  /// loops that are mid-way through reporting a different failure.
  static func sleep(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
  }

  /// Chat streams may only retry while no token has been yielded. Two extra attempts
  /// cover a Wi-Fi blip or 5xx before the first byte.
  static let preFirstTokenMaxAttempts = 3

  /// Pre-first-token stream failures that are worth retrying (Wi-Fi blip, 5xx, transient
  /// rate limits). Auth, cancel, and permanent spending-cap 429s are not.
  static func isTransientPreFirstToken(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    if isPermanentRateLimit(error) { return false }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .cancelled:
        return false
      case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
           .notConnectedToInternet, .dnsLookupFailed:
        return true
      default:
        return false
      }
    }
    guard let te = error as? TranscriptionError else { return false }
    if te.isServerOrUnavailable { return true }
    switch te {
    case .slowDown, .rateLimited, .quotaExceeded, .requestTimeout, .resourceTimeout:
      return true
    case .networkError(let msg):
      let lower = msg.lowercased()
      return lower.contains("503") || lower.contains("502") || lower.contains("504")
        || lower.contains("500") || lower.contains("unavailable")
        || lower.contains("timed out") || lower.contains("timeout")
        || lower.contains("connection") || lower.contains("offline")
        || lower.contains("lost")
    default:
      return false
    }
  }

  /// Retries `operation` on transient pre-stream failures only. Callers must not invoke this
  /// after the first token has been yielded.
  static func withPreFirstTokenRetry<T>(
    logTag: String,
    operation: () async throws -> T
  ) async throws -> T {
    var attempt = 0
    while true {
      attempt += 1
      do {
        return try await operation()
      } catch {
        if Task.isCancelled { throw error }
        guard isTransientPreFirstToken(error), attempt < preFirstTokenMaxAttempts else {
          throw error
        }
        let te = error as? TranscriptionError
        let delaySeconds = delay(
          attempt: attempt,
          retryAfter: te?.retryAfter,
          base: (te?.isServerOrUnavailable ?? false) ? 2.0 : 1.0,
          exponential: te?.isServerOrUnavailable ?? false)
        DebugLogger.log(
          "\(logTag)-RETRY: Attempt \(attempt) failed, retrying in \(String(format: "%.1f", delaySeconds))s: \(error.localizedDescription)")
        await sleep(delaySeconds)
      }
    }
  }
}

import Foundation

/// The two retry decisions that must be made identically everywhere: *may* this error be retried,
/// and *how long* do we wait first.
///
/// The app has five retry loops and they legitimately differ in control flow — `GeminiAPIClient`'s
/// request loop escalates its own attempt budget and posts rate-limit UI notifications, its stream
/// loop may only retry before the first event is yielded, `ChunkRetryPolicy` pauses sibling chunks
/// through a coordinator, and `SpeechService.performWithRetryOn429` returns a raw HTTP response for
/// the caller to interpret; `MeetingListService.withRetry` wraps the meeting notes/summary LLM
/// calls in a plain loop. Streaming and non-streaming TTS share the 429 loop (one 429 branch); the
/// other loops still differ in control flow from it and from each other. What they must
/// NOT differ on is the policy, and they did: the
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

  /// Seconds to wait before retrying, taken from a rate-limit response.
  ///
  /// `Retry-After` wins (delta-seconds or an HTTP-date). Otherwise `retry-after-ms`, otherwise
  /// the reset of the exhausted `anthropic-ratelimit-*` bucket. Nothing parseable returns nil, and a
  /// nil delay stays a permanent block (`isPermanentRateLimit`). The value is the server's own
  /// number — the chat loop refuses delays past `maxAutomaticRetryWait` and floors short ones.
  static func retryAfter(from response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
    if let header = response.value(forHTTPHeaderField: "Retry-After")?
      .trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty {
      if let seconds = nonNegativeSeconds(header) { return seconds }
      if let date = httpDate(from: header) {
        return max(0, date.timeIntervalSince(now))
      }
    }
    if let header = response.value(forHTTPHeaderField: "retry-after-ms"),
       let milliseconds = nonNegativeSeconds(header) {
      return milliseconds / 1000
    }
    return anthropicReset(in: response, now: now)
  }

  private static func nonNegativeSeconds(_ raw: String) -> TimeInterval? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = TimeInterval(trimmed), value >= 0, value.isFinite else { return nil }
    return value
  }

  /// IMF-fixdate, the only HTTP-date form current APIs send (`Sun, 06 Nov 1994 08:49:37 GMT`).
  private static func httpDate(from raw: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: raw)
  }

  /// When the bucket that blocked us reopens. `Retry-After` is authoritative when the server sent
  /// one; these timestamps are the fallback. Anthropic meters requests and (input/output) tokens
  /// separately and reports each bucket's `-remaining` and `-reset`. The 429 comes from the bucket
  /// at `remaining: 0`, which is often the token bucket resetting much later than the request
  /// bucket, so waiting only for the soonest reset retries into a guaranteed second 429. Take the
  /// latest reset among exhausted buckets; if no bucket reports `remaining`, the latest of all.
  private static func anthropicReset(in response: HTTPURLResponse, now: Date) -> TimeInterval? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let isoFractional = ISO8601DateFormatter()
    isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let prefix = "anthropic-ratelimit-"
    let resetSuffix = "-reset"
    let remainingSuffix = "-remaining"
    var resets: [String: TimeInterval] = [:]
    var exhausted: Set<String> = []
    for (key, value) in response.allHeaderFields {
      guard let name = (key as? String)?.lowercased(), name.hasPrefix(prefix),
            let raw = value as? String else { continue }
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if name.hasSuffix(resetSuffix) {
        let bucket = String(name.dropFirst(prefix.count).dropLast(resetSuffix.count))
        guard let date = iso.date(from: trimmed) ?? isoFractional.date(from: trimmed) else { continue }
        resets[bucket] = max(0, date.timeIntervalSince(now))
      } else if name.hasSuffix(remainingSuffix) {
        let bucket = String(name.dropFirst(prefix.count).dropLast(remainingSuffix.count))
        if let remaining = Double(trimmed), remaining <= 0 { exhausted.insert(bucket) }
      }
    }
    let blocking = resets.filter { exhausted.contains($0.key) }
    return (blocking.isEmpty ? resets : blocking).values.max()
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

  /// Longest a chat stream will automatically sit on a rate limit before the first token.
  /// The user is watching an empty reply, and with `preFirstTokenMaxAttempts` the waits add up
  /// (two retries at 45s is ~90s of silence), so this is deliberately well below the 120s
  /// `RateLimitCoordinator` uses for background work. A longer server delay is a quota window:
  /// failing fast with the error beats blocking the reply (the full delay stays on the error
  /// for the message).
  static let maxAutomaticRetryWait: TimeInterval = 45

  /// Floor for a pre-first-token retry sleep. A server that says `Retry-After: 0` (or an
  /// already-past HTTP-date) would otherwise get an immediate hot retry.
  static let minAutomaticRetryWait: TimeInterval = 1

  /// Pre-first-token stream failures that are worth retrying (Wi-Fi blip, 5xx, transient
  /// rate limits). Auth, cancel, permanent spending-cap 429s, and a delay past
  /// `maxAutomaticRetryWait` are not.
  static func isTransientPreFirstToken(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    if isPermanentRateLimit(error) { return false }
    if let wait = (error as? TranscriptionError)?.retryAfter, wait > maxAutomaticRetryWait {
      return false
    }
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

  /// Sleep before pre-first-token retry number `attempt`. `isTransientPreFirstToken` already
  /// rejects a server delay past `maxAutomaticRetryWait`, so only the floor is applied here.
  static func preFirstTokenDelay(attempt: Int, error: Error) -> TimeInterval {
    let te = error as? TranscriptionError
    let serverOrUnavailable = te?.isServerOrUnavailable ?? false
    return max(
      minAutomaticRetryWait,
      delay(
        attempt: attempt,
        retryAfter: te?.retryAfter,
        base: serverOrUnavailable ? 2.0 : 1.0,
        exponential: serverOrUnavailable))
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
        let delaySeconds = preFirstTokenDelay(attempt: attempt, error: error)
        DebugLogger.log(
          "\(logTag)-RETRY: Attempt \(attempt) failed, retrying in \(String(format: "%.1f", delaySeconds))s: \(error.logDescription)")
        await sleep(delaySeconds)
      }
    }
  }
}

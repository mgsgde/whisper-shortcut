import Foundation

/// Wall-clock deadline around a single `URLSession` round-trip.
///
/// `URLSession`'s own timers are not a reliable stall detector on this path:
/// `timeoutIntervalForRequest` does not start until the first response byte, and
/// `timeoutIntervalForResource` is not consistently enforced on reused HTTP/2
/// connections (OpenAI's API). Measured GPT-Transcribe hangs sat in `transcribing`
/// for 3.5–12.8 minutes until the user cancelled (improvement-ledger I2). A Task
/// deadline cancels the request regardless of those timers.
enum NetworkDeadline {

  /// Cap for one OpenAI-compatible transcription POST. 60s is well under the I2
  /// falsifier (`gapMs > 120000`) and far above typical GPT-Transcribe latency
  /// (1–5s for a dictation). Matches Gemini's request-timeout copy so the user
  /// sees the same "over 60 seconds" message on either provider.
  static let transcriptionRequestTimeout: TimeInterval = 60

  private enum Race {
    case completed(Data, URLResponse)
    case timedOut
  }

  /// Returns `session.data(for:)` or throws `TranscriptionError.requestTimeout`
  /// if `timeout` elapses first. A URLSession-native `.timedOut` is mapped to
  /// the same error; a user cancel stays a `CancellationError`.
  static func data(
    for request: URLRequest,
    session: URLSession,
    timeout: TimeInterval
  ) async throws -> (Data, URLResponse) {
    try await withThrowingTaskGroup(of: Race.self) { group in
      group.addTask {
        do {
          let (data, response) = try await session.data(for: request)
          return .completed(data, response)
        } catch let error as URLError where error.code == .timedOut {
          throw TranscriptionError.requestTimeout
        } catch let error as URLError where error.code == .cancelled {
          throw CancellationError()
        }
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
        return .timedOut
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else {
        throw TranscriptionError.requestTimeout
      }
      switch first {
      case .completed(let data, let response):
        return (data, response)
      case .timedOut:
        throw TranscriptionError.requestTimeout
      }
    }
  }
}

//
//  ChunkPipelineSupport.swift
//  WhisperShortcut
//
//  The parts `ChunkTranscriptionService` and `ChunkTTSService` genuinely share: how a single chunk
//  is retried, and how results are accumulated across a task group.
//

import Foundation

/// The retry policy both chunk pipelines run each unit of work under.
///
/// Transcription and TTS carried this loop as two line-for-line copies, including the parts that are
/// easy to get subtly wrong: that a rate-limit error carrying a `retryAfter` skips the local sleep
/// and relies on the coordinator's global pause instead, that a non-retryable error must fail on the
/// first attempt rather than burn the remaining ones, and that the delay prefers the API's number
/// over the exponential fallback. One implementation means one place where that has to be right.
///
/// What stays with the caller is what actually differs: the work itself, and how a retry is reported
/// to the progress delegate (transcription re-announces the chunk as started, TTS does not).
struct ChunkRetryPolicy {
  /// Maximum attempts per chunk, including the first.
  let maxRetries: Int
  /// Base delay for the exponential fallback, used when the API supplies no `retryAfter`.
  let retryDelay: TimeInterval
  /// Global pause shared by every chunk of this pipeline: one 429 parks them all.
  let coordinator: RateLimitCoordinator
  /// Log prefix of the owning service, e.g. `CHUNK-SERVICE`.
  let logPrefix: String

  /// Runs `work` until it succeeds or the attempts run out.
  ///
  /// - Parameters:
  ///   - label: how the unit is named in logs, e.g. `"Chunk 3"`.
  ///   - beforeRetry: called before attempts 2…n with the error that caused the retry (nil only in
  ///     the unreachable case of no recorded error) and the attempt number. Each service reports a
  ///     retry to its own delegate here.
  ///   - work: one attempt.
  func run<Output>(
    label: String,
    beforeRetry: (Error?, Int) async -> Void = { _, _ in },
    work: () async throws -> Output
  ) async throws -> Output {
    var lastError: Error?

    for attempt in 1...maxRetries {
      do {
        // Wait if we're in a rate-limited period (global coordination)
        await coordinator.waitIfNeeded()

        // Check for cancellation after waiting
        try Task.checkCancellation()

        if attempt > 1 {
          DebugLogger.log("\(logPrefix): \(label) attempt \(attempt)/\(maxRetries)")
          await beforeRetry(lastError, attempt)
        }

        let output = try await work()

        // Report success to coordinator (resets rate limit counter)
        await coordinator.reportSuccess()
        return output

      } catch {
        lastError = error

        // Check if this is a rate limit or quota error with retry info
        if let transcriptionError = error as? TranscriptionError {
          switch transcriptionError {
          case .rateLimited(let retryAfter, _), .quotaExceeded(let retryAfter):
            // Only pause other chunks when the error is retryable (transient rate limit).
            if transcriptionError.isRetryable {
              await coordinator.reportRateLimit(retryAfter: retryAfter)
            }

            // If we have a retry delay, this error is retryable
            if retryAfter != nil && attempt < maxRetries {
              DebugLogger.log("\(logPrefix): \(label) hit rate limit, will retry after coordinator wait")
              continue
            }

          default:
            break
          }

          // Non-retryable errors should fail immediately
          if !transcriptionError.isRetryable {
            throw error
          }
        }

        // Don't retry on last attempt
        if attempt < maxRetries {
          // Use API-provided delay if available, otherwise exponential backoff
          let delay: TimeInterval
          if let transcriptionError = error as? TranscriptionError,
             let retryAfter = transcriptionError.retryAfter {
            delay = retryAfter
          } else {
            delay = retryDelay * pow(2.0, Double(attempt - 1))
          }
          DebugLogger.log("\(logPrefix): \(label) failed, retrying in \(String(format: "%.1f", delay))s")
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
      }
    }

    throw lastError ?? TranscriptionError.networkError("\(label) failed")
  }
}

/// Thread-safe accumulation of chunk results across a task group: the successes, the per-chunk
/// errors, and how many chunks have reported in. Was a private actor with these five methods in each
/// chunk service, identical but for the payload type.
actor ChunkResultAccumulator<Value> {
  private var values: [Value] = []
  private var errors: [(index: Int, error: Error)] = []
  private var completedCount = 0

  func incrementCompleted() -> Int {
    completedCount += 1
    return completedCount
  }

  func add(_ value: Value) {
    values.append(value)
  }

  func addError(index: Int, error: Error) {
    errors.append((index: index, error: error))
  }

  func allValues() -> [Value] {
    return values
  }

  func allErrors() -> [(index: Int, error: Error)] {
    return errors
  }
}

//
//  ChunkTTSService.swift
//  WhisperShortcut
//
//  Parallel chunk TTS synthesis with retry and result aggregation.
//

import Foundation

/// Errors specific to chunked TTS.
enum ChunkedTTSError: Error, LocalizedError {
    case chunkingFailed(Error)
    case allChunksFailed(errors: [(index: Int, error: Error)])

    var errorDescription: String? {
        switch self {
        case .chunkingFailed(let error):
            return ChunkFailureMessage.message(context: "text", error: error)
        case .allChunksFailed(let errors):
            return "All \(errors.count) chunks failed to synthesize"
        }
    }
}

/// Service for synthesizing long texts by splitting into chunks
/// and processing them in parallel with retry logic.
///
/// Provider-agnostic: the caller injects a `synthesizeText` closure that turns one text
/// segment into raw PCM (s16le, 24 kHz, mono). Retry, global rate-limit coordination, and
/// audio merging are handled here, so Gemini / OpenAI / xAI all share this path.
class ChunkTTSService {
    // MARK: - Properties

    /// Delegate for receiving progress updates.
    weak var progressDelegate: ChunkProgressDelegate?

    /// Maximum retry attempts per chunk.
    let maxRetries: Int

    /// Base retry delay (exponential backoff applied).
    let retryDelay: TimeInterval

    /// Text chunker for splitting text.
    private let chunker: TextChunker

    /// Coordinator for global rate limiting across all chunks.
    private let rateLimitCoordinator = RateLimitCoordinator(logPrefix: "TTS-RATE-LIMIT")

    // MARK: - Initialization

    init(
        maxRetries: Int = 5,  // Increased from 3 to handle rate limiting with proper delays
        retryDelay: TimeInterval = 1.5
    ) {
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.chunker = TextChunker()
    }

    // MARK: - Public API

    /// Synthesize text to speech using chunking if needed.
    /// - Parameters:
    ///   - text: The text to synthesize
    ///   - model: TTS model to use (for logging only; the request is built by `synthesizeText`)
    ///   - synthesizeText: Provider-specific closure that synthesizes one text segment to raw
    ///     PCM. It should throw `TranscriptionError` (e.g. `.rateLimited`) so retry/backoff works.
    /// - Returns: Synthesized audio data (merged PCM)
    func synthesize(
        text: String,
        model: TTSModel,
        synthesizeText: @escaping (String) async throws -> Data
    ) async throws -> Data {
        let startTime = CFAbsoluteTimeGetCurrent()

        DebugLogger.log("TTS-CHUNK-SERVICE: Starting synthesis (text length: \(text.count) chars, model: \(model.displayName))")

        // Split text into chunks
        let chunks: [TextChunk]
        do {
            chunks = try chunker.splitText(text)
        } catch {
            DebugLogger.logError("TTS-CHUNK-SERVICE: Failed to split text: \(error.localizedDescription)")
            throw ChunkedTTSError.chunkingFailed(error)
        }

        DebugLogger.log("TTS-CHUNK-SERVICE: Split into \(chunks.count) chunks (max retries: \(maxRetries))")

        // Notify delegate about chunking start
        await MainActor.run {
            if let delegate = progressDelegate {
                DebugLogger.log("TTS-CHUNK-SERVICE: Notifying delegate about chunking start (\(chunks.count) chunks)")
                delegate.chunkingStarted(totalChunks: chunks.count)
            } else {
                DebugLogger.logWarning("TTS-CHUNK-SERVICE: No progress delegate set - UI progress won't be shown")
            }
        }

        // If only one chunk, process directly
        if chunks.count == 1 {
            DebugLogger.log("TTS-CHUNK-SERVICE: Single chunk, processing directly")
            let result = try await processChunk(
                chunk: chunks[0],
                totalChunks: 1,
                synthesizeText: synthesizeText
            )
            let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
            DebugLogger.logSuccess("TTS-CHUNK-SERVICE: Single chunk synthesis completed in \(String(format: "%.2f", elapsedTime))s (\(result.data.count) bytes)")
            return result.data
        }

        // Synthesize chunks in parallel
        DebugLogger.log("TTS-CHUNK-SERVICE: Starting parallel synthesis of \(chunks.count) chunks")
        let audioChunks = try await synthesizeParallel(
            chunks: chunks,
            synthesizeText: synthesizeText
        )

        // Don't flip the menu bar into `.merging` if Stop already fired: the cancel handler
        // moved app state to `.idle`, and a late `mergingStarted` on the main actor would
        // re-enter a busy state on top of that, leaving the UI stuck.
        try Task.checkCancellation()
        await MainActor.run {
            progressDelegate?.mergingStarted()
        }

        // Merge audio chunks
        DebugLogger.log("TTS-CHUNK-SERVICE: Merging \(audioChunks.count) audio chunks")
        let mergedAudio = try AudioMerger.merge(audioChunks)

        let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
        DebugLogger.logSuccess("TTS-CHUNK-SERVICE: Total synthesis completed in \(String(format: "%.2f", elapsedTime))s (merged audio: \(mergedAudio.count) bytes)")

        return mergedAudio
    }

    // MARK: - Parallel Processing

    private func synthesizeParallel(
        chunks: [TextChunk],
        synthesizeText: @escaping (String) async throws -> Data
    ) async throws -> [AudioChunkData] {
        let totalChunks = chunks.count

        DebugLogger.log("TTS-CHUNK-SERVICE: Starting parallel synthesis (total chunks: \(totalChunks))")

        // Use actor for thread-safe accumulation
        let accumulator = ResultAccumulator()

        try await withThrowingTaskGroup(of: Result<AudioChunkData, Error>.self) { group in
            for chunk in chunks {
                group.addTask { [self] in
                    DebugLogger.log("TTS-CHUNK-SERVICE: Chunk \(chunk.index + 1)/\(totalChunks) started processing (\(chunk.text.count) chars)")

                    // Notify delegate that chunk started
                    await MainActor.run {
                        progressDelegate?.chunkStarted(index: chunk.index)
                    }

                    do {
                        let audioData = try await self.processChunk(
                            chunk: chunk,
                            totalChunks: totalChunks,
                            synthesizeText: synthesizeText
                        )
                        return .success(audioData)
                    } catch {
                        return .failure(ChunkError(index: chunk.index, error: error))
                    }
                }
            }

            // Collect results
            for try await result in group {
                let completed = await accumulator.incrementCompleted()
                DebugLogger.logDebug("TTS-CHUNK-SERVICE: Progress: \(completed)/\(totalChunks) chunks completed")

                switch result {
                case .success(let audioChunk):
                    await accumulator.addAudioChunk(audioChunk)

                    DebugLogger.logSuccess("TTS-CHUNK-SERVICE: Chunk \(audioChunk.index + 1)/\(totalChunks) completed successfully (\(audioChunk.data.count) bytes)")

                    // Notify delegate that chunk completed
                    await MainActor.run {
                        progressDelegate?.chunkCompleted(index: audioChunk.index, text: "Audio synthesized (\(audioChunk.data.count) bytes)")
                        progressDelegate?.chunkProgressUpdated(completed: completed, total: totalChunks)
                    }

                case .failure(let error):
                    if let chunkError = error as? ChunkError {
                        await accumulator.addError(index: chunkError.index, error: chunkError.error)

                        DebugLogger.logError("TTS-CHUNK-SERVICE: Chunk \(chunkError.index + 1)/\(totalChunks) failed: \(chunkError.error.localizedDescription)")

                        // Notify delegate that chunk failed (no retry at this level - retries happen in processChunk)
                        await MainActor.run {
                            progressDelegate?.chunkFailed(index: chunkError.index, error: chunkError.error, willRetry: false)
                            progressDelegate?.chunkProgressUpdated(completed: completed, total: totalChunks)
                        }
                    }
                }
            }
        }

        // Get final results
        let audioChunks = await accumulator.getAudioChunks()
        let errors = await accumulator.getErrors()

        DebugLogger.log("TTS-CHUNK-SERVICE: Parallel synthesis complete - \(audioChunks.count) succeeded, \(errors.count) failed")

        // Handle results
        if audioChunks.isEmpty {
            // Check if all errors are cancellation errors - if so, propagate as CancellationError
            let allCancelled = errors.allSatisfy { $0.error is CancellationError }
            if allCancelled {
                DebugLogger.log("TTS-CHUNK-SERVICE: All chunks were cancelled - propagating cancellation")
                throw CancellationError()
            }
            DebugLogger.logError("TTS-CHUNK-SERVICE: All chunks failed - throwing error")
            throw ChunkedTTSError.allChunksFailed(errors: errors)
        }

        if !errors.isEmpty {
            // Partial success - log warning but return what we have
            let failedIndices = errors.map { $0.index }
            DebugLogger.logWarning("TTS-CHUNK-SERVICE: Partial success - \(failedIndices.count) chunks failed: \(failedIndices), returning \(audioChunks.count) successful chunks")
            // The caller can decide how to handle partial results
        }

        let sortedChunks = audioChunks.sorted { $0.index < $1.index }
        DebugLogger.log("TTS-CHUNK-SERVICE: Returning \(sortedChunks.count) chunks in order: \(sortedChunks.map { $0.index })")
        return sortedChunks
    }

    // MARK: - Single Chunk Processing

    private func processChunk(
        chunk: TextChunk,
        totalChunks: Int,
        synthesizeText: @escaping (String) async throws -> Data
    ) async throws -> AudioChunkData {
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                // Wait if we're in a rate-limited period (global coordination)
                await rateLimitCoordinator.waitIfNeeded()

                // Check for cancellation after waiting
                try Task.checkCancellation()

                // Report retry status
                if attempt > 1 {
                    DebugLogger.log("TTS-CHUNK-SERVICE: Chunk \(chunk.index) attempt \(attempt)/\(maxRetries)")
                    // Notify delegate about retry
                    let errorToReport = lastError ?? TranscriptionError.networkError("Retrying")
                    await MainActor.run {
                        progressDelegate?.chunkFailed(index: chunk.index, error: errorToReport, willRetry: true)
                    }
                }

                DebugLogger.logDebug("TTS-CHUNK-SERVICE: Making API request for chunk \(chunk.index) (text length: \(chunk.text.count) chars)")

                // Provider-specific synthesis (returns raw PCM s16le 24kHz mono — no WAV header).
                let audioData = try await synthesizeText(chunk.text)

                await rateLimitCoordinator.reportSuccess()
                DebugLogger.logSuccess("TTS-CHUNK-SERVICE: Chunk \(chunk.index) synthesized successfully (\(audioData.count) bytes, \(String(format: "%.2f", Double(audioData.count) / 24000.0 / 2.0))s estimated duration)")

                return AudioChunkData(
                    data: audioData,
                    index: chunk.index
                )

            } catch {
                lastError = error

                // Check if this is a rate limit or quota error with retry info
                if let transcriptionError = error as? TranscriptionError {
                    switch transcriptionError {
                    case .rateLimited(let retryAfter, _), .quotaExceeded(let retryAfter):
                        // Only pause other chunks when the error is retryable (transient rate limit).
                        if transcriptionError.isRetryable {
                            await rateLimitCoordinator.reportRateLimit(retryAfter: retryAfter)
                        }

                        // If we have a retry delay, this error is retryable
                        if retryAfter != nil && attempt < maxRetries {
                            DebugLogger.log("TTS-CHUNK-SERVICE: Chunk \(chunk.index) hit rate limit, will retry after coordinator wait")
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
                    DebugLogger.log("TTS-CHUNK-SERVICE: Chunk \(chunk.index) failed, retrying in \(String(format: "%.1f", delay))s")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        throw lastError ?? TranscriptionError.networkError("Chunk synthesis failed")
    }
}

// MARK: - Helper Types

/// Actor for thread-safe accumulation of TTS results.
private actor ResultAccumulator {
    private var audioChunks: [AudioChunkData] = []
    private var errors: [(index: Int, error: Error)] = []
    private var completedCount = 0

    func incrementCompleted() -> Int {
        completedCount += 1
        return completedCount
    }

    func addAudioChunk(_ audioChunk: AudioChunkData) {
        audioChunks.append(audioChunk)
    }

    func addError(index: Int, error: Error) {
        errors.append((index: index, error: error))
    }

    func getAudioChunks() -> [AudioChunkData] {
        return audioChunks
    }

    func getErrors() -> [(index: Int, error: Error)] {
        return errors
    }
}

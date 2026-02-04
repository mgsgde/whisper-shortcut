//
//  ChunkTranscriptionService.swift
//  WhisperShortcut
//
//  Parallel chunk transcription with retry and result aggregation.
//

import AVFoundation
import Foundation

/// Errors specific to chunked transcription.
enum ChunkedTranscriptionError: Error, LocalizedError {
    case chunkingFailed(Error)
    case allChunksFailed(errors: [(index: Int, error: Error)])
    case partialSuccess(text: String, failedChunks: [Int])

    var errorDescription: String? {
        switch self {
        case .chunkingFailed(let error):
            return "Failed to chunk audio: \(error.localizedDescription)"
        case .allChunksFailed(let errors):
            return "All \(errors.count) chunks failed to transcribe"
        case .partialSuccess(_, let failedChunks):
            return "Partial transcription: \(failedChunks.count) chunk(s) failed"
        }
    }
}

/// Actor to coordinate rate limiting across all chunk tasks.
/// When one chunk hits a 429, all chunks pause together.
actor RateLimitCoordinator {
    /// Time until which all requests should wait
    private var pauseUntil: Date = .distantPast

    /// Number of consecutive rate limit errors (for adaptive backoff)
    private var consecutiveRateLimits: Int = 0

    /// Whether we've already shown a notification for the current wait period
    private var notificationShown: Bool = false

    /// Wait if we're currently in a rate-limited period
    func waitIfNeeded() async {
        let now = Date()
        if pauseUntil > now {
            let waitTime = pauseUntil.timeIntervalSince(now)
            DebugLogger.log("RATE-LIMIT-COORDINATOR: Waiting \(String(format: "%.1f", waitTime))s before next request")

            // Show notification if not already shown for this wait period
            if !notificationShown {
                notificationShown = true
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .rateLimitWaiting,
                        object: nil,
                        userInfo: ["waitTime": waitTime]
                    )
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))

            // Dismiss notification after wait (only once)
            if notificationShown {
                notificationShown = false
                await MainActor.run {
                    NotificationCenter.default.post(name: .rateLimitResolved, object: nil)
                }
            }
        }
    }

    /// Report a rate limit error with optional retry delay from API
    func reportRateLimit(retryAfter: TimeInterval?) {
        consecutiveRateLimits += 1

        // Use API-provided delay, or calculate exponential backoff
        let delay: TimeInterval
        if let retryAfter = retryAfter {
            // Add small buffer to API-provided delay
            delay = retryAfter + 2.0
            DebugLogger.log("RATE-LIMIT-COORDINATOR: API requested \(retryAfter)s delay, using \(delay)s")
        } else {
            // Exponential backoff: 30s, 60s, 120s, capped at 120s
            delay = min(30.0 * pow(2.0, Double(consecutiveRateLimits - 1)), 120.0)
            DebugLogger.log("RATE-LIMIT-COORDINATOR: No API delay, using exponential backoff: \(delay)s")
        }

        let newPauseUntil = Date().addingTimeInterval(delay)
        if newPauseUntil > pauseUntil {
            pauseUntil = newPauseUntil
            notificationShown = false  // Reset so next waitIfNeeded shows notification
            DebugLogger.log("RATE-LIMIT-COORDINATOR: All chunks paused until \(pauseUntil)")
        }
    }

    /// Report a successful request (resets consecutive counter)
    func reportSuccess() {
        if consecutiveRateLimits > 0 {
            DebugLogger.log("RATE-LIMIT-COORDINATOR: Request succeeded, resetting rate limit counter")
            consecutiveRateLimits = 0
        }
    }

    /// Get current pause status for logging
    func isPaused() -> Bool {
        return pauseUntil > Date()
    }
}

/// Service for transcribing long audio files by splitting into chunks
/// and processing them in parallel with retry logic.
class ChunkTranscriptionService {
    // MARK: - Properties

    /// Delegate for receiving progress updates.
    weak var progressDelegate: ChunkProgressDelegate?

    /// Maximum concurrent API calls.
    let maxConcurrency: Int

    /// Maximum retry attempts per chunk.
    let maxRetries: Int

    /// Base retry delay (exponential backoff applied).
    let retryDelay: TimeInterval

    /// Audio chunker for splitting files.
    private let chunker: AudioChunker

    /// Gemini API client for making requests.
    private let geminiClient: GeminiAPIClient

    /// Coordinator for global rate limiting across all chunks.
    private let rateLimitCoordinator = RateLimitCoordinator()

    // MARK: - Initialization

    init(
        maxConcurrency: Int = AppConstants.maxConcurrentChunks,
        maxRetries: Int = 5,  // Increased from 3 to handle rate limiting with proper delays
        retryDelay: TimeInterval = 1.5,
        geminiClient: GeminiAPIClient? = nil
    ) {
        self.maxConcurrency = maxConcurrency
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.chunker = AudioChunker()
        self.geminiClient = geminiClient ?? GeminiAPIClient()
    }

    deinit {
        chunker.cleanup()
    }

    // MARK: - Public API

    /// Transcribe an audio file using chunking if needed.
    /// - Parameters:
    ///   - fileURL: URL of the audio file
    ///   - apiKey: Gemini API key
    ///   - model: Transcription model to use
    ///   - prompt: Custom transcription prompt
    /// - Returns: Transcribed text
    func transcribe(
        fileURL: URL,
        apiKey: String,
        model: TranscriptionModel,
        prompt: String
    ) async throws -> String {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Split audio into chunks
        let chunks: [AudioChunk]
        do {
            chunks = try await chunker.splitAudio(fileURL: fileURL)
        } catch {
            throw ChunkedTranscriptionError.chunkingFailed(error)
        }

        DebugLogger.log("CHUNK-SERVICE: Split into \(chunks.count) chunks")

        // Notify delegate
        await MainActor.run {
            progressDelegate?.chunkingStarted(totalChunks: chunks.count)
        }

        // If only one chunk, process directly
        if chunks.count == 1 {
            let result = try await transcribeChunk(
                chunk: chunks[0],
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                totalChunks: 1
            )
            return result.text
        }

        // Transcribe chunks in parallel
        let transcripts = try await transcribeParallel(
            chunks: chunks,
            apiKey: apiKey,
            model: model,
            prompt: prompt
        )

        // Notify delegate about merging
        await MainActor.run {
            progressDelegate?.mergingStarted()
        }

        // Merge transcripts
        let result = TranscriptMerger.merge(transcripts)

        let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
        DebugLogger.log("CHUNK-SERVICE: Total transcription time: \(String(format: "%.2f", elapsedTime))s")

        // Cleanup chunk files
        chunker.cleanup(chunks: chunks)

        return result
    }

    // MARK: - Parallel Processing

    private func transcribeParallel(
        chunks: [AudioChunk],
        apiKey: String,
        model: TranscriptionModel,
        prompt: String
    ) async throws -> [ChunkTranscript] {
        let semaphore = AsyncSemaphore(value: maxConcurrency)
        let totalChunks = chunks.count

        // Use actor for thread-safe accumulation
        let accumulator = ResultAccumulator()

        try await withThrowingTaskGroup(of: Result<ChunkTranscript, Error>.self) { group in
            for chunk in chunks {
                group.addTask { [self] in
                    // Wait for semaphore
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }

                    // Notify delegate that chunk is now actively processing
                    await MainActor.run {
                        self.progressDelegate?.chunkStarted(index: chunk.index)
                    }

                    do {
                        let transcript = try await self.transcribeChunk(
                            chunk: chunk,
                            apiKey: apiKey,
                            model: model,
                            prompt: prompt,
                            totalChunks: totalChunks
                        )
                        return .success(transcript)
                    } catch {
                        return .failure(ChunkError(index: chunk.index, error: error))
                    }
                }
            }

            // Collect results
            for try await result in group {
                let currentCompleted = await accumulator.incrementCompleted()

                switch result {
                case .success(let transcript):
                    await accumulator.addTranscript(transcript)

                    await MainActor.run { [currentCompleted] in
                        self.progressDelegate?.chunkProgressUpdated(
                            completed: currentCompleted,
                            total: totalChunks
                        )
                        self.progressDelegate?.chunkCompleted(
                            index: transcript.index,
                            text: transcript.text
                        )
                    }

                case .failure(let error):
                    if let chunkError = error as? ChunkError {
                        await accumulator.addError(index: chunkError.index, error: chunkError.error)

                        await MainActor.run { [currentCompleted] in
                            self.progressDelegate?.chunkProgressUpdated(
                                completed: currentCompleted,
                                total: totalChunks
                            )
                            self.progressDelegate?.chunkFailed(
                                index: chunkError.index,
                                error: chunkError.error,
                                willRetry: false
                            )
                        }
                    }
                }
            }
        }

        // Get final results
        let transcripts = await accumulator.getTranscripts()
        let errors = await accumulator.getErrors()

        // Handle results
        if transcripts.isEmpty {
            // Check if all errors are cancellation errors - if so, propagate as CancellationError
            let allCancelled = errors.allSatisfy { $0.error is CancellationError }
            if allCancelled {
                DebugLogger.log("CHUNK-SERVICE: All chunks were cancelled - propagating cancellation")
                throw CancellationError()
            }
            throw ChunkedTranscriptionError.allChunksFailed(errors: errors)
        }

        if !errors.isEmpty {
            // Partial success - log warning but return what we have
            let failedIndices = errors.map { $0.index }
            DebugLogger.logWarning("CHUNK-SERVICE: Partial success - \(failedIndices.count) chunks failed: \(failedIndices)")
            // The caller can decide how to handle partial results
        }

        return transcripts.sorted { $0.index < $1.index }
    }

    // MARK: - Single Chunk Processing

    private func transcribeChunk(
        chunk: AudioChunk,
        apiKey: String,
        model: TranscriptionModel,
        prompt: String,
        totalChunks: Int
    ) async throws -> ChunkTranscript {
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                // Wait if we're in a rate-limited period (global coordination)
                await rateLimitCoordinator.waitIfNeeded()

                // Check for cancellation after waiting
                try Task.checkCancellation()

                // Report retry status
                if attempt > 1 {
                    let errorToReport = lastError ?? TranscriptionError.networkError("Unknown")
                    await MainActor.run {
                        self.progressDelegate?.chunkFailed(
                            index: chunk.index,
                            error: errorToReport,
                            willRetry: true
                        )
                        // Re-notify that chunk is starting again (retry)
                        self.progressDelegate?.chunkStarted(index: chunk.index)
                    }
                    DebugLogger.log("CHUNK-SERVICE: Chunk \(chunk.index) attempt \(attempt)/\(maxRetries)")
                }

                // Read and encode audio
                let audioData = try Data(contentsOf: chunk.url)
                let base64Audio = audioData.base64EncodedString()

                // Get MIME type
                let fileExtension = chunk.url.pathExtension.lowercased()
                let mimeType = geminiClient.getMimeType(for: fileExtension)

                // Build request
                let endpoint = model.apiEndpoint
                var request = try geminiClient.createRequest(endpoint: endpoint, apiKey: apiKey)

                let transcriptionRequest = GeminiTranscriptionRequest(
                    contents: [
                        GeminiTranscriptionRequest.GeminiTranscriptionContent(
                            parts: [
                                GeminiTranscriptionRequest.GeminiTranscriptionPart(
                                    text: prompt.isEmpty
                                        ? "Transcribe this audio. Return only the transcribed text without any additional commentary or formatting."
                                        : prompt,
                                    inlineData: nil,
                                    fileData: nil
                                ),
                                GeminiTranscriptionRequest.GeminiTranscriptionPart(
                                    text: nil,
                                    inlineData: GeminiTranscriptionRequest.GeminiInlineData(
                                        mimeType: mimeType,
                                        data: base64Audio
                                    ),
                                    fileData: nil
                                )
                            ]
                        )
                    ]
                )

                request.httpBody = try JSONEncoder().encode(transcriptionRequest)

                // Make request (without GeminiAPIClient's internal retry - we handle it here)
                let response = try await geminiClient.performRequest(
                    request,
                    responseType: GeminiResponse.self,
                    mode: "CHUNK-\(chunk.index)",
                    withRetry: false
                )

                // Report success to coordinator (resets rate limit counter)
                await rateLimitCoordinator.reportSuccess()

                // Extract text
                let text = geminiClient.extractText(from: response)
                let normalizedText = TextProcessingUtility.normalizeTranscriptionText(text)

                DebugLogger.log("CHUNK-SERVICE: Chunk \(chunk.index) transcribed (\(normalizedText.count) chars)")

                return ChunkTranscript(
                    text: normalizedText,
                    index: chunk.index,
                    startTime: chunk.startTime,
                    endTime: chunk.endTime
                )

            } catch {
                lastError = error

                // Check if this is a rate limit or quota error with retry info
                if let transcriptionError = error as? TranscriptionError {
                    switch transcriptionError {
                    case .rateLimited(let retryAfter), .quotaExceeded(let retryAfter):
                        // Report to coordinator so all chunks pause
                        await rateLimitCoordinator.reportRateLimit(retryAfter: retryAfter)

                        // If we have a retry delay, this error is retryable
                        if retryAfter != nil && attempt < maxRetries {
                            DebugLogger.log("CHUNK-SERVICE: Chunk \(chunk.index) hit rate limit, will retry after coordinator wait")
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
                    DebugLogger.log("CHUNK-SERVICE: Chunk \(chunk.index) failed, retrying in \(String(format: "%.1f", delay))s")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        throw lastError ?? TranscriptionError.networkError("Chunk transcription failed")
    }
}

// MARK: - Helper Types

/// Wrapper error to track which chunk failed.
private struct ChunkError: Error {
    let index: Int
    let error: Error
}

/// Actor for thread-safe accumulation of transcription results.
private actor ResultAccumulator {
    private var transcripts: [ChunkTranscript] = []
    private var errors: [(index: Int, error: Error)] = []
    private var completedCount = 0

    func incrementCompleted() -> Int {
        completedCount += 1
        return completedCount
    }

    func addTranscript(_ transcript: ChunkTranscript) {
        transcripts.append(transcript)
    }

    func addError(index: Int, error: Error) {
        errors.append((index: index, error: error))
    }

    func getTranscripts() -> [ChunkTranscript] {
        return transcripts
    }

    func getErrors() -> [(index: Int, error: Error)] {
        return errors
    }
}

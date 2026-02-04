//
//  ChunkTTSService.swift
//  WhisperShortcut
//
//  Parallel chunk TTS synthesis with retry and result aggregation.
//

import Foundation

/// Actor to coordinate rate limiting across all TTS chunk tasks.
/// When one chunk hits a 429, all chunks pause together.
actor TTSRateLimitCoordinator {
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
            DebugLogger.log("TTS-RATE-LIMIT-COORDINATOR: Waiting \(String(format: "%.1f", waitTime))s before next request")

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
            DebugLogger.log("TTS-RATE-LIMIT-COORDINATOR: API requested \(retryAfter)s delay, using \(delay)s")
        } else {
            // Exponential backoff: 30s, 60s, 120s, capped at 120s
            delay = min(30.0 * pow(2.0, Double(consecutiveRateLimits - 1)), 120.0)
            DebugLogger.log("TTS-RATE-LIMIT-COORDINATOR: No API delay, using exponential backoff: \(delay)s")
        }

        let newPauseUntil = Date().addingTimeInterval(delay)
        if newPauseUntil > pauseUntil {
            pauseUntil = newPauseUntil
            notificationShown = false  // Reset so next waitIfNeeded shows notification
            DebugLogger.log("TTS-RATE-LIMIT-COORDINATOR: All chunks paused until \(pauseUntil)")
        }
    }

    /// Report a successful request (resets consecutive counter)
    func reportSuccess() {
        if consecutiveRateLimits > 0 {
            DebugLogger.log("TTS-RATE-LIMIT-COORDINATOR: Request succeeded, resetting rate limit counter")
            consecutiveRateLimits = 0
        }
    }
}

/// Errors specific to chunked TTS.
enum ChunkedTTSError: Error, LocalizedError {
    case chunkingFailed(Error)
    case allChunksFailed(errors: [(index: Int, error: Error)])

    var errorDescription: String? {
        switch self {
        case .chunkingFailed(let error):
            return "Failed to chunk text: \(error.localizedDescription)"
        case .allChunksFailed(let errors):
            return "All \(errors.count) chunks failed to synthesize"
        }
    }
}

/// Service for synthesizing long texts by splitting into chunks
/// and processing them in parallel with retry logic.
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

    /// Gemini API client for making requests.
    private let geminiClient: GeminiAPIClient

    /// Coordinator for global rate limiting across all chunks.
    private let rateLimitCoordinator = TTSRateLimitCoordinator()

    // MARK: - Initialization

    init(
        maxRetries: Int = 5,  // Increased from 3 to handle rate limiting with proper delays
        retryDelay: TimeInterval = 1.5,
        geminiClient: GeminiAPIClient? = nil
    ) {
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.chunker = TextChunker()
        self.geminiClient = geminiClient ?? GeminiAPIClient()
    }

    // MARK: - Public API

    /// Synthesize text to speech using chunking if needed.
    /// - Parameters:
    ///   - text: The text to synthesize
    ///   - voiceName: Voice name to use
    ///   - apiKey: Gemini API key
    ///   - model: TTS model to use
    /// - Returns: Synthesized audio data
    func synthesize(
        text: String,
        voiceName: String,
        apiKey: String,
        model: TTSModel
    ) async throws -> Data {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        DebugLogger.log("TTS-CHUNK-SERVICE: Starting synthesis (text length: \(text.count) chars, voice: \(voiceName), model: \(model.displayName))")

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
            let result = try await synthesizeChunk(
                chunk: chunks[0],
                voiceName: voiceName,
                apiKey: apiKey,
                model: model,
                totalChunks: 1
            )
            let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
            DebugLogger.logSuccess("TTS-CHUNK-SERVICE: Single chunk synthesis completed in \(String(format: "%.2f", elapsedTime))s (\(result.data.count) bytes)")
            return result.data
        }

        // Synthesize chunks in parallel
        DebugLogger.log("TTS-CHUNK-SERVICE: Starting parallel synthesis of \(chunks.count) chunks")
        let audioChunks = try await synthesizeParallel(
            chunks: chunks,
            voiceName: voiceName,
            apiKey: apiKey,
            model: model
        )

        // Notify delegate about merging start
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
        voiceName: String,
        apiKey: String,
        model: TTSModel
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
                        let audioData = try await self.synthesizeChunk(
                            chunk: chunk,
                            voiceName: voiceName,
                            apiKey: apiKey,
                            model: model,
                            totalChunks: totalChunks
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

                        // Notify delegate that chunk failed (no retry at this level - retries happen in synthesizeChunk)
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

    private func synthesizeChunk(
        chunk: TextChunk,
        voiceName: String,
        apiKey: String,
        model: TTSModel,
        totalChunks: Int
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

                // Build request
                let endpoint = model.apiEndpoint
                var request = try geminiClient.createRequest(endpoint: endpoint, apiKey: apiKey)

                // Build contents with text input
                let contents = [
                    GeminiChatRequest.GeminiChatContent(
                        role: "user",
                        parts: [
                            GeminiChatRequest.GeminiChatPart(
                                text: chunk.text,
                                inlineData: nil,
                                fileData: nil,
                                url: nil
                            )
                        ]
                    )
                ]

                // Build generation config with audio output
                let generationConfig = GeminiChatRequest.GeminiGenerationConfig(
                    responseModalities: ["AUDIO"],
                    speechConfig: GeminiChatRequest.GeminiSpeechConfig(
                        voiceConfig: GeminiChatRequest.GeminiVoiceConfig(
                            prebuiltVoiceConfig: GeminiChatRequest.GeminiPrebuiltVoiceConfig(
                                voiceName: voiceName
                            )
                        )
                    )
                )

                // Create request
                let chatRequest = GeminiChatRequest(
                    contents: contents,
                    systemInstruction: nil,
                    tools: nil,
                    generationConfig: generationConfig,
                    model: model.modelName
                )

                request.httpBody = try JSONEncoder().encode(chatRequest)

                DebugLogger.logDebug("TTS-CHUNK-SERVICE: Making API request for chunk \(chunk.index) (text length: \(chunk.text.count) chars)")
                
                // Make request (without GeminiAPIClient's internal retry - we handle it here)
                let result = try await geminiClient.performRequest(
                    request,
                    responseType: GeminiChatResponse.self,
                    mode: "TTS-CHUNK-\(chunk.index)",
                    withRetry: false
                )

                DebugLogger.logDebug("TTS-CHUNK-SERVICE: Received response for chunk \(chunk.index) (candidates: \(result.candidates.count))")

                guard let firstCandidate = result.candidates.first else {
                    throw TranscriptionError.networkError("No candidates in Gemini TTS response")
                }

                // Extract audio data from response
                DebugLogger.logDebug("TTS-CHUNK-SERVICE: Extracting audio from chunk \(chunk.index) response (\(firstCandidate.content.parts.count) parts)")
                for (partIndex, part) in firstCandidate.content.parts.enumerated() {
                    if let inlineData = part.inlineData {
                        DebugLogger.logDebug("TTS-CHUNK-SERVICE: Found inlineData in part \(partIndex) (mimeType: \(inlineData.mimeType), base64 length: \(inlineData.data.count))")
                        
                        // Decode base64 audio data
                        guard let audioData = Data(base64Encoded: inlineData.data) else {
                            DebugLogger.logError("TTS-CHUNK-SERVICE: Failed to decode base64 audio data for chunk \(chunk.index)")
                            throw TranscriptionError.networkError("Failed to decode base64 audio data")
                        }

                        // Report success to coordinator (resets rate limit counter)
                        await rateLimitCoordinator.reportSuccess()

                        DebugLogger.logSuccess("TTS-CHUNK-SERVICE: Chunk \(chunk.index) synthesized successfully (\(audioData.count) bytes, \(String(format: "%.2f", Double(audioData.count) / 24000.0 / 2.0))s estimated duration)")

                        return AudioChunkData(
                            data: audioData,
                            index: chunk.index
                        )
                    }
                }

                DebugLogger.logError("TTS-CHUNK-SERVICE: No audio data found in TTS response for chunk \(chunk.index)")
                throw TranscriptionError.networkError("No audio data found in TTS response")

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

/// Wrapper error to track which chunk failed.
private struct ChunkError: Error {
    let index: Int
    let error: Error
}

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


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
            return ChunkFailureMessage.message(context: "audio", error: error)
        case .allChunksFailed(let errors):
            return "All \(errors.count) chunks failed to transcribe"
        case .partialSuccess(_, let failedChunks):
            return "Partial transcription: \(failedChunks.count) chunk(s) failed"
        }
    }
}

/// Service for transcribing long audio files by splitting into chunks
/// and processing them in parallel with retry logic.
class ChunkTranscriptionService {
    // MARK: - Constants

    /// Per-chunk request timeout. If a single chunk doesn't complete within this time,
    /// the request is aborted and retried instead of blocking the whole transcription.
    /// Prevents one slow API response (e.g. 2+ minutes) from delaying the entire result.
    private static let chunkResourceTimeout: TimeInterval = 90.0

    // MARK: - Properties

    /// Delegate for receiving progress updates.
    weak var progressDelegate: ChunkProgressDelegate?

    /// Maximum retry attempts per chunk.
    let maxRetries: Int

    /// Base retry delay (exponential backoff applied).
    let retryDelay: TimeInterval

    /// Audio chunker for splitting files.
    private let chunker: AudioChunker

    /// Gemini API client for making requests.
    private let geminiClient: GeminiAPIClient

    /// Coordinator for global rate limiting across all chunks.
    private let rateLimitCoordinator = RateLimitCoordinator(logPrefix: "CHUNK-RATE-LIMIT")

    /// Per-chunk retry policy, shared with `ChunkTTSService` (see `ChunkRetryPolicy`).
    private var retryPolicy: ChunkRetryPolicy {
        ChunkRetryPolicy(
            maxRetries: maxRetries, retryDelay: retryDelay,
            coordinator: rateLimitCoordinator, logPrefix: "CHUNK-SERVICE")
    }

    // MARK: - Initialization

    init(
        maxRetries: Int = 5,  // Increased from 3 to handle rate limiting with proper delays
        retryDelay: TimeInterval = 1.5,
        geminiClient: GeminiAPIClient? = nil
    ) {
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.chunker = AudioChunker()
        if let geminiClient = geminiClient {
            self.geminiClient = geminiClient
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60.0
            config.timeoutIntervalForResource = Self.chunkResourceTimeout
            OfflineModeURLProtocol.install(on: config)
            let session = URLSession(configuration: config)
            self.geminiClient = GeminiAPIClient(session: session)
        }
    }

    deinit {
        chunker.cleanup()
    }

    // MARK: - Public API

    /// Transcribe an audio file using chunking if needed. Chunk export and transcription
    /// upload are pipelined via `AudioChunker.splitAudioStream`: chunk N+1 is exported in
    /// parallel with chunks 0..N already in flight against the API, eliminating the
    /// "wait for all chunks to be split before any upload" delay on long recordings.
    /// - Parameters:
    ///   - fileURL: URL of the audio file
    ///   - audioDuration: Pre-loaded duration in seconds (the caller already needed it for
    ///     the chunking-vs-inline decision). Forwarded to `splitAudioStream` to skip a
    ///     duplicate `asset.load(.duration)`.
    ///   - credential: Gemini API credential (API key)
    ///   - model: Transcription model to use
    ///   - prompt: Custom transcription prompt
    /// - Returns: Transcribed text
    func transcribe(
        fileURL: URL,
        audioDuration: TimeInterval,
        credential: GeminiCredential,
        model: TranscriptionModel,
        prompt: String,
        glossaryTerms: [String] = []
    ) async throws -> String {
        let startTime = CFAbsoluteTimeGetCurrent()

        let chunkStream: AudioChunkStream
        do {
            chunkStream = try await chunker.splitAudioStream(fileURL: fileURL, precomputedDuration: audioDuration)
        } catch {
            throw ChunkedTranscriptionError.chunkingFailed(error)
        }

        DebugLogger.log("CHUNK-SERVICE: Streaming split, expected \(chunkStream.expectedCount) chunks")

        await MainActor.run {
            progressDelegate?.chunkingStarted(totalChunks: chunkStream.expectedCount)
        }

        // Pipelined transcription: producer (chunker) and consumers (transcribe tasks) run
        // concurrently inside the same task group.
        let (transcripts, yieldedChunks) = try await transcribeParallel(
            chunkStream: chunkStream,
            credential: credential,
            model: model,
            prompt: prompt,
            glossaryTerms: glossaryTerms
        )

        // Don't flip the menu bar into `.merging` if Stop already fired: the cancel handler
        // moved app state to `.idle`, and a late delegate call would re-enter a busy state
        // on top of that, leaving the UI stuck.
        try Task.checkCancellation()
        await MainActor.run {
            progressDelegate?.mergingStarted()
        }

        let result = TranscriptMerger.merge(transcripts)

        let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
        DebugLogger.log("CHUNK-SERVICE: Total transcription time: \(String(format: "%.2f", elapsedTime))s")

        chunker.cleanup(chunks: yieldedChunks)

        return result
    }

    // MARK: - Parallel Processing

    /// Drives the producer/consumer pipeline. The outer `for try await chunk in stream`
    /// suspends between exports — while suspended, transcribe tasks already in the group
    /// run in parallel. After the splitter finishes, the second loop drains results.
    private func transcribeParallel(
        chunkStream: AudioChunkStream,
        credential: GeminiCredential,
        model: TranscriptionModel,
        prompt: String,
        glossaryTerms: [String]
    ) async throws -> (transcripts: [ChunkTranscript], chunks: [AudioChunk]) {
        let totalChunks = chunkStream.expectedCount
        let accumulator = ChunkResultAccumulator<ChunkTranscript>()
        var yieldedChunks: [AudioChunk] = []

        try await withThrowingTaskGroup(of: Result<ChunkTranscript, Error>.self) { group in
            // Producer-side: drain the splitter stream and dispatch a transcribe task per
            // chunk. Splitter errors are wrapped as `chunkingFailed`; cancellation re-throws
            // as-is. Transcription errors don't surface here — they land in `Result.failure`.
            do {
                for try await chunk in chunkStream.stream {
                    yieldedChunks.append(chunk)
                    group.addTask { [self] in
                        await MainActor.run {
                            self.progressDelegate?.chunkStarted(index: chunk.index)
                        }
                        do {
                            let transcript = try await self.transcribeChunk(
                                chunk: chunk,
                                credential: credential,
                                model: model,
                                prompt: prompt,
                                glossaryTerms: glossaryTerms,
                                totalChunks: totalChunks
                            )
                            return .success(transcript)
                        } catch {
                            return .failure(ChunkError(index: chunk.index, error: error))
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ChunkedTranscriptionError.chunkingFailed(error)
            }

            // Drain side: collect results as transcribe tasks complete.
            for try await result in group {
                let currentCompleted = await accumulator.incrementCompleted()

                switch result {
                case .success(let transcript):
                    await accumulator.add(transcript)
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

        let transcripts = await accumulator.allValues()
        let errors = await accumulator.allErrors()

        if transcripts.isEmpty {
            let allCancelled = errors.allSatisfy { $0.error is CancellationError }
            if allCancelled {
                DebugLogger.log("CHUNK-SERVICE: All chunks were cancelled - propagating cancellation")
                throw CancellationError()
            }
            throw ChunkedTranscriptionError.allChunksFailed(errors: errors)
        }

        if !errors.isEmpty {
            let failedIndices = errors.map { $0.index }
            DebugLogger.logWarning("CHUNK-SERVICE: Partial success - \(failedIndices.count) chunks failed: \(failedIndices)")
        }

        return (transcripts.sorted { $0.index < $1.index }, yieldedChunks)
    }

    // MARK: - Single Chunk Processing

    private func transcribeChunk(
        chunk: AudioChunk,
        credential: GeminiCredential,
        model: TranscriptionModel,
        prompt: String,
        glossaryTerms: [String],
        totalChunks: Int
    ) async throws -> ChunkTranscript {
        try await retryPolicy.run(
            label: "Chunk \(chunk.index)",
            beforeRetry: { error, _ in
                let errorToReport = error ?? TranscriptionError.networkError("Unknown")
                await MainActor.run {
                    self.progressDelegate?.chunkFailed(
                        index: chunk.index,
                        error: errorToReport,
                        willRetry: true
                    )
                    // Re-notify that chunk is starting again (retry)
                    self.progressDelegate?.chunkStarted(index: chunk.index)
                }
            }
        ) {
            // Read and encode audio (as compact AAC when possible)
            let audioData: Data
            let mimeType: String
            if let aacData = AudioTranscoder.aacData(for: chunk.url) {
                audioData = aacData
                mimeType = AudioTranscoder.aacMimeType
            } else {
                audioData = try Data(contentsOf: chunk.url)
                mimeType = geminiClient.getMimeType(for: chunk.url.pathExtension.lowercased())
            }
            let base64Audio = audioData.base64EncodedString()

            let endpoint = model.apiEndpoint
            var request = try geminiClient.createRequest(endpoint: endpoint, credential: credential)
            request.timeoutInterval = Self.chunkResourceTimeout

            let transcriptionRequest = GeminiTranscriptionRequest(
                contents: [
                    GeminiTranscriptionRequest.GeminiTranscriptionContent(
                        parts: [
                            .text(prompt.isEmpty
                                ? "Transcribe this audio. Return only the transcribed text without any additional commentary or formatting."
                                : prompt),
                            .inline(mimeType: mimeType, data: base64Audio)
                        ]
                    )
                ],
                generationConfig: model.geminiTranscriptionGenerationConfig
            )

            request.httpBody = try JSONEncoder().encode(transcriptionRequest)

            // Make request (without GeminiAPIClient's internal retry - we handle it here)
            let response = try await geminiClient.performRequest(
                request,
                responseType: GeminiResponse.self,
                mode: "CHUNK-\(chunk.index)",
                withRetry: false
            )

            // Extract text
            let text = geminiClient.extractText(from: response)
            // A near-silent trailing chunk can trigger prompt-context confabulation on
            // Flash-tier models, in both directions: impossibly long invented output, or
            // near-empty output made of nothing but the glossary we sent in the prompt.
            let chunkDuration = chunk.endTime - chunk.startTime
            let normalizedText = TextProcessingUtility.discardingGlossaryEchoTranscript(
                TextProcessingUtility.discardingImplausibleTranscript(
                    TextProcessingUtility.normalizeTranscriptionText(text),
                    audioDurationSeconds: chunkDuration,
                    mode: "CHUNK-\(chunk.index)"),
                audioDurationSeconds: chunkDuration,
                glossaryTerms: glossaryTerms,
                mode: "CHUNK-\(chunk.index)")

            DebugLogger.log("CHUNK-SERVICE: Chunk \(chunk.index) transcribed (\(normalizedText.count) chars)")

            return ChunkTranscript(
                text: normalizedText,
                index: chunk.index,
                startTime: chunk.startTime,
                endTime: chunk.endTime
            )
        }
    }
}

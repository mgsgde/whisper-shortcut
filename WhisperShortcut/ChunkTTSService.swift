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

/// Cuts a byte stream of s16le mono PCM into playable slices: never mid-sample, a short first
/// slice so playback starts as early as possible, then half-second batches so the player node is
/// not fed a flood of tiny buffers. 24 kHz × 2 bytes = 48 000 bytes per second.
struct PCMStreamBatcher {
    static let bytesPerSecond = 48_000
    private let firstFlushBytes: Int
    private let flushBytes: Int
    private var pending = Data()
    private var flushedOnce = false

    init(firstFlushSeconds: Double = 0.25, flushSeconds: Double = 0.5) {
        firstFlushBytes = Int(firstFlushSeconds * Double(Self.bytesPerSecond))
        flushBytes = Int(flushSeconds * Double(Self.bytesPerSecond))
    }

    /// Appends one byte; returns a slice when a batch is complete.
    mutating func append(_ byte: UInt8) -> Data? {
        pending.append(byte)
        let threshold = flushedOnce ? flushBytes : firstFlushBytes
        guard pending.count >= threshold, pending.count.isMultiple(of: 2) else { return nil }
        return take()
    }

    /// Whatever is left at the end of the stream (dropping a trailing half-sample, if any).
    mutating func drain() -> Data? {
        if !pending.count.isMultiple(of: 2) { pending.removeLast() }
        return pending.isEmpty ? nil : take()
    }

    private mutating func take() -> Data {
        defer { pending = Data(); flushedOnce = true }
        return pending
    }
}

/// Playback-order gate for `onChunkReady`: chunks finish out of order, so audio is held here until
/// every chunk before it has been emitted. Partial audio (a streaming provider's slices) passes
/// straight through for the chunk whose turn it is and is buffered for the others; on completion
/// only the bytes not yet emitted go out, so a chunk that streamed live is never played twice.
/// A permanently failed chunk opens the gate for its successors — playing the rest with a gap
/// beats playing nothing at all.
///
/// An actor because partials arrive from the parallel synthesis tasks while completions arrive
/// from the collecting loop; every emission happens on the main actor, in order.
actor PlaybackOrderGate {
    private let totalChunks: Int
    private let onChunkReady: (Data, Int, Int) -> Void
    private var nextChunkToEmit = 0
    /// Audio received for chunks that are not yet at the gate, live partials included.
    private var buffered: [Int: Data] = [:]
    /// How many bytes of each chunk have already been handed to playback.
    private var emittedBytes: [Int: Int] = [:]
    private var completed = Set<Int>()
    private var failed = Set<Int>()

    init(totalChunks: Int, onChunkReady: @escaping (Data, Int, Int) -> Void) {
        self.totalChunks = totalChunks
        self.onChunkReady = onChunkReady
    }

    /// A streaming slice of chunk `index`, in arrival order.
    func partial(index: Int, data: Data) async {
        guard !completed.contains(index), !failed.contains(index) else { return }
        if index == nextChunkToEmit {
            await emit(data, index: index)
        } else {
            buffered[index, default: Data()].append(data)
        }
    }

    /// Drops partials buffered for `index` that were never emitted — a retry will resend them.
    /// Bytes already played stay counted, so the retried chunk resumes after them.
    func discardBuffered(index: Int) {
        buffered[index] = nil
    }

    /// The complete audio of chunk `index`. Emits the remainder (if its turn) and releases whatever
    /// became contiguous behind it.
    func complete(index: Int, data: Data) async {
        completed.insert(index)
        buffered[index] = data
        await releasePlayable()
    }

    func fail(index: Int) async {
        failed.insert(index)
        buffered[index] = nil
        await releasePlayable()
    }

    private func releasePlayable() async {
        while nextChunkToEmit < totalChunks {
            let index = nextChunkToEmit
            if completed.contains(index) {
                let data = buffered.removeValue(forKey: index) ?? Data()
                let already = emittedBytes[index] ?? 0
                if data.count > already { await emit(data.suffix(from: already), index: index) }
                nextChunkToEmit += 1
            } else if failed.contains(index) {
                nextChunkToEmit += 1
            } else {
                // Not finished yet, but its turn: flush what has streamed in so far and wait.
                if let head = buffered.removeValue(forKey: index), !head.isEmpty {
                    await emit(head, index: index)
                }
                break
            }
        }
    }

    private func emit(_ data: Data, index: Int) async {
        guard !data.isEmpty else { return }
        emittedBytes[index, default: 0] += data.count
        let total = totalChunks
        let sink = onChunkReady
        await MainActor.run { sink(Data(data), index, total) }
    }
}

/// Service for synthesizing long texts by splitting into chunks
/// and processing them in parallel with retry logic.
///
/// Provider-agnostic: the caller injects a `synthesizeText` closure that turns one text
/// segment into raw PCM (s16le, 24 kHz, mono). Retry, global rate-limit coordination, and
/// audio merging are handled here, so Gemini / OpenAI / xAI all share this path.
class ChunkTTSService {
    /// Provider-specific synthesis of one text segment to raw PCM (s16le, 24 kHz, mono). The
    /// `onPartial` callback is optional to honour: a provider that streams its body awaits it with
    /// each playable slice, in order; the returned `Data` is always the complete chunk.
    typealias Synthesizer = (_ text: String, _ onPartial: @escaping (Data) async -> Void) async throws -> Data

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

    /// Per-chunk retry policy, shared with `ChunkTranscriptionService` (see `ChunkRetryPolicy`).
    private var retryPolicy: ChunkRetryPolicy {
        ChunkRetryPolicy(
            maxRetries: maxRetries, retryDelay: retryDelay,
            coordinator: rateLimitCoordinator, logPrefix: "TTS-CHUNK-SERVICE")
    }

    // MARK: - Initialization

    /// - Parameter chunkSize: Ceiling of the chunk-size ramp (see `TextChunker`). Providers whose
    ///   streams misbehave above a certain audio length pass a lower cap — Gemini uses
    ///   `AppConstants.ttsGeminiChunkSizeChars`.
    init(
        maxRetries: Int = 5,  // Increased from 3 to handle rate limiting with proper delays
        retryDelay: TimeInterval = 1.5,
        chunkSize: Int = AppConstants.ttsChunkSizeChars
    ) {
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.chunker = TextChunker(chunkSize: chunkSize)
    }

    // MARK: - Public API

    /// Synthesize text to speech using chunking if needed.
    /// - Parameters:
    ///   - text: The text to synthesize
    ///   - model: TTS model to use (for logging only; the request is built by `synthesizeText`)
    ///   - onChunkReady: Called on the main actor with `(pcm, chunkIndex, totalChunks)` as each
    ///     chunk becomes playable, strictly **in playback order** — chunk 3 is withheld until
    ///     chunks 0–2 have been emitted, even though synthesis finishes out of order. Lets the
    ///     caller start playing the beginning while the tail is still being synthesized: waiting
    ///     for the merge means waiting for the *slowest* chunk (measured: 27.6 s to first sound
    ///     for a 4-chunk reply whose first chunk was ready after 18.1 s).
    ///     A streaming provider (OpenAI) delivers a chunk as several calls with the same index —
    ///     the first one as soon as a quarter second of audio exists — still in playback order.
    ///   - synthesizeText: Provider-specific closure that synthesizes one text segment to raw
    ///     PCM. It should throw `TranscriptionError` (e.g. `.rateLimited`) so retry/backoff works.
    /// - Returns: Synthesized audio data (merged PCM)
    func synthesize(
        text: String,
        model: TTSModel,
        onChunkReady: ((Data, Int, Int) -> Void)? = nil,
        synthesizeText: @escaping Synthesizer
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

        let gate = onChunkReady.map { PlaybackOrderGate(totalChunks: chunks.count, onChunkReady: $0) }

        // If only one chunk, process directly
        if chunks.count == 1 {
            DebugLogger.log("TTS-CHUNK-SERVICE: Single chunk, processing directly")
            let result = try await processChunk(
                chunk: chunks[0],
                totalChunks: 1,
                gate: gate,
                synthesizeText: synthesizeText
            )
            let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
            DebugLogger.logSuccess("TTS-CHUNK-SERVICE: Single chunk synthesis completed in \(String(format: "%.2f", elapsedTime))s (\(result.data.count) bytes)")
            await gate?.complete(index: 0, data: result.data)
            return result.data
        }

        // Synthesize chunks in parallel
        DebugLogger.log("TTS-CHUNK-SERVICE: Starting parallel synthesis of \(chunks.count) chunks")
        let audioChunks = try await synthesizeParallel(
            chunks: chunks,
            gate: gate,
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
        gate: PlaybackOrderGate?,
        synthesizeText: @escaping Synthesizer
    ) async throws -> [AudioChunkData] {
        let totalChunks = chunks.count

        DebugLogger.log("TTS-CHUNK-SERVICE: Starting parallel synthesis (total chunks: \(totalChunks))")

        // Use actor for thread-safe accumulation
        let accumulator = ChunkResultAccumulator<AudioChunkData>()

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
                            gate: gate,
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
                    await accumulator.add(audioChunk)
                    await gate?.complete(index: audioChunk.index, data: audioChunk.data)

                    DebugLogger.logSuccess("TTS-CHUNK-SERVICE: Chunk \(audioChunk.index + 1)/\(totalChunks) completed successfully (\(audioChunk.data.count) bytes)")

                    // Notify delegate that chunk completed
                    await MainActor.run {
                        progressDelegate?.chunkCompleted(index: audioChunk.index, text: "Audio synthesized (\(audioChunk.data.count) bytes)")
                        progressDelegate?.chunkProgressUpdated(completed: completed, total: totalChunks)
                    }

                case .failure(let error):
                    if let chunkError = error as? ChunkError {
                        await accumulator.addError(index: chunkError.index, error: chunkError.error)
                        await gate?.fail(index: chunkError.index)

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
        let audioChunks = await accumulator.allValues()
        let errors = await accumulator.allErrors()

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
        gate: PlaybackOrderGate?,
        synthesizeText: @escaping Synthesizer
    ) async throws -> AudioChunkData {
        // Partials stream to the gate on the first attempt only. A retry re-synthesizes the whole
        // chunk (TTS output is not deterministic, so its bytes cannot be spliced onto what already
        // played); the gate then emits just the part beyond what it has handed out.
        let attempts = AttemptCounter()
        return try await retryPolicy.run(
            label: "Chunk \(chunk.index)",
            beforeRetry: { error, _ in
                await gate?.discardBuffered(index: chunk.index)
                // Notify delegate about retry
                let errorToReport = error ?? TranscriptionError.networkError("Retrying")
                await MainActor.run {
                    self.progressDelegate?.chunkFailed(index: chunk.index, error: errorToReport, willRetry: true)
                }
            }
        ) {
            DebugLogger.logDebug("TTS-CHUNK-SERVICE: Making API request for chunk \(chunk.index) (text length: \(chunk.text.count) chars)")
            let isFirstAttempt = await attempts.next() == 1

            // Provider-specific synthesis (returns raw PCM s16le 24kHz mono — no WAV header).
            let audioData = try await synthesizeText(chunk.text) { slice in
                guard isFirstAttempt, let gate else { return }
                await gate.partial(index: chunk.index, data: slice)
            }

            DebugLogger.logSuccess("TTS-CHUNK-SERVICE: Chunk \(chunk.index) synthesized successfully (\(audioData.count) bytes, \(String(format: "%.2f", Double(audioData.count) / 24000.0 / 2.0))s estimated duration)")

            return AudioChunkData(
                data: audioData,
                index: chunk.index
            )
        }
    }
}

/// Counts a chunk's synthesis attempts across the retry policy's closure invocations.
private actor AttemptCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

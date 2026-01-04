//
//  AudioChunker.swift
//  WhisperShortcut
//
//  Splits audio files into overlapping chunks for parallel transcription.
//

import AVFoundation
import Foundation

/// Represents a chunk of audio extracted from a larger file.
struct AudioChunk {
    /// Temporary file URL containing this chunk's audio data.
    let url: URL
    /// Zero-based index of this chunk in the sequence.
    let index: Int
    /// Start time in the original audio (seconds).
    let startTime: TimeInterval
    /// End time in the original audio (seconds).
    let endTime: TimeInterval

    /// Duration of this chunk in seconds.
    var duration: TimeInterval {
        return endTime - startTime
    }
}

/// Errors that can occur during audio chunking.
enum AudioChunkerError: Error, LocalizedError {
    case invalidAudioFile
    case failedToLoadDuration
    case exportFailed(String)
    case noAudioTrack
    case fileCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidAudioFile:
            return "The audio file is invalid or cannot be read"
        case .failedToLoadDuration:
            return "Failed to determine audio duration"
        case .exportFailed(let reason):
            return "Failed to export audio chunk: \(reason)"
        case .noAudioTrack:
            return "No audio track found in the file"
        case .fileCreationFailed:
            return "Failed to create chunk file"
        }
    }
}

/// Splits audio files into overlapping chunks for parallel transcription.
class AudioChunker {
    /// Duration of each chunk in seconds. Default: 45s
    let chunkDuration: TimeInterval

    /// Overlap duration between chunks for context continuity. Default: 2s
    let overlapDuration: TimeInterval

    /// Directory for storing temporary chunk files.
    private let tempDirectory: URL

    /// Initialize with custom chunk and overlap durations.
    /// - Parameters:
    ///   - chunkDuration: Duration of each chunk (default: 45 seconds)
    ///   - overlapDuration: Overlap between chunks (default: 2 seconds)
    init(
        chunkDuration: TimeInterval = AppConstants.chunkDurationSeconds,
        overlapDuration: TimeInterval = AppConstants.chunkOverlapSeconds
    ) {
        self.chunkDuration = chunkDuration
        self.overlapDuration = overlapDuration

        // Create temp directory for chunks
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper_chunks_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.tempDirectory = tempDir
    }

    deinit {
        // Clean up temp directory when chunker is deallocated
        cleanup()
    }

    /// Get the duration of an audio file.
    /// - Parameter fileURL: URL of the audio file
    /// - Returns: Duration in seconds
    func getAudioDuration(_ fileURL: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    /// Determine if an audio file needs chunking.
    /// - Parameter fileURL: URL of the audio file
    /// - Returns: True if the audio should be chunked
    func needsChunking(_ fileURL: URL) async throws -> Bool {
        let duration = try await getAudioDuration(fileURL)
        return duration > AppConstants.chunkingThresholdSeconds
    }

    /// Split an audio file into overlapping chunks.
    /// - Parameter fileURL: URL of the source audio file
    /// - Returns: Array of AudioChunk objects, sorted by index
    func splitAudio(fileURL: URL) async throws -> [AudioChunk] {
        let asset = AVURLAsset(url: fileURL)

        // Load duration
        let duration = try await asset.load(.duration)
        let totalDuration = CMTimeGetSeconds(duration)

        // If audio is short enough, return as single chunk
        if totalDuration <= chunkDuration + overlapDuration {
            return [AudioChunk(url: fileURL, index: 0, startTime: 0, endTime: totalDuration)]
        }

        // Calculate chunk boundaries
        var chunks: [AudioChunk] = []
        var currentStart: TimeInterval = 0
        var chunkIndex = 0

        while currentStart < totalDuration {
            // Calculate chunk end (with overlap extending into next chunk's territory)
            let chunkEnd = min(currentStart + chunkDuration, totalDuration)

            // Export this chunk
            let chunkURL = try await exportChunk(
                from: asset,
                sourceURL: fileURL,
                start: currentStart,
                end: min(chunkEnd + overlapDuration, totalDuration),
                index: chunkIndex
            )

            chunks.append(AudioChunk(
                url: chunkURL,
                index: chunkIndex,
                startTime: currentStart,
                endTime: chunkEnd
            ))

            // Move to next chunk (overlap means we step back slightly for context)
            currentStart = chunkEnd
            chunkIndex += 1
        }

        DebugLogger.logDebug("Split audio into \(chunks.count) chunks (total: \(String(format: "%.1f", totalDuration))s)")
        return chunks
    }

    /// Export a portion of an audio file to a new file.
    private func exportChunk(
        from asset: AVAsset,
        sourceURL: URL,
        start: TimeInterval,
        end: TimeInterval,
        index: Int
    ) async throws -> URL {
        // Create output URL
        let outputURL = tempDirectory.appendingPathComponent("chunk_\(index).wav")

        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)

        // Use AVAssetReader/Writer for precise audio extraction
        let timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 44100),
            end: CMTime(seconds: end, preferredTimescale: 44100)
        )

        // Load the audio track
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioChunkerError.noAudioTrack
        }

        // Load source format description for passthrough
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        let sourceFormatHint = formatDescriptions.first

        // Create asset reader
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange

        // Configure output settings matching the source format (24kHz, 16-bit, mono)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 24000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw AudioChunkerError.exportFailed("Cannot add reader output")
        }
        reader.add(readerOutput)

        // Create asset writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)

        // Use passthrough mode with source format hint for better compatibility
        // This avoids crashes from incompatible output settings
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: sourceFormatHint
        )
        writerInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(writerInput) else {
            throw AudioChunkerError.exportFailed("Cannot add writer input")
        }
        writer.add(writerInput)

        // Start reading and writing
        guard reader.startReading() else {
            throw AudioChunkerError.exportFailed(reader.error?.localizedDescription ?? "Unknown read error")
        }

        guard writer.startWriting() else {
            throw AudioChunkerError.exportFailed(writer.error?.localizedDescription ?? "Unknown write error")
        }

        writer.startSession(atSourceTime: CMTime(seconds: start, preferredTimescale: 44100))

        // Process samples
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio.chunk.export")) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        writerInput.markAsFinished()

                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: AudioChunkerError.exportFailed(
                                    writer.error?.localizedDescription ?? "Write failed"
                                ))
                            }
                        }
                        return
                    }
                }
            }
        }

        // Verify output file exists and has content
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw AudioChunkerError.fileCreationFailed
        }

        return outputURL
    }

    /// Clean up all temporary chunk files.
    func cleanup() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// Clean up specific chunk files.
    /// - Parameter chunks: Array of chunks whose files should be deleted
    func cleanup(chunks: [AudioChunk]) {
        for chunk in chunks {
            // Don't delete the original file (index 0 with original URL)
            if chunk.url.path.contains("chunk_") {
                try? FileManager.default.removeItem(at: chunk.url)
            }
        }
    }
}

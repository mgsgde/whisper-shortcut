//
//  AudioMerger.swift
//  WhisperShortcut
//
//  Merges PCM audio data chunks into a single audio stream.
//

import Foundation

/// Represents audio data from a chunk with index information.
struct AudioChunkData {
    /// PCM audio data from this chunk.
    let data: Data
    /// Zero-based index of this chunk in the sequence.
    let index: Int
}

/// Merges PCM audio data chunks into a single audio stream.
class AudioMerger {
    /// Expected PCM format: 16-bit signed little-endian, 24kHz, mono
    private static let expectedSampleRate: Double = 24000
    private static let expectedChannels: UInt32 = 1
    private static let expectedBitsPerChannel: UInt32 = 16
    private static let bytesPerSample: Int = 2 // 16-bit = 2 bytes

    /// Merge multiple audio chunks into a single PCM audio data stream.
    /// - Parameter audioChunks: Array of audio chunk data (will be sorted by index)
    /// - Returns: Merged PCM audio data
    static func merge(_ audioChunks: [AudioChunkData]) throws -> Data {
        guard !audioChunks.isEmpty else {
            DebugLogger.logError("AUDIO-MERGER: No chunks provided for merging")
            throw AudioMergerError.noChunks
        }

        DebugLogger.log("AUDIO-MERGER: Starting merge of \(audioChunks.count) audio chunks")

        // Sort by index to ensure correct order
        let sorted = audioChunks.sorted { $0.index < $1.index }
        DebugLogger.logDebug("AUDIO-MERGER: Sorted chunks by index: \(sorted.map { "\($0.index):\($0.data.count)bytes" }.joined(separator: ", "))")

        guard sorted.count > 1 else {
            DebugLogger.log("AUDIO-MERGER: Single chunk, returning as-is (\(sorted[0].data.count) bytes)")
            return sorted[0].data
        }

        // Verify all chunks have valid PCM data
        var totalBytes = 0
        for chunk in sorted {
            guard !chunk.data.isEmpty else {
                DebugLogger.logWarning("AUDIO-MERGER: Chunk \(chunk.index) has empty data, skipping")
                continue
            }

            // Verify data length is multiple of bytes per sample (16-bit = 2 bytes)
            guard chunk.data.count % bytesPerSample == 0 else {
                DebugLogger.logError("AUDIO-MERGER: Invalid format for chunk \(chunk.index) - data length (\(chunk.data.count)) is not a multiple of \(bytesPerSample) bytes")
                throw AudioMergerError.invalidChunkFormat(
                    index: chunk.index,
                    reason: "Data length (\(chunk.data.count)) is not a multiple of \(bytesPerSample) bytes"
                )
            }
            
            totalBytes += chunk.data.count
            DebugLogger.logDebug("AUDIO-MERGER: Validated chunk \(chunk.index): \(chunk.data.count) bytes (format: OK)")
        }

        // Concatenate all chunks sequentially
        var mergedData = Data(capacity: totalBytes)
        for chunk in sorted {
            if !chunk.data.isEmpty {
                mergedData.append(chunk.data)
                DebugLogger.logDebug("AUDIO-MERGER: Appended chunk \(chunk.index) (\(chunk.data.count) bytes) - total so far: \(mergedData.count) bytes")
            }
        }

        let estimatedDuration = Double(mergedData.count) / expectedSampleRate / Double(bytesPerSample) * Double(expectedChannels)
        DebugLogger.logSuccess("AUDIO-MERGER: Successfully merged \(sorted.count) chunks into \(mergedData.count) bytes total (estimated duration: \(String(format: "%.2f", estimatedDuration))s)")
        return mergedData
    }

    /// Verify that audio data matches expected PCM format.
    /// - Parameter data: The audio data to verify
    /// - Returns: True if format matches expected format
    static func verifyFormat(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        guard data.count % bytesPerSample == 0 else { return false }
        return true
    }
}

/// Errors that can occur during audio merging.
enum AudioMergerError: Error, LocalizedError {
    case noChunks
    case invalidChunkFormat(index: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .noChunks:
            return "No audio chunks provided for merging"
        case .invalidChunkFormat(let index, let reason):
            return "Invalid format for chunk \(index): \(reason)"
        }
    }
}


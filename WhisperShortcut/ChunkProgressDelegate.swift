//
//  ChunkProgressDelegate.swift
//  WhisperShortcut
//
//  Protocol for receiving chunk transcription progress updates.
//

import Foundation

/// Protocol for receiving progress updates during chunked transcription.
/// Implement this protocol to update UI or track transcription progress.
@MainActor
protocol ChunkProgressDelegate: AnyObject {
    /// Called when chunk processing progress changes.
    /// - Parameters:
    ///   - completed: Number of chunks completed so far
    ///   - total: Total number of chunks to process
    func chunkProgressUpdated(completed: Int, total: Int)

    /// Called when a chunk is successfully transcribed.
    /// - Parameters:
    ///   - index: The chunk index (0-based)
    ///   - text: The transcribed text for this chunk
    func chunkCompleted(index: Int, text: String)

    /// Called when a chunk transcription fails.
    /// - Parameters:
    ///   - index: The chunk index (0-based)
    ///   - error: The error that occurred
    ///   - willRetry: Whether the chunk will be retried
    func chunkFailed(index: Int, error: Error, willRetry: Bool)

    /// Called when chunking begins.
    /// - Parameter totalChunks: Total number of chunks that will be processed
    func chunkingStarted(totalChunks: Int)

    /// Called when all chunks are complete and merging begins.
    func mergingStarted()
}

/// Default implementations for optional delegate methods.
extension ChunkProgressDelegate {
    func chunkCompleted(index: Int, text: String) {}
    func chunkFailed(index: Int, error: Error, willRetry: Bool) {}
    func chunkingStarted(totalChunks: Int) {}
    func mergingStarted() {}
}

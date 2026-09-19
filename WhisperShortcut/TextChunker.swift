//
//  TextChunker.swift
//  WhisperShortcut
//
//  Splits text into chunks at sentence boundaries for parallel TTS processing.
//

import Foundation

/// Represents a chunk of text extracted from a larger text.
struct TextChunk {
    /// The text content of this chunk.
    let text: String
    /// Zero-based index of this chunk in the sequence.
    let index: Int
    /// Start character index in the original text.
    let startIndex: Int
    /// End character index in the original text.
    let endIndex: Int
}

/// Errors that can occur during text chunking.
enum TextChunkerError: Error, LocalizedError {
    case emptyText
    case invalidText

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "The text is empty"
        case .invalidText:
            return "The text is invalid"
        }
    }
}

/// Splits text into chunks at sentence boundaries for parallel TTS processing.
///
/// The first chunk is capped separately and much lower (`firstChunkSize`): playback starts as
/// soon as it is synthesized, and TTS latency grows with the audio length, so a short opener is
/// what decides how long the user waits. Caps after it grow geometrically by `growthFactor`
/// until they reach `chunkSize`, so each chunk's audio covers the next one's synthesis.
class TextChunker {
    /// Maximum characters per chunk after the ramp reaches its ceiling.
    let chunkSize: Int
    /// Maximum characters for the first chunk.
    let firstChunkSize: Int
    /// Multiplier applied to `firstChunkSize` at each later index, until the cap hits `chunkSize`.
    let growthFactor: Double

    /// - Parameters:
    ///   - chunkSize: Maximum characters per chunk after the ramp reaches its ceiling.
    ///   - firstChunkSize: Maximum characters for the first chunk. Clamped to `chunkSize`.
    ///   - growthFactor: Multiplier applied to `firstChunkSize` for each later index.
    init(
        chunkSize: Int = AppConstants.ttsChunkSizeChars,
        firstChunkSize: Int = AppConstants.ttsFirstChunkSizeChars,
        growthFactor: Double = AppConstants.ttsChunkGrowthFactor
    ) {
        self.chunkSize = chunkSize
        self.firstChunkSize = min(firstChunkSize, chunkSize)
        self.growthFactor = growthFactor
    }

    /// Cap for chunk `k`: `min(chunkSize, firstChunkSize * growthFactor^k)`.
    func chunkCap(forIndex k: Int) -> Int {
        min(chunkSize, Int(Double(firstChunkSize) * pow(growthFactor, Double(k))))
    }

    /// Determine if text needs chunking.
    /// - Parameter text: The text to check
    /// - Returns: True if the text should be chunked
    func needsChunking(_ text: String) -> Bool {
        let needsChunking = text.count > AppConstants.ttsChunkSizeChars
        if needsChunking {
            DebugLogger.log("TTS-CHUNKER: Text needs chunking (length: \(text.count) chars, threshold: \(AppConstants.ttsChunkSizeChars))")
        } else {
            DebugLogger.logDebug("TTS-CHUNKER: Text does not need chunking (length: \(text.count) chars, threshold: \(AppConstants.ttsChunkSizeChars))")
        }
        return needsChunking
    }

    /// Split text into chunks at sentence boundaries.
    /// - Parameter text: The text to split
    /// - Returns: Array of TextChunk objects, sorted by index
    func splitText(_ text: String) throws -> [TextChunk] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedText.isEmpty else {
            DebugLogger.logError("TTS-CHUNKER: Cannot split empty text")
            throw TextChunkerError.emptyText
        }

        DebugLogger.log("TTS-CHUNKER: Starting text split (text length: \(trimmedText.count) chars, chunk size: \(chunkSize), first chunk: \(firstChunkSize), growth factor: \(growthFactor))")

        // If text is short enough, return as single chunk
        if trimmedText.count <= firstChunkSize {
            DebugLogger.log("TTS-CHUNKER: Text fits in single chunk, returning as-is")
            return [TextChunk(
                text: trimmedText,
                index: 0,
                startIndex: 0,
                endIndex: trimmedText.count
            )]
        }

        var chunks: [TextChunk] = []
        var currentIndex = 0
        var chunkIndex = 0

        while currentIndex < trimmedText.count {
            let remainingText = String(trimmedText[trimmedText.index(trimmedText.startIndex, offsetBy: currentIndex)...])
            let remainingLength = remainingText.count
            let isFirstChunk = chunkIndex == 0
            let maxLength = chunkCap(forIndex: chunkIndex)
            let minLength = Int(Double(maxLength) * (isFirstChunk ? AppConstants.ttsFirstChunkMinSizeRatio : AppConstants.ttsChunkMinSizeRatio))

            // If remaining text fits in one chunk, add it and finish
            if remainingLength <= maxLength {
                chunks.append(TextChunk(
                    text: remainingText,
                    index: chunkIndex,
                    startIndex: currentIndex,
                    endIndex: trimmedText.count
                ))
                break
            }

            // Find the best split point within this chunk's cap
            let chunkEnd = findBestSplitPoint(
                in: remainingText,
                maxLength: maxLength,
                minLength: minLength,
                startOffset: currentIndex
            )

            let chunkText = String(trimmedText[trimmedText.index(trimmedText.startIndex, offsetBy: currentIndex)..<trimmedText.index(trimmedText.startIndex, offsetBy: chunkEnd)])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !chunkText.isEmpty {
                chunks.append(TextChunk(
                    text: chunkText,
                    index: chunkIndex,
                    startIndex: currentIndex,
                    endIndex: chunkEnd
                ))
                DebugLogger.logDebug("TTS-CHUNKER: Created chunk \(chunkIndex) (chars: \(chunkText.count), range: \(currentIndex)-\(chunkEnd))")
            }

            currentIndex = chunkEnd
            chunkIndex += 1
        }

        DebugLogger.log("TTS-CHUNKER: Split text into \(chunks.count) chunks (total: \(trimmedText.count) chars)")
        for (idx, chunk) in chunks.enumerated() {
            DebugLogger.logDebug("TTS-CHUNKER: Chunk \(idx): \(chunk.text.count) chars, preview: '\(String(chunk.text.prefix(50)))...'")
        }
        return chunks
    }

    /// Find the best split point within the maximum length.
    /// Tries sentence boundaries first, then word boundaries, then character limit.
    /// Only searches in the last portion of the chunk to prevent splitting too early.
    /// - Parameters:
    ///   - text: The text to search in
    ///   - maxLength: Maximum length for the chunk
    ///   - minLength: Minimum length for the chunk (prevents splitting too early)
    ///   - startOffset: The starting offset in the original text
    /// - Returns: The best split point (character index)
    private func findBestSplitPoint(in text: String, maxLength: Int, minLength: Int, startOffset: Int) -> Int {
        // Ensure we don't exceed the text length
        let searchLength = min(maxLength, text.count)
        
        guard searchLength > 0 else {
            return startOffset
        }

        let minChunkSize = minLength
        
        // Only search in the last portion of the chunk (last 30% or minimum 200 chars)
        // This ensures we don't split too early when natural boundaries are found near the start
        let searchStartOffset = max(0, searchLength - max(200, Int(Double(searchLength) * 0.3)))
        let searchRange = text.index(text.startIndex, offsetBy: searchStartOffset)..<text.index(text.startIndex, offsetBy: searchLength)
        let searchText = String(text[searchRange])
        
        // Ensure we don't split before minimum chunk size
        let minSplitPoint = max(minChunkSize, searchStartOffset)

        // Try to find sentence boundary (., !, ? followed by space or newline)
        if let sentenceEnd = findSentenceBoundary(in: searchText) {
            let absolutePosition = startOffset + searchStartOffset + sentenceEnd
            if absolutePosition >= startOffset + minSplitPoint {
                DebugLogger.logDebug("TTS-CHUNKER: Found sentence boundary at position \(absolutePosition)")
                return absolutePosition
            }
        }

        // Fallback: find word boundary (space or newline)
        if let wordEnd = findWordBoundary(in: searchText) {
            let absolutePosition = startOffset + searchStartOffset + wordEnd
            if absolutePosition >= startOffset + minSplitPoint {
                DebugLogger.logDebug("TTS-CHUNKER: Found word boundary at position \(absolutePosition)")
                return absolutePosition
            }
        }

        // Last resort: split at character limit (but respect minimum)
        let splitPoint = max(startOffset + minSplitPoint, startOffset + searchLength)
        DebugLogger.logDebug("TTS-CHUNKER: No boundary found, splitting at position \(splitPoint)")
        return splitPoint
    }

    /// Find sentence boundary in text.
    /// - Parameter text: The text to search
    /// - Returns: Character index of sentence boundary, or nil if not found
    private func findSentenceBoundary(in text: String) -> Int? {
        // Look for sentence endings: . ! ? followed by space or newline
        let sentenceEndings: Set<Character> = [".", "!", "?"]
        var searchIndex = text.endIndex

        // Search backwards from the end of the search range
        while searchIndex > text.startIndex {
            searchIndex = text.index(before: searchIndex)
            let char = text[searchIndex]

            if sentenceEndings.contains(char) {
                // Check if followed by space or newline
                let nextIndex = text.index(after: searchIndex)
                if nextIndex < text.endIndex {
                    let nextChar = text[nextIndex]
                    if nextChar.isWhitespace || nextChar.isNewline {
                        // Found sentence boundary - return position after the punctuation and whitespace
                        var endIndex = nextIndex
                        // Skip any additional whitespace
                        while endIndex < text.endIndex && (text[endIndex].isWhitespace || text[endIndex].isNewline) {
                            endIndex = text.index(after: endIndex)
                        }
                        return text.distance(from: text.startIndex, to: endIndex)
                    }
                }
            }
        }

        return nil
    }

    /// Find word boundary in text.
    /// - Parameter text: The text to search
    /// - Returns: Character index of word boundary, or nil if not found
    private func findWordBoundary(in text: String) -> Int? {
        // Look for space or newline
        var searchIndex = text.endIndex

        // Search backwards from the end
        while searchIndex > text.startIndex {
            searchIndex = text.index(before: searchIndex)
            let char = text[searchIndex]

            if char.isWhitespace || char.isNewline {
                // Found word boundary - return position after the whitespace
                var endIndex = text.index(after: searchIndex)
                // Skip any additional whitespace
                while endIndex < text.endIndex && (text[endIndex].isWhitespace || text[endIndex].isNewline) {
                    endIndex = text.index(after: endIndex)
                }
                return text.distance(from: text.startIndex, to: endIndex)
            }
        }

        return nil
    }
}


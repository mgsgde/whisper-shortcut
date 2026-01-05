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
class TextChunker {
    /// Maximum characters per chunk. Default: 5000
    let chunkSize: Int

    /// Initialize with custom chunk size.
    /// - Parameter chunkSize: Maximum characters per chunk (default: 5000)
    init(chunkSize: Int = AppConstants.ttsChunkSizeChars) {
        self.chunkSize = chunkSize
    }

    /// Determine if text needs chunking.
    /// - Parameter text: The text to check
    /// - Returns: True if the text should be chunked
    func needsChunking(_ text: String) -> Bool {
        let needsChunking = text.count > AppConstants.ttsChunkingThresholdChars
        if needsChunking {
            DebugLogger.log("TTS-CHUNKER: Text needs chunking (length: \(text.count) chars, threshold: \(AppConstants.ttsChunkingThresholdChars))")
        } else {
            DebugLogger.logDebug("TTS-CHUNKER: Text does not need chunking (length: \(text.count) chars, threshold: \(AppConstants.ttsChunkingThresholdChars))")
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

        DebugLogger.log("TTS-CHUNKER: Starting text split (text length: \(trimmedText.count) chars, chunk size: \(chunkSize))")

        // If text is short enough, return as single chunk
        if trimmedText.count <= chunkSize {
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

            // If remaining text fits in one chunk, add it and finish
            if remainingLength <= chunkSize {
                chunks.append(TextChunk(
                    text: remainingText,
                    index: chunkIndex,
                    startIndex: currentIndex,
                    endIndex: trimmedText.count
                ))
                break
            }

            // Find the best split point within chunkSize
            let chunkEnd = findBestSplitPoint(
                in: remainingText,
                maxLength: chunkSize,
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
    /// - Parameters:
    ///   - text: The text to search in
    ///   - maxLength: Maximum length for the chunk
    ///   - startOffset: The starting offset in the original text
    /// - Returns: The best split point (character index)
    private func findBestSplitPoint(in text: String, maxLength: Int, startOffset: Int) -> Int {
        // Ensure we don't exceed the text length
        let searchLength = min(maxLength, text.count)
        
        guard searchLength > 0 else {
            return startOffset
        }

        let searchRange = text.startIndex..<text.index(text.startIndex, offsetBy: searchLength)
        let searchText = String(text[searchRange])

        // Try to find sentence boundary (., !, ? followed by space or newline)
        if let sentenceEnd = findSentenceBoundary(in: searchText) {
            DebugLogger.logDebug("TTS-CHUNKER: Found sentence boundary at position \(startOffset + sentenceEnd)")
            return startOffset + sentenceEnd
        }

        // Fallback: find word boundary (space or newline)
        if let wordEnd = findWordBoundary(in: searchText) {
            DebugLogger.logDebug("TTS-CHUNKER: Found word boundary at position \(startOffset + wordEnd)")
            return startOffset + wordEnd
        }

        // Last resort: split at character limit
        DebugLogger.logDebug("TTS-CHUNKER: No boundary found, splitting at character limit \(startOffset + searchLength)")
        return startOffset + searchLength
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


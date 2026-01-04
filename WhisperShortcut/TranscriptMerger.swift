//
//  TranscriptMerger.swift
//  WhisperShortcut
//
//  Merges chunk transcripts with overlap deduplication.
//

import Foundation

/// Represents a transcribed chunk with timing information.
struct ChunkTranscript {
    /// Transcribed text from this chunk.
    let text: String
    /// Zero-based index of this chunk in the sequence.
    let index: Int
    /// Start time in the original audio (seconds).
    let startTime: TimeInterval
    /// End time in the original audio (seconds).
    let endTime: TimeInterval
}

/// Merges transcripts from multiple chunks into a single coherent text.
class TranscriptMerger {
    /// Minimum number of words to check for overlap detection.
    private static let minOverlapWords = 3

    /// Maximum number of words to check for overlap at chunk boundaries.
    private static let maxOverlapWords = 15

    /// Merge multiple chunk transcripts into a single text.
    /// - Parameter transcripts: Array of chunk transcripts (will be sorted by index)
    /// - Returns: Merged transcript text
    static func merge(_ transcripts: [ChunkTranscript]) -> String {
        guard !transcripts.isEmpty else { return "" }

        // Sort by index to ensure correct order
        let sorted = transcripts.sorted { $0.index < $1.index }

        guard sorted.count > 1 else {
            return sorted[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var result = sorted[0].text.trimmingCharacters(in: .whitespacesAndNewlines)

        for i in 1..<sorted.count {
            let currentText = sorted[i].text.trimmingCharacters(in: .whitespacesAndNewlines)

            if currentText.isEmpty {
                continue
            }

            // Try to find and remove overlapping text
            if let deduplicatedText = removeOverlap(previous: result, current: currentText) {
                if !deduplicatedText.isEmpty {
                    result += " " + deduplicatedText
                }
            } else {
                // No overlap found, just append with space
                result += " " + currentText
            }
        }

        return normalizeWhitespace(result)
    }

    /// Remove overlapping text between the end of previous and start of current.
    /// - Parameters:
    ///   - previous: The accumulated text so far
    ///   - current: The new chunk's text
    /// - Returns: The current text with overlap removed, or nil if no overlap found
    private static func removeOverlap(previous: String, current: String) -> String? {
        let previousWords = previous.split(separator: " ").map(String.init)
        let currentWords = current.split(separator: " ").map(String.init)

        guard previousWords.count >= minOverlapWords,
              currentWords.count >= minOverlapWords else {
            return nil
        }

        // Look at the last N words of previous text
        let checkWords = min(maxOverlapWords, previousWords.count)
        let previousSuffix = Array(previousWords.suffix(checkWords))

        // Try to find where current text starts matching the end of previous
        for overlapLength in stride(from: min(checkWords, currentWords.count), through: minOverlapWords, by: -1) {
            let previousEnd = Array(previousSuffix.suffix(overlapLength))
            let currentStart = Array(currentWords.prefix(overlapLength))

            // Compare words (case-insensitive, ignoring punctuation at boundaries)
            if wordsMatch(previousEnd, currentStart) {
                // Found overlap - return current text without the overlapping part
                let remaining = Array(currentWords.dropFirst(overlapLength))
                if remaining.isEmpty {
                    return ""
                }
                return remaining.joined(separator: " ")
            }
        }

        return nil
    }

    /// Compare two word arrays for similarity (handles punctuation and case differences).
    private static func wordsMatch(_ words1: [String], _ words2: [String]) -> Bool {
        guard words1.count == words2.count else { return false }

        for (w1, w2) in zip(words1, words2) {
            let clean1 = cleanWord(w1)
            let clean2 = cleanWord(w2)

            // Allow for slight differences (transcription variations)
            if clean1.lowercased() != clean2.lowercased() {
                return false
            }
        }

        return true
    }

    /// Clean a word by removing leading/trailing punctuation.
    private static func cleanWord(_ word: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        return word.trimmingCharacters(in: punctuation)
    }

    /// Normalize whitespace in the final text.
    private static func normalizeWhitespace(_ text: String) -> String {
        // Replace multiple spaces with single space
        let components = text.components(separatedBy: .whitespaces)
        return components.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Merge transcripts, returning partial result if some chunks failed.
    /// - Parameters:
    ///   - transcripts: Successfully transcribed chunks
    ///   - failedIndices: Indices of chunks that failed
    /// - Returns: Merged text with markers for failed chunks
    static func mergeWithGaps(_ transcripts: [ChunkTranscript], failedIndices: [Int]) -> String {
        guard !transcripts.isEmpty else {
            return ""
        }

        // Sort by index
        let sorted = transcripts.sorted { $0.index < $1.index }
        let failedSet = Set(failedIndices)

        var result = ""
        var lastIndex = -1

        for transcript in sorted {
            // Check if there's a gap (failed chunk) before this one
            if transcript.index > lastIndex + 1 {
                let gapStart = lastIndex + 1
                let gapEnd = transcript.index - 1
                for gapIndex in gapStart...gapEnd {
                    if failedSet.contains(gapIndex) {
                        if !result.isEmpty {
                            result += " "
                        }
                        result += "[chunk \(gapIndex + 1) failed]"
                    }
                }
            }

            // Add this transcript
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if !result.isEmpty {
                    result += " "
                }
                result += text
            }

            lastIndex = transcript.index
        }

        return normalizeWhitespace(result)
    }
}

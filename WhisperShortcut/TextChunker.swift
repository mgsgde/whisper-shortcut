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
        while currentIndex < trimmedText.count {
            // Indices follow appended chunks only: a skipped whitespace-only span must not leave a
            // gap, or `PlaybackOrderGate` waits forever for the missing index.
            let chunkIndex = chunks.count
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

            // Find the best split point. May overshoot this chunk's cap to finish a
            // sentence, but never past `chunkSize`.
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
        }

        DebugLogger.log("TTS-CHUNKER: Split text into \(chunks.count) chunks (total: \(trimmedText.count) chars)")
        for (idx, chunk) in chunks.enumerated() {
            DebugLogger.logDebug("TTS-CHUNKER: Chunk \(idx): \(chunk.text.count) chars")
        }
        return chunks
    }

    /// Where a reader would pause. Positions are indexes into `Array(text)` (the remaining
    /// text), after the punctuation and the whitespace that follows it.
    ///
    /// `cap` is this chunk's ramp cap, `hardMax` is `chunkSize` (never exceeded). The first
    /// matching rule wins:
    /// 1. Last sentence end in `[minLength, cap]`.
    /// 2. First sentence end in `(cap, min(hardMax, cap * 1.5)]` — finish the sentence.
    /// 3. Last sentence end in `[floor, minLength)` where `floor` is 25% of `cap`.
    /// 4. Last clause break in `[floor, cap]` (`;` / `:` plus whitespace, or a spaced dash).
    /// 5. Last comma plus whitespace in `[floor, cap]`.
    /// 6. Last whitespace in `[floor, cap]`.
    /// 7. Hard cut at `cap`.
    private func findBestSplitPoint(in text: String, maxLength: Int, minLength: Int, startOffset: Int) -> Int {
        let chars = Array(text)
        let cap = maxLength
        let hardMax = chunkSize
        let floor = Int(Double(cap) * 0.25)

        guard cap > 0, !chars.isEmpty else {
            return startOffset
        }

        let overshootLimit = min(hardMax, Int(Double(cap) * 1.5))
        let sentenceEnds = sentenceSplitPositions(in: chars, maxPosition: overshootLimit)

        if let position = sentenceEnds.last(where: { $0 >= minLength && $0 <= cap }) {
            return loggedSplit("sentence", startOffset + position)
        }
        if let position = sentenceEnds.first(where: { $0 > cap && $0 <= overshootLimit }) {
            return loggedSplit("overshoot", startOffset + position)
        }
        if let position = sentenceEnds.last(where: { $0 >= floor && $0 < minLength }) {
            return loggedSplit("sentence-early", startOffset + position)
        }
        if let position = lastClauseSplit(in: chars, floor: floor, cap: cap) {
            return loggedSplit("clause", startOffset + position)
        }
        if let position = lastCommaSplit(in: chars, floor: floor, cap: cap) {
            return loggedSplit("comma", startOffset + position)
        }
        if let position = lastWhitespaceSplit(in: chars, floor: floor, cap: cap) {
            return loggedSplit("whitespace", startOffset + position)
        }

        let hard = min(cap, chars.count)
        return loggedSplit("hard", startOffset + max(hard, 1))
    }

    private func loggedSplit(_ rule: String, _ position: Int) -> Int {
        DebugLogger.logDebug("TTS-CHUNKER: split rule=\(rule) at \(position)")
        return position
    }

    /// Split positions after `.` `!` `?` `…`, optional closing quotes or brackets, and the
    /// whitespace that follows. A `.` after an abbreviation or an ordinal number is not an end.
    private func sentenceSplitPositions(in chars: [Character], maxPosition: Int) -> [Int] {
        let endings: Set<Character> = [".", "!", "?", "\u{2026}"]
        var positions: [Int] = []
        var index = 0
        while index < chars.count && index < maxPosition {
            let char = chars[index]
            let isAbbreviation = char == "." && isAbbreviationDot(chars, dotIndex: index)
            if endings.contains(char) && !isAbbreviation {
                var cursor = index + 1
                while cursor < chars.count && Self.sentenceClosers.contains(chars[cursor]) {
                    cursor += 1
                }
                if cursor >= chars.count || chars[cursor].isWhitespace {
                    while cursor < chars.count && chars[cursor].isWhitespace {
                        cursor += 1
                    }
                    if cursor <= maxPosition {
                        positions.append(cursor)
                        index = cursor
                        continue
                    }
                    break
                }
            }
            index += 1
        }
        return positions
    }

    /// `.` does not end a sentence when the token before it is one letter (`z. B.`, `d. h.`),
    /// a pure number (`am 3. Oktober`), or a known abbreviation.
    private func isAbbreviationDot(_ chars: [Character], dotIndex: Int) -> Bool {
        guard dotIndex > 0 else { return false }

        var immediate = ""
        var index = dotIndex - 1
        while index >= 0 && (chars[index].isLetter || chars[index].isNumber) {
            immediate.insert(chars[index], at: immediate.startIndex)
            index -= 1
        }
        if immediate.count == 1 && immediate.first?.isLetter == true {
            return true
        }
        if !immediate.isEmpty && immediate.allSatisfy(\.isNumber) {
            return true
        }

        var extended = ""
        index = dotIndex - 1
        while index >= 0 && (chars[index].isLetter || chars[index].isNumber || chars[index] == ".") {
            extended.insert(chars[index], at: extended.startIndex)
            index -= 1
        }
        let loweredImmediate = immediate.lowercased()
        let loweredExtended = extended.lowercased()
        return Self.abbreviations.contains(loweredImmediate) || Self.abbreviations.contains(loweredExtended)
    }

    /// Last `;` or `:` followed by whitespace, or the index of a spaced en/em dash, inside
    /// `[floor, cap]`. A dash split leaves the dash at the start of the next chunk.
    private func lastClauseSplit(in chars: [Character], floor: Int, cap: Int) -> Int? {
        var best: Int?
        var index = 0
        while index < chars.count && index <= cap {
            let char = chars[index]
            if char == ";" || char == ":" {
                var cursor = index + 1
                if cursor < chars.count && chars[cursor].isWhitespace {
                    while cursor < chars.count && chars[cursor].isWhitespace {
                        cursor += 1
                    }
                    if cursor >= floor && cursor <= cap {
                        best = cursor
                    }
                }
            } else if Self.spacedDashes.contains(char)
                        && index > 0
                        && index + 1 < chars.count
                        && chars[index - 1].isWhitespace
                        && chars[index + 1].isWhitespace
                        && index >= floor
                        && index <= cap {
                best = index
            }
            index += 1
        }
        return best
    }

    /// Last comma followed by whitespace whose split position falls in `[floor, cap]`.
    private func lastCommaSplit(in chars: [Character], floor: Int, cap: Int) -> Int? {
        var best: Int?
        var index = 0
        while index < chars.count && index < cap {
            if chars[index] == "," {
                var cursor = index + 1
                if cursor < chars.count && chars[cursor].isWhitespace {
                    while cursor < chars.count && chars[cursor].isWhitespace {
                        cursor += 1
                    }
                    if cursor >= floor && cursor <= cap {
                        best = cursor
                    }
                }
            }
            index += 1
        }
        return best
    }

    /// Last whitespace run whose end falls in `[floor, cap]`.
    private func lastWhitespaceSplit(in chars: [Character], floor: Int, cap: Int) -> Int? {
        var best: Int?
        var index = 0
        while index < chars.count && index < cap {
            if chars[index].isWhitespace {
                var cursor = index + 1
                while cursor < chars.count && chars[cursor].isWhitespace {
                    cursor += 1
                }
                if cursor >= floor && cursor <= cap {
                    best = cursor
                }
                if cursor > cap {
                    break
                }
                index = cursor
                continue
            }
            index += 1
        }
        return best
    }

    private static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "bzw", "ca", "etc", "usw", "vgl",
        "nr", "evtl", "inkl", "ggf", "e.g", "i.e", "vs", "st"
    ]

    private static let sentenceClosers: Set<Character> = [
        "\"", "\u{201D}", "\u{201C}", "\u{00BB}", "\u{00AB}", "'", "\u{2019}", ")", "]"
    ]

    private static let spacedDashes: Set<Character> = ["\u{2013}", "\u{2014}"]
}


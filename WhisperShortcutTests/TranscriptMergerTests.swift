import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Overlap dedup for chunked / streaming dictation. A missed overlap pastes the same phrase
/// twice; a false overlap drops real words. Neither shows up as an API error.
@Suite("TranscriptMerger")
struct TranscriptMergerTests {

  private func chunk(_ text: String, index: Int, start: TimeInterval = 0, end: TimeInterval = 1)
    -> ChunkTranscript
  {
    ChunkTranscript(text: text, index: index, startTime: start, endTime: end)
  }

  private struct MergeCase: Sendable {
    let chunks: [(String, Int)]
    let expected: String
    let label: String
  }

  @Test(
    "Merge dedups overlapping tails, sorts by index, skips empties and normalizes spaces",
    arguments: [
      MergeCase(chunks: [], expected: "", label: "empty list merges to empty string"),
      MergeCase(chunks: [("  hello world  ", 0)], expected: "hello world", label: "single chunk is trimmed"),
      MergeCase(
        chunks: [("hello there", 0), ("next sentence starts here", 1)],
        expected: "hello there next sentence starts here", label: "no shared tail joins with a space"),
      MergeCase(
        chunks: [("hello world this is a test", 0), ("this is a test of the system", 1)],
        expected: "hello world this is a test of the system", label: "3+ word shared tail is dropped"),
      MergeCase(
        chunks: [("one two three four.", 0), ("Two Three Four five six", 1)],
        expected: "one two three four. five six", label: "overlap ignores case and boundary punctuation"),
      // Both sides need >=3 words for the overlap scan. "there friend" is only two,
      // so the repeated "there" must survive rather than being guessed away.
      MergeCase(
        chunks: [("hi there", 0), ("there friend", 1)],
        expected: "hi there there friend", label: "overlap shorter than three words is kept"),
      MergeCase(
        chunks: [("keep this", 0), ("   ", 1), ("and this", 2)],
        expected: "keep this and this", label: "empty later chunk is skipped"),
      MergeCase(
        chunks: [("second half of the sentence", 1), ("first half of the sentence", 0)],
        expected: "first half of the sentence second half of the sentence",
        label: "chunks sorted by index before merging"),
      MergeCase(
        chunks: [("one two three four", 0), ("two three four", 1)],
        expected: "one two three four", label: "later chunk that is only the previous tail adds nothing"),
      // Overlap detection needs >=3 shared words, so each window repeats a 3-word tail.
      MergeCase(
        chunks: [("the quick brown fox jumps", 0), ("brown fox jumps over the", 1), ("jumps over the lazy dog", 2)],
        expected: "the quick brown fox jumps over the lazy dog", label: "three overlapping windows collapse"),
      MergeCase(
        chunks: [("hello    world", 0), ("next    words here", 1)],
        expected: "hello world next words here", label: "runs of spaces collapse to one"),
    ])
  private func merges(_ c: MergeCase) {
    let merged = TranscriptMerger.merge(c.chunks.map { chunk($0.0, index: $0.1) })
    #expect(merged == c.expected, "\(c.label)")
  }
}

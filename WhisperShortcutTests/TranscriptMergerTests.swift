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

  @Test("An empty list merges to an empty string")
  func emptyInput() {
    #expect(TranscriptMerger.merge([]) == "")
  }

  @Test("A single chunk is trimmed and otherwise unchanged")
  func singleChunkIsTrimmed() {
    #expect(
      TranscriptMerger.merge([chunk("  hello world  ", index: 0)])
        == "hello world")
  }

  @Test("Chunks with no shared tail are joined with a single space")
  func noOverlapJoinsWithSpace() {
    let merged = TranscriptMerger.merge([
      chunk("hello there", index: 0),
      chunk("next sentence starts here", index: 1),
    ])
    #expect(merged == "hello there next sentence starts here")
  }

  @Test("A shared tail of at least three words is dropped from the next chunk")
  func exactWordOverlapIsDeduped() {
    let merged = TranscriptMerger.merge([
      chunk("hello world this is a test", index: 0),
      chunk("this is a test of the system", index: 1),
    ])
    #expect(merged == "hello world this is a test of the system")
  }

  @Test("Overlap matching is case-insensitive and ignores boundary punctuation")
  func overlapIgnoresCaseAndPunctuation() {
    let merged = TranscriptMerger.merge([
      chunk("one two three four.", index: 0),
      chunk("Two Three Four five six", index: 1),
    ])
    #expect(merged == "one two three four. five six")
  }

  @Test("An overlap shorter than three words is not treated as a duplicate")
  func shortOverlapIsKept() {
    // Both sides need ≥3 words for the overlap scan. "there friend" is only two,
    // so the repeated "there" must survive rather than being guessed away.
    let merged = TranscriptMerger.merge([
      chunk("hi there", index: 0),
      chunk("there friend", index: 1),
    ])
    #expect(merged == "hi there there friend")
  }

  @Test("An empty later chunk is skipped")
  func emptyChunkIsSkipped() {
    let merged = TranscriptMerger.merge([
      chunk("keep this", index: 0),
      chunk("   ", index: 1),
      chunk("and this", index: 2),
    ])
    #expect(merged == "keep this and this")
  }

  @Test("Chunks are sorted by index before merging")
  func outOfOrderChunksAreSorted() {
    let merged = TranscriptMerger.merge([
      chunk("second half of the sentence", index: 1),
      chunk("first half of the sentence", index: 0),
    ])
    #expect(merged == "first half of the sentence second half of the sentence")
  }

  @Test("A later chunk that is only the previous tail adds nothing")
  func completeOverlapAddsNothing() {
    let merged = TranscriptMerger.merge([
      chunk("one two three four", index: 0),
      chunk("two three four", index: 1),
    ])
    #expect(merged == "one two three four")
  }

  @Test("Three overlapping windows collapse to one sentence")
  func threeWindows() {
    // Overlap detection needs ≥3 shared words, so each window repeats a 3-word tail.
    let merged = TranscriptMerger.merge([
      chunk("the quick brown fox jumps", index: 0),
      chunk("brown fox jumps over the", index: 1),
      chunk("jumps over the lazy dog", index: 2),
    ])
    #expect(merged == "the quick brown fox jumps over the lazy dog")
  }

  @Test("Runs of spaces in the joined result collapse to one")
  func whitespaceIsNormalized() {
    let merged = TranscriptMerger.merge([
      chunk("hello    world", index: 0),
      chunk("next    words here", index: 1),
    ])
    #expect(merged == "hello world next words here")
  }
}

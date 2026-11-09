import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// A summary written before audio was added to the transcript (resume, late chunk, recovered
/// backlog) must be recognised as stale; one without a sidecar must not be regenerated.
@Suite("Meeting summary meta")
struct MeetingSummaryMetaTests {
  private let transcript = "[00:00] Hello\n\n[01:00] World\n\n"

  @Test("Meta counts chunks and records the last start")
  func metaCountsChunksAndLastStart() {
    let meta = MeetingListService.summaryMeta(forTranscript: transcript)
    #expect(meta == MeetingListService.SummaryMeta(chunkCount: 2, lastChunkStart: 60))
  }

  @Test("A summary without meta counts as matching")
  func noMetaMatches() {
    #expect(MeetingListService.summaryMatches(meta: nil, transcript: transcript))
  }

  @Test("An unchanged transcript matches")
  func unchangedMatches() {
    let meta = MeetingListService.summaryMeta(forTranscript: transcript)
    #expect(MeetingListService.summaryMatches(meta: meta, transcript: transcript))
  }

  @Test("An appended chunk makes the summary stale")
  func appendedChunkIsStale() {
    let meta = MeetingListService.summaryMeta(forTranscript: transcript)
    #expect(!MeetingListService.summaryMatches(meta: meta, transcript: transcript + "[02:00] More\n\n"))
  }

  @Test("A chunk spliced in before the last one makes the summary stale")
  func splicedChunkIsStale() {
    let meta = MeetingListService.summaryMeta(forTranscript: transcript)
    let spliced = "[00:00] Hello\n\n[00:30] Late\n\n[01:00] World\n\n"
    #expect(!MeetingListService.summaryMatches(meta: meta, transcript: spliced))
  }

  @Test("Meta round-trips as JSON")
  func roundTrip() throws {
    let meta = MeetingListService.SummaryMeta(chunkCount: 3, lastChunkStart: 125)
    let data = try JSONEncoder().encode(meta)
    #expect(try JSONDecoder().decode(MeetingListService.SummaryMeta.self, from: data) == meta)
  }

  @Test("Meta from the chunks a summary was built from flags a transcript that grew meanwhile")
  func metaFromSourceChunksFlagsLaterGrowth() {
    let source = LiveMeetingTranscriptStore.parseTranscript(transcript)
    let meta = MeetingListService.summaryMeta(forChunks: source)
    #expect(meta == MeetingListService.summaryMeta(forTranscript: transcript))
    let grown = transcript + "[02:00] Arrived during generation\n\n"
    #expect(!MeetingListService.summaryMatches(meta: meta, transcript: grown))
  }
}

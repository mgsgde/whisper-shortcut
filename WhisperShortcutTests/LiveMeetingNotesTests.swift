import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Covers the two pure functions the live-note stream depends on. Both fail silently when wrong:
/// a broken round-trip loses every note of a reopened meeting without an error anywhere, and a
/// broken bullet parser turns a good model response into an empty note that is never retried
/// (the segment counts as covered either way).
@Suite("Live meeting notes")
struct LiveMeetingNotesTests {

  @Test("Notes survive a write/read round-trip")
  func notesRoundTrip() {
    let notes = [
      LiveMeetingNote(startTime: 0, bullets: ["Kickoff, everyone introduced themselves"]),
      LiveMeetingNote(startTime: 754, bullets: ["Pricing tiers debated", "No decision yet"]),
      LiveMeetingNote(startTime: 900, bullets: ["Budget owner agreed"]),
    ]

    let parsed = LiveMeetingTranscriptStore.parseNotes(
      LiveMeetingTranscriptStore.notesMarkdown(notes))

    #expect(parsed.count == 3)
    #expect(parsed.map(\.startTime) == [0, 754, 900])
    #expect(parsed[1].bullets == ["Pricing tiers debated", "No decision yet"])
    #expect(parsed[2].bullets == ["Budget owner agreed"])
  }

  @Test("A legacy flagged-moment header (with the old ★) reads as an ordinary note")
  func legacyStarHeaderParsesAsNote() {
    let text = "## [00:10]\n- Intro\n\n## ★ [01:05]\n- Flagged by me\n"
    let parsed = LiveMeetingTranscriptStore.parseNotes(text)
    #expect(parsed.count == 2)
    #expect(parsed[1].startTime == 65)
    #expect(parsed[1].bullets == ["Flagged by me"])
    // Writing never emits the ★ again.
    #expect(!LiveMeetingTranscriptStore.notesMarkdown(parsed).contains("★"))
  }

  @Test("Timestamps past 99 minutes round-trip (long meetings)")
  func longMeetingTimestamps() {
    let notes = [LiveMeetingNote(startTime: 7_265, bullets: ["Still going"])]
    let parsed = LiveMeetingTranscriptStore.parseNotes(
      LiveMeetingTranscriptStore.notesMarkdown(notes))
    #expect(parsed.first?.startTime == 7_265)
  }

  @Test("Empty note list produces nothing to parse back")
  func emptyNotes() {
    #expect(LiveMeetingTranscriptStore.parseNotes("").isEmpty)
  }

  @Test("Bullet responses are parsed and capped at two")
  func parsesBullets() {
    let raw = "- Budget approved\n- Hiring paused\n- Third thing the prompt forbade"
    #expect(LiveMeetingSession.parseBullets(raw) == ["Budget approved", "Hiring paused"])
  }

  @Test("Alternative bullet glyphs are accepted")
  func parsesAlternativeBulletGlyphs() {
    #expect(LiveMeetingSession.parseBullets("• Roadmap slipped") == ["Roadmap slipped"])
    #expect(LiveMeetingSession.parseBullets("* Roadmap slipped") == ["Roadmap slipped"])
  }

  @Test("A single unbulleted line is accepted, a paragraph dump is not")
  func toleratesUnbulletedSingleLine() {
    #expect(LiveMeetingSession.parseBullets("Roadmap slipped by two weeks") == ["Roadmap slipped by two weeks"])
    #expect(LiveMeetingSession.parseBullets("First line\nSecond line").isEmpty)
    #expect(LiveMeetingSession.parseBullets(String(repeating: "x", count: 400)).isEmpty)
  }

  @Test("An empty response yields no bullets — the prompt allows staying silent")
  func emptyResponseYieldsNoBullets() {
    #expect(LiveMeetingSession.parseBullets("").isEmpty)
    #expect(LiveMeetingSession.parseBullets("\n  \n").isEmpty)
  }
}

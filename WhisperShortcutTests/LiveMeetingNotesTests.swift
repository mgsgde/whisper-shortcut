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

  @Test("Bullet responses are parsed, capped, or rejected", arguments: [
    ("- Budget approved\n- Hiring paused\n- Third thing the prompt forbade",
     ["Budget approved", "Hiring paused"], "capped at two"),
    ("• Roadmap slipped", ["Roadmap slipped"], "bullet glyph"),
    ("* Roadmap slipped", ["Roadmap slipped"], "asterisk"),
    ("Roadmap slipped by two weeks", ["Roadmap slipped by two weeks"], "unbulleted single line"),
    ("First line\nSecond line", [] as [String], "paragraph dump is not accepted"),
    (String(repeating: "x", count: 400), [], "overlong unbulleted line"),
    ("", [], "empty response"),
    ("\n  \n", [], "whitespace-only response"),
  ])
  func parseBullets(raw: String, expected: [String], label: String) {
    #expect(LiveMeetingSession.parseBullets(raw) == expected, "\(label)")
  }

  // MARK: - Hand edits

  @Test("A note emptied of bullets disappears instead of leaving a blank header")
  func emptiedNoteDisappears() {
    let notes = [
      LiveMeetingNote(startTime: 0, bullets: ["Kickoff"]),
      LiveMeetingNote(startTime: 754, bullets: ["Pricing tiers debated"]),
    ]
    let emptied = LiveMeetingTranscriptStore.applyingEdit(
      to: notes, replacing: LiveMeetingNote(id: notes[1].id, startTime: 754, bullets: []))

    #expect(emptied.count == 1)
    let markdown = LiveMeetingTranscriptStore.notesMarkdown(emptied)
    #expect(!markdown.contains("[12:34]"))
    let parsed = LiveMeetingTranscriptStore.parseNotes(markdown)
    #expect(parsed.count == 1)
    #expect(parsed[0].bullets == ["Kickoff"])
  }

  @Test("Editing one note leaves the others untouched and in order")
  func editingOneNoteKeepsTheRest() {
    let notes = [
      LiveMeetingNote(startTime: 0, bullets: ["Kickoff"]),
      LiveMeetingNote(startTime: 754, bullets: ["Pricing tiers debated"]),
      LiveMeetingNote(startTime: 900, bullets: ["Budget owner agreed"]),
    ]
    let edited = LiveMeetingTranscriptStore.applyingEdit(
      to: notes,
      replacing: LiveMeetingNote(id: notes[1].id, startTime: 754, bullets: ["Pricing settled"]))

    #expect(edited.map(\.startTime) == [0, 754, 900])
    #expect(edited.map(\.bullets) == [["Kickoff"], ["Pricing settled"], ["Budget owner agreed"]])
    #expect(edited[0].id == notes[0].id)
    #expect(edited[1].id == notes[1].id)
    #expect(edited[2].id == notes[2].id)

    let parsed = LiveMeetingTranscriptStore.parseNotes(
      LiveMeetingTranscriptStore.notesMarkdown(edited))
    #expect(parsed.map(\.startTime) == [0, 754, 900])
    #expect(parsed[1].bullets == ["Pricing settled"])
  }

  @Test("Editor text becomes one bullet per non-empty line, typed markers stripped")
  func draftBecomesBullets() {
    #expect(
      LiveMeetingTranscriptStore.bullets(fromDraft: "First point\n\n  - Second point  \n• Third\n")
        == ["First point", "Second point", "Third"])
    #expect(LiveMeetingTranscriptStore.bullets(fromDraft: "   \n\n").isEmpty)
  }
}

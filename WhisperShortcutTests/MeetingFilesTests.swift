import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// One meeting's files and the on-disk transcript format. A wrong move would orphan a summary when
/// a meeting is named, and a wrong timestamp would put a recovered chunk at the wrong second.
@Suite("Meeting files and transcript format")
struct MeetingFilesTests {

  @Test("Chunks round-trip through the transcript format, including minutes past 99")
  func roundTrip() {
    let chunks = [
      LiveMeetingChunk(startTime: 0, text: "one"),
      LiveMeetingChunk(startTime: 65, text: "two\nlines"),
      LiveMeetingChunk(startTime: 3725, text: "past an hour"),
    ]
    let parsed = MeetingTranscriptFormat.parse(MeetingTranscriptFormat.text(chunks))
    #expect(parsed.map(\.startTime) == chunks.map(\.startTime))
    #expect(parsed.map(\.text) == chunks.map(\.text))
    #expect(MeetingTranscriptFormat.text(chunks).contains("[62:05] past an hour"))
  }

  @Test("Timestamp and block match the bytes appendToTranscript writes")
  func timestampAndBlock() {
    #expect(MeetingTranscriptFormat.timestamp(135) == "[02:15]")
    #expect(MeetingTranscriptFormat.block(startTime: 5, text: "hi") == "[00:05] hi\n\n")
  }

  @Test("Stem dates round-trip to the whole second; a named stem does not parse")
  func stemDate() {
    let d = Date(timeIntervalSince1970: 1_775_000_000.9)
    let parsed = MeetingTranscriptFormat.date(fromStem: MeetingTranscriptFormat.newStem(at: d))
    let truncated = Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down))
    #expect(parsed == truncated)
    #expect(MeetingTranscriptFormat.date(fromStem: "Meeting-2026-03-04-143000-Standup") == nil)
  }

  @Test("move(toStem:) moves transcript, notes and summary")
  func moveAllFiles() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = MeetingFiles(transcript: dir.appendingPathComponent("Meeting-2026-01-01-100000.txt"))
    try "transcript".write(to: files.transcript, atomically: true, encoding: .utf8)
    try "notes".write(to: files.notes, atomically: true, encoding: .utf8)
    try "summary".write(to: files.summary, atomically: true, encoding: .utf8)

    let moved = try files.move(toStem: "Meeting-2026-01-01-100000-Standup")

    #expect(moved.transcript.lastPathComponent == "Meeting-2026-01-01-100000-Standup.txt")
    #expect(moved.transcript.deletingLastPathComponent() == dir)
    #expect(try String(contentsOf: moved.transcript, encoding: .utf8) == "transcript")
    #expect(try String(contentsOf: moved.notes, encoding: .utf8) == "notes")
    #expect(try String(contentsOf: moved.summary, encoding: .utf8) == "summary")
    #expect(!FileManager.default.fileExists(atPath: files.transcript.path))
    #expect(!FileManager.default.fileExists(atPath: files.notes.path))
    #expect(!FileManager.default.fileExists(atPath: files.summary.path))
  }

  @Test("move(toStem:) with only the transcript present does not throw")
  func moveTranscriptOnly() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = MeetingFiles(transcript: dir.appendingPathComponent("Meeting-2026-01-01-100000.txt"))
    try "transcript".write(to: files.transcript, atomically: true, encoding: .utf8)

    let moved = try files.move(toStem: "Meeting-2026-01-01-100000-Only")

    #expect(try String(contentsOf: moved.transcript, encoding: .utf8) == "transcript")
    #expect(!FileManager.default.fileExists(atPath: moved.notes.path))
    #expect(!FileManager.default.fileExists(atPath: moved.summary.path))
    #expect(!FileManager.default.fileExists(atPath: files.transcript.path))
  }

  @Test("removeAll() deletes transcript, notes and summary")
  func removeAll() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = MeetingFiles(transcript: dir.appendingPathComponent("Meeting-2026-01-01-100000.txt"))
    try "t".write(to: files.transcript, atomically: true, encoding: .utf8)
    try "n".write(to: files.notes, atomically: true, encoding: .utf8)
    try "s".write(to: files.summary, atomically: true, encoding: .utf8)

    files.removeAll()

    for url in files.all {
      #expect(!FileManager.default.fileExists(atPath: url.path))
    }
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("MeetingFilesTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}

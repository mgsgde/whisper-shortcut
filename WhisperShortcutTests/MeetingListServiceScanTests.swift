import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Covers `MeetingListService.scan`, the pure directory scan shared with the MCP meeting tools
/// (R83) — used to be reimplemented separately there with a different sort key, no title trim
/// and no hidden-file skip.
@Suite("MeetingListService.scan")
struct MeetingListServiceScanTests {

  private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-scan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func write(_ dir: URL, _ name: String, _ text: String = "") throws {
    try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  @Test("Skips hidden files and non-matching filenames, trims titles, sorts newest first")
  func scanFixture() throws {
    let dir = try makeDir()
    try write(dir, "Meeting-2026-10-18-090000-  Budget Review  .txt", "[00:00] hi\n")
    try write(dir, "Meeting-2026-10-19-110109.txt", "[00:00] hi\n")
    try write(dir, ".Meeting-2026-10-20-120000-Hidden.txt", "[00:00] hi\n")
    try write(dir, "not-a-meeting.txt", "irrelevant")

    let result = MeetingListService.scan(directory: dir)

    #expect(result.count == 2)
    // Newest first (2026-10-19 before 2026-10-18).
    #expect(result[0].meetingId == "Meeting-2026-10-19-110109")
    #expect(result[1].meetingId == "Meeting-2026-10-18-090000-  Budget Review  ")
    // Title is trimmed; untitled meeting has no title.
    #expect(result[1].title == "Budget Review")
    #expect(result[1].displayLabel == "Budget Review")
    #expect(result[0].title == nil)
  }

  @Test("Missing directory returns an empty list")
  func missingDirectory() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
    #expect(MeetingListService.scan(directory: dir).isEmpty)
  }
}

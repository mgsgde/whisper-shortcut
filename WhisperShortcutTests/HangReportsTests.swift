import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Hang reports")
struct HangReportsTests {

  @Test("No files means no feedback attachment")
  func emptyListProducesNoAttachment() {
    #expect(HangReports.feedbackAttachment(reportURLs: [], newestContents: "unused") == nil)
  }

  @Test("Attachment names the newest recent file and inlines its excerpt")
  func attachmentListsFilesAndExcerpt() throws {
    let newest = URL(fileURLWithPath: "/tmp/hang-20260902-103000.txt")
    let older = URL(fileURLWithPath: "/tmp/hang-20260902-090000.txt")
    let text = HangReports.feedbackAttachment(
      reportURLs: [newest, older],
      newestContents: "WATCHDOG: main thread hang\n0  AppKit",
      now: Self.hangInstant("20260902-103000"))

    let body = try #require(text)
    #expect(body.hasPrefix("App hang in the last 24 hours (hang-20260902-103000.txt, +1 more):"))
    #expect(body.contains("+1 more"))
    #expect(body.contains("WATCHDOG: main thread hang"))
    #expect(!body.contains("Reveal Hang Reports"))
    #expect(!body.contains("attach"))
  }

  @Test("Reports older than 24 hours produce no attachment")
  func oldReportsProduceNoAttachment() {
    let old = URL(fileURLWithPath: "/tmp/hang-20260901-090000.txt")
    let now = Self.hangInstant("20260901-090000").addingTimeInterval(24 * 60 * 60 + 1)
    #expect(HangReports.feedbackAttachment(
      reportURLs: [old],
      newestContents: "WATCHDOG: main thread hang",
      now: now) == nil)
  }

  @Test("A mix keeps only the recent hang, with no extra count for one file")
  func mixedAgesKeepOnlyTheRecentHang() throws {
    let recent = URL(fileURLWithPath: "/tmp/hang-20260902-103000.txt")
    let old = URL(fileURLWithPath: "/tmp/hang-20260901-090000.txt")
    let text = HangReports.feedbackAttachment(
      reportURLs: [recent, old],
      newestContents: "WATCHDOG: main thread hang",
      now: Self.hangInstant("20260902-103000"))

    let body = try #require(text)
    #expect(body.contains("hang-20260902-103000.txt"))
    #expect(!body.contains("hang-20260901-090000.txt"))
    #expect(!body.contains("more"))
    #expect(body.contains("WATCHDOG: main thread hang"))
  }

  private static func hangInstant(_ stamp: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.isLenient = false
    return formatter.date(from: stamp)!
  }

  @Test("existingReportURLs only returns hang-*.txt")
  func filtersToHangTextFiles() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("hang-reports-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    try "hang".write(to: dir.appendingPathComponent("hang-20260902-100000.txt"), atomically: true, encoding: .utf8)
    try "nope".write(to: dir.appendingPathComponent("errors-20260902.log"), atomically: true, encoding: .utf8)
    try "also".write(to: dir.appendingPathComponent("hang-notes.md"), atomically: true, encoding: .utf8)

    let found = HangReports.existingReportURLs(in: dir)
    #expect(found.map(\.lastPathComponent) == ["hang-20260902-100000.txt"])
  }
}

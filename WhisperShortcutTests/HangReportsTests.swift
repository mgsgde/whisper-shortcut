import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Hang reports")
struct HangReportsTests {

  @Test("No files means no feedback attachment")
  func emptyListProducesNoAttachment() {
    #expect(HangReports.feedbackAttachment(reportURLs: [], newestContents: "unused") == nil)
  }

  @Test("Attachment lists filenames and the newest excerpt")
  func attachmentListsFilesAndExcerpt() throws {
    let newest = URL(fileURLWithPath: "/tmp/hang-20260902-103000.txt")
    let older = URL(fileURLWithPath: "/tmp/hang-20260901-090000.txt")
    let text = HangReports.feedbackAttachment(
      reportURLs: [newest, older],
      newestContents: "WATCHDOG: main thread hang\n0  AppKit")

    let body = try #require(text)
    #expect(body.contains("hang-20260902-103000.txt"))
    #expect(body.contains("hang-20260901-090000.txt"))
    #expect(body.contains("Reveal Hang Reports"))
    #expect(body.contains("WATCHDOG: main thread hang"))
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

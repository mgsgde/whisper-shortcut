import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The report file is what the developer actually receives once the message no longer fits in a
/// link, so the name has to be recognizable and last week's drafts must not pile up.
@Suite("Report attachment")
struct ReportAttachmentTests {

  private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("report-attachment-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func stamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: date)
  }

  @Test("The file name comes from now and the contents round-trip")
  func fileNameAndContents() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 1_763_640_000)
    let text = "report body\nsecond line"

    let url = try ReportAttachment.write(text, now: now, directory: dir)

    #expect(url.lastPathComponent == "WhisperShortcut-Report-\(stamp(now)).txt")
    #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
    #expect(try String(contentsOf: url, encoding: .utf8) == text)
  }

  @Test("A file older than 7 days is pruned and a newer one stays")
  func prunesExpiredFiles() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 1_763_640_000)
    let fm = FileManager.default
    let old = dir.appendingPathComponent("old.txt")
    let fresh = dir.appendingPathComponent("fresh.txt")
    try "old".write(to: old, atomically: true, encoding: .utf8)
    try "fresh".write(to: fresh, atomically: true, encoding: .utf8)
    try fm.setAttributes(
      [.modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60)], ofItemAtPath: old.path)
    try fm.setAttributes(
      [.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: fresh.path)

    let url = try ReportAttachment.write("kept", now: now, directory: dir)

    #expect(!fm.fileExists(atPath: old.path))
    #expect(fm.fileExists(atPath: fresh.path))
    #expect(try String(contentsOf: fresh, encoding: .utf8) == "fresh")
    #expect(fm.fileExists(atPath: url.path))
    #expect(try String(contentsOf: url, encoding: .utf8) == "kept")
  }
}

@Suite("Report sender")
struct ReportSenderTests {

  @Test("Only Apple Mail gets the compose service")
  func prefersAppleMail() {
    #expect(ReportSender.prefersAppleMail(mailtoHandlerBundleID: "com.apple.mail"))
    #expect(!ReportSender.prefersAppleMail(mailtoHandlerBundleID: "com.microsoft.Outlook"))
    #expect(!ReportSender.prefersAppleMail(mailtoHandlerBundleID: nil))
  }
}

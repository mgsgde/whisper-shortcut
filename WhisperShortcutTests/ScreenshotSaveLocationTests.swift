import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Screenshot save folder — bookmark failure classification")
struct ScreenshotSaveLocationTests {

  private struct Row: Sendable {
    let note: String
    let error: NSError
    let path: String
    let mounted: @Sendable (String) -> Bool
    let discard: Bool
  }

  private static func cocoa(_ code: Int) -> NSError { NSError(domain: NSCocoaErrorDomain, code: code) }

  private static let rows: [Row] = [
    Row(note: "corrupt bookmark data is discarded", error: cocoa(NSFileReadCorruptFileError),
        path: "/Users/me/Pictures", mounted: { _ in true }, discard: true),
    Row(note: "missing folder on startup disk (read) is discarded", error: cocoa(NSFileReadNoSuchFileError),
        path: "/Users/me/Gone", mounted: { _ in true }, discard: true),
    Row(note: "missing folder on startup disk (generic) is discarded", error: cocoa(NSFileNoSuchFileError),
        path: "/Users/me/Gone", mounted: { _ in true }, discard: true),
    Row(note: "missing folder on unmounted external volume is kept", error: cocoa(NSFileReadNoSuchFileError),
        path: "/Volumes/Backup/Shots", mounted: { _ in false }, discard: false),
    Row(note: "missing folder on mounted external volume is discarded", error: cocoa(NSFileReadNoSuchFileError),
        path: "/Volumes/Backup/Shots", mounted: { $0 == "/Volumes/Backup" }, discard: true),
    Row(note: "no-permission error is transient, keeps bookmark", error: cocoa(NSFileReadNoPermissionError),
        path: "/Users/me/Pictures", mounted: { _ in true }, discard: false),
    Row(note: "POSIX I/O error is transient, keeps bookmark", error: NSError(domain: NSPOSIXErrorDomain, code: 5),
        path: "/Users/me/Pictures", mounted: { _ in true }, discard: false),
  ]

  @Test("shouldDiscardBookmark classifies bookmark failures", arguments: rows)
  private func classifies(_ row: Row) {
    #expect(ScreenshotSaveLocation.shouldDiscardBookmark(
      error: row.error, folderPath: row.path, volumeIsMounted: row.mounted) == row.discard, "\(row.note)")
  }
}

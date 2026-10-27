import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Screenshot save folder — bookmark failure classification")
struct ScreenshotSaveLocationTests {

  private func cocoa(_ code: Int) -> NSError {
    NSError(domain: NSCocoaErrorDomain, code: code)
  }

  @Test("Corrupt bookmark data is discarded")
  func corruptDiscarded() {
    #expect(ScreenshotSaveLocation.shouldDiscardBookmark(
      error: cocoa(NSFileReadCorruptFileError), folderPath: "/Users/me/Pictures", volumeIsMounted: { _ in true }))
  }

  @Test("A folder that no longer exists on the startup disk is discarded")
  func missingFolderDiscarded() {
    #expect(ScreenshotSaveLocation.shouldDiscardBookmark(
      error: cocoa(NSFileReadNoSuchFileError), folderPath: "/Users/me/Gone", volumeIsMounted: { _ in true }))
    #expect(ScreenshotSaveLocation.shouldDiscardBookmark(
      error: cocoa(NSFileNoSuchFileError), folderPath: "/Users/me/Gone", volumeIsMounted: { _ in true }))
  }

  @Test("A missing folder on an unmounted external volume is kept")
  func unmountedVolumeKept() {
    #expect(!ScreenshotSaveLocation.shouldDiscardBookmark(
      error: cocoa(NSFileReadNoSuchFileError), folderPath: "/Volumes/Backup/Shots", volumeIsMounted: { _ in false }))
  }

  @Test("A missing folder on a mounted external volume is discarded")
  func mountedVolumeMissingFolderDiscarded() {
    #expect(ScreenshotSaveLocation.shouldDiscardBookmark(
      error: cocoa(NSFileReadNoSuchFileError), folderPath: "/Volumes/Backup/Shots", volumeIsMounted: { $0 == "/Volumes/Backup" }))
  }

  @Test("Other errors are transient and keep the bookmark")
  func otherErrorsKept() {
    #expect(!ScreenshotSaveLocation.shouldDiscardBookmark(
      error: cocoa(NSFileReadNoPermissionError), folderPath: "/Users/me/Pictures", volumeIsMounted: { _ in true }))
    #expect(!ScreenshotSaveLocation.shouldDiscardBookmark(
      error: NSError(domain: NSPOSIXErrorDomain, code: 5), folderPath: "/Users/me/Pictures", volumeIsMounted: { _ in true }))
  }
}

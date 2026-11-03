import Foundation

/// Failure classification shared by every security-scoped folder the app remembers
/// (`ScreenshotSaveLocation`, `ExtraModelFolder`).
///
/// It lives here rather than in one of its callers because the rule is about bookmarks, not about
/// screenshots or models: a bookmark that keeps failing must be forgotten, one whose folder is
/// merely away must not. Two copies of that rule would drift, and the `/Volumes` half is subtle
/// enough that a drifted copy would silently delete a user's setting for an unplugged drive.
enum SecurityScopedBookmark {
  /// Whether a bookmark that failed to resolve should be forgotten for good. Only "the bookmark
  /// data is corrupt" and "the folder no longer exists" qualify. An unmounted external drive
  /// reports the same missing-file error as a deleted folder, so for paths under `/Volumes` the
  /// volume root decides: if it is not mounted right now, the folder may well come back.
  static func shouldDiscard(
    error: NSError, folderPath: String, volumeIsMounted: (String) -> Bool
  ) -> Bool {
    guard error.domain == NSCocoaErrorDomain else { return false }
    switch error.code {
    case NSFileReadCorruptFileError:
      return true
    case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
      let parts = folderPath.split(separator: "/", omittingEmptySubsequences: true)
      if parts.count >= 2, parts[0] == "Volumes" {
        return volumeIsMounted("/Volumes/\(parts[1])")
      }
      return true
    default:
      return false
    }
  }
}

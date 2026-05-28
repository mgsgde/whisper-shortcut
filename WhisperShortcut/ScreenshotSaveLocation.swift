import AppKit
import Foundation

/// Owns the user-selected screenshot save folder and all sandboxed writes to it.
/// Because the app is sandboxed, writing outside the container requires a
/// security-scoped bookmark obtained from a folder picker; this type is the
/// single place that creates, resolves, and accesses that bookmark so both
/// capture paths (⌘3 and the in-chat button) stay consistent.
enum ScreenshotSaveLocation {
  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: UserDefaultsKeys.screenshotSaveEnabled)
  }

  static var displayPath: String {
    UserDefaults.standard.string(forKey: UserDefaultsKeys.screenshotSaveFolderDisplayPath) ?? ""
  }

  static var hasFolder: Bool {
    UserDefaults.standard.data(forKey: UserDefaultsKeys.screenshotSaveBookmark) != nil
  }

  /// Stores a security-scoped bookmark for the chosen folder plus its display path.
  @discardableResult
  static func setFolder(_ url: URL) -> Bool {
    do {
      let bookmark = try url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(bookmark, forKey: UserDefaultsKeys.screenshotSaveBookmark)
      UserDefaults.standard.set(url.path, forKey: UserDefaultsKeys.screenshotSaveFolderDisplayPath)
      DebugLogger.log("SCREENSHOT: Save folder set to \(url.path)")
      return true
    } catch {
      DebugLogger.logError(
        "SCREENSHOT: Failed to bookmark folder \(url.path): \(error.localizedDescription)")
      return false
    }
  }

  /// Resolves the stored bookmark to a URL, refreshing it if stale. Returns nil if no folder is
  /// configured or resolution failed.
  static func resolveFolderURL() -> URL? {
    guard let bookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.screenshotSaveBookmark)
    else { return nil }
    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
        bookmarkDataIsStale: &isStale)
      if isStale {
        let accessed = url.startAccessingSecurityScopedResource()
        if let refreshed = try? url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
          UserDefaults.standard.set(refreshed, forKey: UserDefaultsKeys.screenshotSaveBookmark)
        }
        if accessed { url.stopAccessingSecurityScopedResource() }
      }
      return url
    } catch {
      DebugLogger.logError(
        "SCREENSHOT: Failed to resolve save folder bookmark: \(error.localizedDescription)")
      return nil
    }
  }

  /// Writes the PNG into the chosen folder under a timestamped name. Returns the written URL or nil.
  @discardableResult
  static func save(_ pngData: Data) -> URL? {
    guard let folder = resolveFolderURL() else {
      DebugLogger.logError("SCREENSHOT: Save requested but no folder is configured")
      return nil
    }
    let accessed = folder.startAccessingSecurityScopedResource()
    defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
    let target = uniqueURL(in: folder)
    do {
      try pngData.write(to: target)
      DebugLogger.log("SCREENSHOT: Saved \(pngData.count) bytes to \(target.path)")
      return target
    } catch {
      DebugLogger.logError("SCREENSHOT: Failed to write \(target.path): \(error.localizedDescription)")
      return nil
    }
  }

  private static func uniqueURL(in folder: URL) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let base = "Screenshot \(formatter.string(from: Date()))"
    var candidate = folder.appendingPathComponent("\(base).png")
    var counter = 1
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = folder.appendingPathComponent("\(base) (\(counter)).png")
      counter += 1
    }
    return candidate
  }
}

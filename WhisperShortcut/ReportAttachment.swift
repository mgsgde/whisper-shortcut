import Foundation

/// A report that is too long for a `wa.me` or `mailto:` URL, written beside the app's other data
/// so the user can attach it or drag it into a chat.
enum ReportAttachment {
  private static let retention: TimeInterval = 7 * 24 * 60 * 60

  /// Writes `text` to <Application Support>/Reports/WhisperShortcut-Report-yyyy-MM-dd-HHmmss.txt
  /// (use AppSupportPaths like the Logs dir does), prunes files there older than 7 days, returns the URL.
  static func write(_ text: String, now: Date = Date(), directory: URL? = nil) throws -> URL {
    let folder = directory ?? AppSupportPaths.reportsURL()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    pruneOld(now: now, directory: folder)
    let url = folder.appendingPathComponent(fileName(for: now))
    try text.write(to: url, atomically: true, encoding: .utf8)
    DebugLogger.log("DICTATION-REPORT: Wrote \(url.lastPathComponent) (\(text.count) chars)")
    return url
  }

  private static func fileName(for now: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return "WhisperShortcut-Report-\(formatter.string(from: now)).txt"
  }

  /// Drops report files last modified more than 7 days before `now`. Called when a report is
  /// written and once at launch. A missing folder, or a file that cannot be dated or removed,
  /// is left alone: losing one old draft is not a reason to fail the report the user is sending.
  static func pruneOld(now: Date = Date(), directory: URL? = nil) {
    prune(folder: directory ?? AppSupportPaths.reportsURL(), now: now)
  }

  private static func prune(folder: URL, now: Date) {
    let cutoff = now.addingTimeInterval(-retention)
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil, options: [])
    else { return }
    for url in urls {
      guard let attributes = try? fm.attributesOfItem(atPath: url.path),
        (attributes[.type] as? FileAttributeType) == .typeRegular,
        let modified = attributes[.modificationDate] as? Date,
        modified < cutoff
      else { continue }
      do {
        try fm.removeItem(at: url)
      } catch {
        DebugLogger.logWarning(
          "DICTATION-REPORT: Could not prune \(url.lastPathComponent): \(error.logDescription)")
      }
    }
  }
}

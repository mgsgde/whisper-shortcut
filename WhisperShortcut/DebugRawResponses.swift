import Foundation

/// Opt-in dump of the final raw assistant response for a chat send.
/// Gated by `UserDefaultsKeys.saveRawAssistantResponses`; no-op otherwise.
///
/// Designed to make markdown-rendering bugs trivially reproducible: flip the toggle,
/// reproduce the bad UI, paste the `.md` into a diff with the rendered view. Avoids
/// having to instrument code with throw-away `DebugLogger` calls each time.
enum DebugRawResponses {

  private static let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  /// Writes `content` to `Debug/raw-responses/{timestamp}-{model}.md` iff the toggle is on.
  /// Failures are silently ignored — this is diagnostic-only and must never affect the chat path.
  static func saveIfEnabled(content: String, model: String) {
    guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.saveRawAssistantResponses) else { return }
    let dir = AppSupportPaths.debugRawResponsesURL()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let timestamp = timestampFormatter.string(from: Date())
    let safeModel = model
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    let url = dir.appendingPathComponent("\(timestamp)-\(safeModel).md")
    try? content.write(to: url, atomically: true, encoding: .utf8)
  }
}

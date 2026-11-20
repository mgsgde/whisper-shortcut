#if DEBUG
import Foundation

/// Writes one Dictate Prompt request to `Debug/prompt-context` so the exact context
/// (window JPEG and text blocks) can be inspected. Debug builds only. The write runs
/// off the caller thread and never fails the request.
enum PromptContextDebugDump {

  private static let lock = NSLock()
  private static let maxStems = 30

  static func write(_ envelope: SpeechService.DictatePromptEnvelope, logPrefix: String) {
    let snapshot = envelope
    let prefix = logPrefix
    Task.detached(priority: .utility) {
      writeSnapshot(snapshot, logPrefix: prefix)
    }
  }

  private static func writeSnapshot(
    _ envelope: SpeechService.DictatePromptEnvelope, logPrefix: String
  ) {
    lock.lock()
    defer { lock.unlock() }

    let directory = AppSupportPaths.debugPromptContextURL()
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let stem = timestampStem()
      if let jpeg = envelope.screenshot {
        try jpeg.write(to: directory.appendingPathComponent("\(stem).jpg"), options: .atomic)
      }
      let textURL = directory.appendingPathComponent("\(stem).txt")
      try render(envelope, stem: stem).write(to: textURL, atomically: true, encoding: .utf8)
      pruneOldest(in: directory)
      DebugLogger.log("\(logPrefix): PROMPT-CONTEXT-DUMP: \(textURL.path)")
    } catch {
      DebugLogger.logError("\(logPrefix): PROMPT-CONTEXT-DUMP failed: \(error.logDescription)")
    }
  }

  private static func timestampStem() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    return formatter.string(from: Date())
  }

  private static func render(
    _ envelope: SpeechService.DictatePromptEnvelope, stem: String
  ) -> String {
    var sections: [String] = []
    if envelope.screenshot != nil {
      sections.append("image: \(stem).jpg")
    } else {
      sections.append("image: none")
    }
    if envelope.screenshot != nil {
      sections.append(section("screenshotLabel", envelope.screenshotLabel))
    }
    if let fieldBlock = envelope.fieldBlock {
      sections.append(section("fieldBlock", fieldBlock))
    }
    if let selectionBlock = envelope.selectionBlock {
      sections.append(section("selectionBlock", selectionBlock))
    }
    if !envelope.history.isEmpty {
      var body = ""
      for (index, turn) in envelope.history.enumerated() {
        if index > 0 { body += "\n\n" }
        body += turn.isUser ? "[user]\n" : "[model]\n"
        body += turn.text
      }
      sections.append(section("history (\(envelope.history.count) turns)", body))
    }
    sections.append(section("systemPrompt", envelope.systemPrompt))
    return sections.joined(separator: "\n\n") + "\n"
  }

  private static func section(_ title: String, _ body: String) -> String {
    "=== \(title) ===\n\(body)"
  }

  /// Drops `.jpg` / `.txt` whose stem is outside the newest `maxStems`, ordered by the
  /// timestamp stem (lexicographic order matches local time).
  private static func pruneOldest(in directory: URL) {
    let fileManager = FileManager.default
    guard let urls = try? fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return }

    var stems = Set<String>()
    for url in urls {
      let ext = url.pathExtension.lowercased()
      guard ext == "jpg" || ext == "txt" else { continue }
      stems.insert(url.deletingPathExtension().lastPathComponent)
    }
    for stem in stems.sorted().dropLast(maxStems) {
      for ext in ["jpg", "txt"] {
        let url = directory.appendingPathComponent("\(stem).\(ext)")
        if fileManager.fileExists(atPath: url.path) {
          try? fileManager.removeItem(at: url)
        }
      }
    }
  }
}
#endif

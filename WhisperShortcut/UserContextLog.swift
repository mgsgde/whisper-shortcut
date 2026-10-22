import Foundation

/// Stored `mode` on an interaction row. Raw values are the JSONL spellings already on disk
/// (`geminiChat`, not `chat`). Call sites used to repeat those literals, so a rename in one
/// reader left the others counting a different set.
enum InteractionMode: String, Codable, CaseIterable {
  case transcription
  case prompt
  case chat = "geminiChat"
}

/// One reader and one writer for the UserContext JSONL streams.
///
/// Listing, line decoding, ISO-8601 timestamps, and append each existed as a private copy
/// (`ContextLogger`, `ContextDerivation`, `UsageReport`, `QuickActionStore`,
/// `GlossaryFastLearner`, `SmartImprovementScorecard`). The copies had already drifted: the
/// scorecard parsed `yyyy-MM-dd` filenames with the user calendar, so a Buddhist or Japanese
/// calendar dropped today's file, and each reader allocated its own ISO-8601 parser.
enum UserContextLog {

  /// Date-stamped daily streams. The raw value is the filename prefix.
  enum Stream: String, CaseIterable {
    case interactions = "interactions-"
    case signals = "signals-"
  }

  /// Gregorian `yyyy-MM-dd` for daily log names. Locale is set before the calendar: assigning
  /// `locale` replaces the calendar with the locale's, and without the Gregorian pin a Buddhist
  /// or Japanese user calendar makes `2026-10-22` unparsable as "today".
  static let fileNameDateFormatter = makeFileNameDateFormatter(dateFormat: "yyyy-MM-dd")
  private static let fileNameFormatterLock = NSLock()

  static func makeFileNameDateFormatter(dateFormat: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = dateFormat
    return formatter
  }

  /// `yyyy-MM-dd` for `date`, using the shared Gregorian formatter.
  static func fileNameDayString(from date: Date) -> String {
    fileNameFormatterLock.lock()
    defer { fileNameFormatterLock.unlock() }
    return fileNameDateFormatter.string(from: date)
  }

  /// Day encoded in a `prefixyyyy-MM-dd.jsonl` name, or nil when the name is not that stream.
  static func fileDay(in fileName: String, stream: Stream) -> Date? {
    guard fileName.hasPrefix(stream.rawValue), fileName.hasSuffix(".jsonl") else { return nil }
    let dateString = fileName
      .replacingOccurrences(of: stream.rawValue, with: "")
      .replacingOccurrences(of: ".jsonl", with: "")
    fileNameFormatterLock.lock()
    defer { fileNameFormatterLock.unlock() }
    return fileNameDateFormatter.date(from: dateString)
  }

  /// Daily `prefixyyyy-MM-dd.jsonl` files in `directory` whose name date is within `lastDays`
  /// of `now`, oldest first.
  ///
  /// `calendar` is only the cutoff arithmetic (callers pass `.current`). Filename dates are
  /// always parsed with `fileNameDateFormatter`, so a Buddhist cutoff calendar still finds a
  /// Gregorian name.
  static func files(
    stream: Stream,
    in directory: URL,
    lastDays: Int,
    now: Date,
    calendar: Calendar = .current
  ) -> [URL] {
    let cutoff = calendar.date(byAdding: .day, value: -lastDays, to: now) ?? now
    do {
      let contents = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      return contents.filter { url in
        guard let fileDate = fileDay(in: url.lastPathComponent, stream: stream) else { return false }
        return fileDate >= cutoff
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
      DebugLogger.logError("USER-CONTEXT: Failed to list log files: \(error.localizedDescription)")
      return []
    }
  }

  /// Decodes every non-empty line of `files` as `T`. Blank lines and lines that are not `T`
  /// are skipped — a malformed row must not drop the rest of the file. Each former reader had
  /// its own copy of this loop (`components(separatedBy:)` vs `split(whereSeparator:)`).
  static func decodeLines<T: Decodable>(_ files: [URL], as type: T.Type) -> [T] {
    let decoder = JSONDecoder()
    var rows: [T] = []
    for url in files {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
        guard let row = try? decoder.decode(T.self, from: data) else { continue }
        rows.append(row)
      }
    }
    return rows
  }

  /// Interaction rows from the live UserContext directory. `mode` keeps only that mode's raw
  /// value; nil returns every decodable row, including modes this enum does not know.
  static func interactions(lastDays: Int, mode: InteractionMode? = nil) -> [InteractionLogEntry] {
    let files = files(
      stream: .interactions,
      in: ContextLogger.shared.directoryURL,
      lastDays: lastDays,
      now: Date())
    let entries = decodeLines(files, as: InteractionLogEntry.self)
    guard let mode else { return entries }
    return entries.filter { $0.mode == mode.rawValue }
  }

  /// ISO-8601 timestamp, with or without fractional seconds.
  ///
  /// `ContextDerivation` parsed with `ISO8601DateFormatter` and treated failure as `.distantPast`;
  /// the scorecard parsed with `Date.ISO8601FormatStyle` and treated failure as nil. This accepts
  /// whichever of those parsers succeeds. Callers that want the old distant-past fallback apply
  /// it themselves. `date(from:)` is not thread-safe, so the formatters stay behind a lock;
  /// `ISO8601FormatStyle` is a value and is not locked.
  static func timestamp(_ s: String) -> Date? {
    timestampLock.lock()
    let fractional = fractionalTimestampFormatter.date(from: s)
    let plain = fractional == nil ? plainTimestampFormatter.date(from: s) : nil
    timestampLock.unlock()
    if let fractional { return fractional }
    if let plain { return plain }
    if let date = try? Date(s, strategy: fractionalTimestampStyle) { return date }
    return try? Date(s, strategy: plainTimestampStyle)
  }

  /// Current time in the same ISO-8601 form `ContextLogger` writes (`…ss.SSSZ`).
  ///
  /// One cached formatter: the old helper allocated a new `ISO8601DateFormatter` on every
  /// append. Formatting is thread-safe; parsing is not (see `timestamp`).
  static func nowString(_ date: Date = Date()) -> String {
    nowFormatter.string(from: date)
  }

  /// Appends `data` plus a newline to `url`, creating the file when it is missing.
  ///
  /// The history writers and the daily-stream writer each opened a `FileHandle` and sought to
  /// the end. One of them drifting (atomic replace, missing newline) would truncate a JSONL log.
  static func appendLine(_ data: Data, to url: URL) throws {
    guard var line = String(data: data, encoding: .utf8) else {
      throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    line += "\n"
    if FileManager.default.fileExists(atPath: url.path) {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      _ = try handle.seekToEnd()
      if let lineData = line.data(using: .utf8) {
        try handle.write(contentsOf: lineData)
      }
    } else {
      try line.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  private static let nowFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let timestampLock = NSLock()
  private static let fractionalTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let plainTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
  private static let fractionalTimestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let plainTimestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
}

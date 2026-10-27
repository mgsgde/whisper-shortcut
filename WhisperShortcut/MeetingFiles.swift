import Foundation

/// The files one meeting owns, all named after its stem in `Meetings/`. Anything that deletes, renames
/// or lists a meeting goes through `all`, so adding a file to a meeting is one edit here.
struct MeetingFiles {
  static var directory: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)
  }

  let transcript: URL

  init(stem: String) {
    transcript = Self.directory.appendingPathComponent("\(stem).txt")
  }

  init(transcript: URL) {
    self.transcript = transcript
  }

  var stem: String { transcript.deletingPathExtension().lastPathComponent }

  var notes: URL { transcript.deletingPathExtension().appendingPathExtension("notes.md") }

  var summary: URL { transcript.deletingPathExtension().appendingPathExtension("summary.md") }

  var all: [URL] { [transcript, notes, summary] }

  /// Deletes every file of the meeting that exists. Kept audio is separate (`MeetingAudioBacklog`).
  func removeAll() {
    for url in all {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Moves every existing file to `newStem` in the same directory, replacing files already there.
  /// Returns the moved set. Throws only if moving the transcript fails (notes/summary are best effort, as before).
  func move(toStem newStem: String) throws -> MeetingFiles {
    let destination = MeetingFiles(
      transcript: transcript.deletingLastPathComponent().appendingPathComponent("\(newStem).txt"))
    let fm = FileManager.default
    if fm.fileExists(atPath: destination.transcript.path) {
      try fm.removeItem(at: destination.transcript)
    }
    try fm.moveItem(at: transcript, to: destination.transcript)
    moveBestEffort(notes, to: destination.notes)
    moveBestEffort(summary, to: destination.summary)
    return destination
  }

  private func moveBestEffort(_ source: URL, to destination: URL) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: source.path) else { return }
    try? fm.removeItem(at: destination)
    try? fm.moveItem(at: source, to: destination)
  }
}

/// The on-disk transcript format: "[mm:ss] text" blocks separated by blank lines, and the
/// "Meeting-yyyy-MM-dd-HHmmss" stem.
enum MeetingTranscriptFormat {
  /// Display timestamp, e.g. "[02:15]". Minutes may exceed two digits for long meetings.
  static func timestamp(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds) / 60
    let remainder = Int(seconds) % 60
    return String(format: "[%02d:%02d]", minutes, remainder)
  }

  /// One transcript block as `appendToTranscript` writes it: timestamp, a space, the text, then a blank line.
  static func block(startTime: TimeInterval, text: String) -> String {
    "\(timestamp(startTime)) \(text)\n\n"
  }

  /// Renders chunks in the transcript file format `appendToTranscript` writes.
  static func text(_ chunks: [LiveMeetingChunk]) -> String {
    chunks.map { block(startTime: $0.startTime, text: $0.text) }.joined()
  }

  /// Matches a "[mm:ss]" timestamp marker at the start of a line (minutes may exceed two digits for
  /// long meetings). Anchored so a "[1:23]" inside a chunk's text does not split the chunk.
  private static let timestampRegex = try! NSRegularExpression(
    pattern: #"^\[(\d+):(\d{2})\]"#, options: [.anchorsMatchLines])

  /// Parses a transcript file (as written by `appendToTranscript`: "[mm:ss] text" blocks
  /// separated by blank lines) back into chunks. Used to rehydrate a resumed meeting.
  static func parse(_ text: String) -> [LiveMeetingChunk] {
    let ns = text as NSString
    let matches = timestampRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    var result: [LiveMeetingChunk] = []
    for (i, m) in matches.enumerated() {
      let minutes = Int(ns.substring(with: m.range(at: 1))) ?? 0
      let seconds = Int(ns.substring(with: m.range(at: 2))) ?? 0
      let start = TimeInterval(minutes * 60 + seconds)
      let bodyStart = m.range.location + m.range.length
      let bodyEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
      let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !body.isEmpty {
        result.append(LiveMeetingChunk(startTime: start, text: body))
      }
    }
    return result
  }

  /// Generates a timestamp-based filename stem (e.g. "Meeting-2026-03-04-201119").
  /// Used as the meeting's unique ID for both transcript files and chat store scope.
  static func newStem(at date: Date = Date()) -> String {
    "Meeting-" + stemDateFormatter.string(from: date)
  }

  /// Parses the meeting date from a session's `meetingStem` / `meetingId`
  /// (e.g. "Meeting-2025-03-04-143000"). Returns nil if the stem isn't in the expected format.
  static func date(fromStem stem: String) -> Date? {
    guard stem.hasPrefix("Meeting-") else { return nil }
    let timestamp = String(stem.dropFirst("Meeting-".count))
    return stemDateFormatter.date(from: timestamp)
  }

  private static let stemDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter
  }()
}

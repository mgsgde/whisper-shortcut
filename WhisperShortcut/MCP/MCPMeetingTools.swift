import Foundation

/// Read-only tool layer behind the MCP server. Pure over a `Meetings/` directory so it is testable.
/// Files are read fresh on every call because the live transcript grows while recording.
struct MCPMeetingTools {
  let meetingsDirectory: URL
  /// Filename stem of the meeting being recorded right now, nil if none.
  let liveStem: () -> String?

  static let maxResultCharacters = 60_000

  /// "yyyy-MM-dd HH:mm:ss", matching the string format this tool has always reported — unlike
  /// `MeetingListService`, which only needs the parsed `Date`.
  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
  }()

  // MARK: - Definitions

  static let toolDefinitions: [[String: Any]] = [
    [
      "name": "get_live_transcript",
      "description":
        "Returns the transcript of the meeting that is being recorded right now in WhisperShortcut. "
        + "During a live meeting, call this before answering any question about the meeting, passing next_since from your previous call to get only what is new. Omit since on the first call.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "since": [
            "type": "string",
            "description": "Timestamp (mm:ss or h:mm:ss). Only transcript after it is returned. Use next_since from the previous call.",
          ]
        ],
      ] as [String: Any],
    ],
    [
      "name": "list_meetings",
      "description":
        "Lists recorded meetings, newest first, with id, date, title, duration, whether notes and a summary exist, and whether the meeting is live.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "limit": ["type": "integer", "description": "Maximum number of meetings (default 20, max 200)."]
        ],
      ] as [String: Any],
    ],
    [
      "name": "get_meeting",
      "description":
        "Returns the transcript, notes and/or summary of one meeting by id (as returned by list_meetings).",
      "inputSchema": [
        "type": "object",
        "properties": [
          "id": ["type": "string", "description": "Meeting id from list_meetings."],
          "part": [
            "type": "string", "enum": ["transcript", "notes", "summary", "all"],
            "description": "Which part to return (default all).",
          ],
          "since": ["type": "string", "description": "Only transcript chunks after this timestamp (mm:ss or h:mm:ss)."],
          "until": [
            "type": "string",
            "description": "Only transcript chunks before this timestamp (mm:ss or h:mm:ss). Use it to read the start of a long meeting whose output was cut.",
          ],
        ],
        "required": ["id"],
      ] as [String: Any],
    ],
    [
      "name": "search_meetings",
      "description":
        "Case- and accent-insensitive text search across all meeting transcripts and notes. Returns meeting id, timestamp and the matching passage, newest meetings first.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "query": ["type": "string", "description": "Text to search for."],
          "limit": ["type": "integer", "description": "Maximum number of matches (default 20)."],
        ],
        "required": ["query"],
      ] as [String: Any],
    ],
  ]

  // MARK: - Dispatch

  func call(name: String, arguments: [String: Any]) -> (text: String, isError: Bool) {
    switch name {
    case "get_live_transcript": return getLiveTranscript(arguments)
    case "list_meetings": return listMeetings(arguments)
    case "get_meeting": return getMeeting(arguments)
    case "search_meetings": return searchMeetings(arguments)
    default: return ("Unknown tool: \(name)", true)
    }
  }

  // MARK: - Helpers

  /// Shared scan (R83): one regex, trimmed titles, hidden files skipped, date-descending —
  /// same scan the app's own meeting list uses, instead of a second reimplementation here.
  private func allMeetings() -> [MeetingFileInfo] {
    MeetingListService.scan(directory: meetingsDirectory)
  }

  private func transcriptURL(_ id: String) -> URL {
    meetingsDirectory.appendingPathComponent("\(id).txt")
  }

  private func notesURL(_ id: String) -> URL {
    MeetingListService.notesURL(transcriptFileURL: transcriptURL(id))
  }

  private func summaryURL(_ id: String) -> URL {
    MeetingListService.summaryURL(transcriptFileURL: transcriptURL(id))
  }

  private func chunks(for id: String) -> [LiveMeetingChunk]? {
    guard let text = try? String(contentsOf: transcriptURL(id), encoding: .utf8) else { return nil }
    return LiveMeetingTranscriptStore.parseTranscript(text)
  }

  static func format(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return String(format: "%02d:%02d", total / 60, total % 60)
  }

  /// "mm:ss", "h:mm:ss" or "[mm:ss]" → seconds. Nil if unparseable.
  static func parseTimestamp(_ raw: String) -> TimeInterval? {
    let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] \n\t"))
    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
    // Each part is capped so `h * 3600` cannot overflow (a trap, i.e. an app crash) on hostile input.
    guard !parts.isEmpty, parts.count <= 3,
      !parts.contains(where: { $0 == nil || $0! < 0 || $0! > 1_000_000 })
    else { return nil }
    let nums = parts.map { $0! }
    switch nums.count {
    case 2: return TimeInterval(nums[0] * 60 + nums[1])
    case 3: return TimeInterval(nums[0] * 3600 + nums[1] * 60 + nums[2])
    default: return nil
    }
  }

  private func parseSince(_ arguments: [String: Any]) -> (value: TimeInterval?, error: String?) {
    parseTimestampArgument(arguments, "since")
  }

  private func parseTimestampArgument(_ arguments: [String: Any], _ key: String) -> (value: TimeInterval?, error: String?) {
    guard let raw = arguments[key] as? String, !raw.isEmpty else { return (nil, nil) }
    guard let v = Self.parseTimestamp(raw) else {
      return (nil, "Invalid \(key) value \"\(raw)\". Use mm:ss or h:mm:ss.")
    }
    return (v, nil)
  }

  /// This site's default and range over `ChatToolRegistry.intArgument`'s shared, hostile-input-safe
  /// parse (Int/Double/NSNumber/String, clamped and NaN/infinity-safe) — used to have its own
  /// smaller Int/Double-only parse copied here (R84).
  private func intArg(_ arguments: [String: Any], _ key: String, default d: Int, max m: Int) -> Int {
    min(max(ChatToolRegistry.intArgument(arguments, key, default: d), 1), m)
  }

  private func render(_ chunks: [LiveMeetingChunk]) -> String {
    chunks.map { "[\(Self.format($0.startTime))] \($0.text)" }.joined(separator: "\n\n")
  }

  /// Keeps the newest part when over the cap.
  static func capNewest(_ text: String, limit: Int = maxResultCharacters) -> String {
    guard text.count > limit else { return text }
    let cut = text.count - limit
    var kept = String(text.suffix(limit))
    if let nl = kept.firstIndex(of: "\n"), kept.distance(from: kept.startIndex, to: nl) < 500 {
      kept = String(kept[kept.index(after: nl)...])
    }
    return "[Output cut: the oldest \(cut) characters were removed to stay under \(limit). Pass `until` (mm:ss) to read the earlier part.]\n\n" + kept
  }

  /// Keeps the beginning (used for result lists ordered newest first).
  static func capHead(_ text: String, limit: Int = maxResultCharacters) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "\n\n[Output cut: \(text.count - limit) characters removed. Use a smaller limit or a more specific query.]"
  }

  // MARK: - get_live_transcript

  private func getLiveTranscript(_ arguments: [String: Any]) -> (text: String, isError: Bool) {
    let since = parseSince(arguments)
    if let e = since.error { return (e, true) }

    if let stem = liveStem(), let all = chunks(for: stem) {
      let elapsed = all.last.map { Self.format($0.startTime) } ?? "00:00"
      let fresh = all.filter { since.value == nil || $0.startTime > since.value! }
      var out = "Live meeting: \(stem)\nElapsed: \(elapsed)\n\n"
      if fresh.isEmpty {
        let sinceText = since.value.map { Self.format($0) } ?? "00:00"
        out += "No new transcript since \(sinceText).\nnext_since: \(sinceText)"
        return (out, false)
      }
      out += render(fresh)
      out = Self.capNewest(out)
      out += "\n\nnext_since: \(Self.format(fresh.last!.startTime))"
      return (out, false)
    }

    if let latest = allMeetings().first {
      return ("No meeting is being recorded right now. The most recent meeting is \"\(latest.id)\"; use get_meeting with that id.", false)
    }
    return ("No meeting is being recorded right now, and there are no saved meetings.", false)
  }

  // MARK: - list_meetings

  private func listMeetings(_ arguments: [String: Any]) -> (text: String, isError: Bool) {
    let limit = intArg(arguments, "limit", default: 20, max: 200)
    let live = liveStem()
    let meetings = allMeetings()
    if meetings.isEmpty { return ("No meetings found.", false) }
    let fm = FileManager.default
    let lines = meetings.prefix(limit).map { m -> String in
      let duration = chunks(for: m.id)?.last.map { Self.format($0.startTime) } ?? "00:00"
      let notes = fm.fileExists(atPath: notesURL(m.id).path)
      let summary = fm.fileExists(atPath: summaryURL(m.id).path)
      return "- id: \(m.id) | date: \(Self.dateFormatter.string(from: m.date)) | title: \(m.title ?? "-") | duration: \(duration) | has_notes: \(notes) | has_summary: \(summary) | is_live: \(m.id == live)"
    }
    var out = lines.joined(separator: "\n")
    if meetings.count > limit { out += "\n\n(\(meetings.count - limit) older meetings not shown; raise limit.)" }
    return (Self.capHead(out), false)
  }

  // MARK: - get_meeting

  private func getMeeting(_ arguments: [String: Any]) -> (text: String, isError: Bool) {
    guard let id = arguments["id"] as? String, !id.isEmpty else { return ("Missing required argument: id", true) }
    if id.contains("/") || id.contains("..") || id.contains("\\") { return ("Invalid meeting id.", true) }
    let part = (arguments["part"] as? String) ?? "all"
    guard ["transcript", "notes", "summary", "all"].contains(part) else {
      return ("Invalid part \"\(part)\". Use transcript, notes, summary or all.", true)
    }
    let since = parseSince(arguments)
    if let e = since.error { return (e, true) }
    let until = parseTimestampArgument(arguments, "until")
    if let e = until.error { return (e, true) }

    guard FileManager.default.fileExists(atPath: transcriptURL(id).path) else {
      let recent = allMeetings().prefix(5).map(\.id).joined(separator: ", ")
      return ("Unknown meeting id \"\(id)\". Use list_meetings. Recent ids: \(recent.isEmpty ? "none" : recent)", true)
    }

    var sections: [String] = []
    func fileText(_ url: URL) -> String? {
      guard let t = try? String(contentsOf: url, encoding: .utf8) else { return nil }
      let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    var tail: [String] = []
    if part == "notes" || part == "all" {
      tail.append("## Notes\n" + (fileText(notesURL(id)) ?? "(no notes)"))
    }
    if part == "summary" || part == "all" {
      tail.append("## Summary\n" + (fileText(summaryURL(id)) ?? "(no summary)"))
    }
    if part == "transcript" || part == "all" {
      let all = chunks(for: id) ?? []
      let shown = all.filter {
        (since.value == nil || $0.startTime > since.value!) && (until.value == nil || $0.startTime < until.value!)
      }
      var t = shown.isEmpty ? "(no transcript in that range)" : render(shown)
      let budget = max(10_000, Self.maxResultCharacters - tail.reduce(0) { $0 + $1.count } - 200)
      t = Self.capNewest(t, limit: budget)
      sections.append("## Transcript\n" + t)
    }
    sections.append(contentsOf: tail)
    let out = "Meeting: \(id)\n\n" + sections.joined(separator: "\n\n")
    return (Self.capNewest(out), false)
  }

  // MARK: - search_meetings

  private func searchMeetings(_ arguments: [String: Any]) -> (text: String, isError: Bool) {
    guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
      return ("Missing required argument: query", true)
    }
    let limit = intArg(arguments, "limit", default: 20, max: 200)
    let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    var hits: [String] = []
    outer: for m in allMeetings() {
      for chunk in chunks(for: m.id) ?? [] where chunk.text.range(of: query, options: opts) != nil {
        hits.append("\(m.id) [\(Self.format(chunk.startTime))] \(Self.truncate(chunk.text))")
        if hits.count >= limit { break outer }
      }
      if let notes = try? String(contentsOf: notesURL(m.id), encoding: .utf8) {
        for line in notes.components(separatedBy: "\n") where line.range(of: query, options: opts) != nil {
          hits.append("\(m.id) [notes] \(Self.truncate(line.trimmingCharacters(in: .whitespaces)))")
          if hits.count >= limit { break outer }
        }
      }
    }
    if hits.isEmpty { return ("No matches for \"\(query)\".", false) }
    return (Self.capHead(hits.joined(separator: "\n\n")), false)
  }

  private static func truncate(_ s: String, to n: Int = 400) -> String {
    s.count > n ? String(s.prefix(n)) + "…" : s
  }
}

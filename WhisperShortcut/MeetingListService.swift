import Foundation

/// Metadata for a saved meeting transcript file.
struct MeetingFileInfo: Identifiable, Hashable {
  let url: URL
  let date: Date
  let displayLabel: String
  /// Stable identifier derived from filename (e.g. "Meeting-2025-03-04-143000"), used as session store scope.
  let meetingId: String

  var id: String { meetingId }
}

/// Scans the Meetings/ folder for transcript files, parses them into chunks, and caches results.
final class MeetingListService: ObservableObject {
  static let shared = MeetingListService()

  @Published private(set) var meetings: [MeetingFileInfo] = []

  private var chunkCache: [URL: [LiveMeetingChunk]] = [:]

  private static let filenameRegex = try! NSRegularExpression(
    pattern: #"^Meeting-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})(?:-(.+))?\.txt$"#)

  private static let chunkLineRegex = try! NSRegularExpression(
    pattern: #"^\[(\d{2}):(\d{2})\]\s*(.+)$"#)

  private static let displayDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEEE, d MMM yyyy, HH:mm"
    return f
  }()

  private static let timestampFilenameFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    return f
  }()

  private init() {}

  /// Maximum characters for context sent to Gemini. Full transcript is still scrollable in UI.
  static let contextMaxChars = 60_000

  // MARK: - List

  /// Scans the Meetings/ directory and updates the published `meetings` list.
  func refresh() {
    let dir = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)

    guard FileManager.default.fileExists(atPath: dir.path) else {
      meetings = []
      return
    }

    let files = (try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []

    var result: [MeetingFileInfo] = []
    for fileURL in files {
      guard let info = Self.parseMeetingFilename(fileURL) else { continue }
      result.append(info)
    }

    result.sort { $0.date > $1.date }
    meetings = result
  }

  // MARK: - Parse

  /// Returns cached chunks for a meeting file, parsing on first access.
  func chunks(for meeting: MeetingFileInfo) -> [LiveMeetingChunk] {
    if let cached = chunkCache[meeting.url] { return cached }
    let parsed = Self.parseTranscriptFile(at: meeting.url)
    chunkCache[meeting.url] = parsed
    return parsed
  }

  /// Builds a context string from chunks for the chat system instruction.
  func contextString(for chunks: [LiveMeetingChunk]) -> String {
    let lines = chunks.map { "\($0.timestampString) \($0.text)" }
    var text = lines.joined(separator: "\n")
    if text.count > Self.contextMaxChars {
      text = String(text.suffix(Self.contextMaxChars))
    }
    guard !text.isEmpty else { return "" }
    return "Use the following meeting transcript to answer the user's questions.\n\n\(text)"
  }

  /// Clears the chunk cache (e.g. when a meeting file changes on disk).
  func invalidateCache(for url: URL? = nil) {
    if let url = url {
      chunkCache.removeValue(forKey: url)
    } else {
      chunkCache.removeAll()
    }
  }

  /// Renames a meeting file to a new display name (suffix after timestamp). Returns the new MeetingFileInfo on success, nil on failure.
  func renameMeeting(_ meeting: MeetingFileInfo, newDisplayName: String) -> MeetingFileInfo? {
    let sanitized = newDisplayName
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sanitized.isEmpty else { return nil }
    let timestampStem = "Meeting-\(Self.timestampFilenameFormatter.string(from: meeting.date))"
    let newStem = "\(timestampStem)-\(sanitized)"
    let dir = meeting.url.deletingLastPathComponent()
    let newURL = dir.appendingPathComponent("\(newStem).txt")
    guard newURL != meeting.url else { return meeting }
    do {
      if FileManager.default.fileExists(atPath: newURL.path) {
        try FileManager.default.removeItem(at: newURL)
      }
      try FileManager.default.moveItem(at: meeting.url, to: newURL)
      let oldSummaryURL = Self.summaryURL(for: meeting)
      let newSummaryURL = newURL.deletingPathExtension().appendingPathExtension("summary.md")
      if FileManager.default.fileExists(atPath: oldSummaryURL.path) {
        if FileManager.default.fileExists(atPath: newSummaryURL.path) {
          try FileManager.default.removeItem(at: newSummaryURL)
        }
        try FileManager.default.moveItem(at: oldSummaryURL, to: newSummaryURL)
      }
      invalidateCache(for: meeting.url)
      refresh()
      DebugLogger.log("MEETING-LIBRARY: Renamed to \(newStem).txt")
      return meetings.first { $0.url == newURL }
    } catch {
      DebugLogger.logError("MEETING-LIBRARY: Rename failed: \(error.localizedDescription)")
      return nil
    }
  }

  /// Deletes a meeting file from disk. Returns true on success.
  func deleteMeeting(_ meeting: MeetingFileInfo) -> Bool {
    do {
      try FileManager.default.removeItem(at: meeting.url)
      let summaryURL = Self.summaryURL(for: meeting)
      try? FileManager.default.removeItem(at: summaryURL)
      invalidateCache(for: meeting.url)
      refresh()
      DebugLogger.log("MEETING-LIBRARY: Deleted \(meeting.url.lastPathComponent)")
      return true
    } catch {
      DebugLogger.logError("MEETING-LIBRARY: Delete failed: \(error.localizedDescription)")
      return false
    }
  }

  // MARK: - Summary

  /// URL for the Markdown summary file (same stem as transcript, extension .summary.md).
  static func summaryURL(for meeting: MeetingFileInfo) -> URL {
    meeting.url.deletingPathExtension().appendingPathExtension("summary.md")
  }

  /// URL for summary file next to a transcript file (by path, e.g. when meeting just ended).
  static func summaryURL(transcriptFileURL: URL) -> URL {
    transcriptFileURL.deletingPathExtension().appendingPathExtension("summary.md")
  }

  /// Loads summary from disk if the .summary.md file exists.
  func loadSummary(for meeting: MeetingFileInfo) -> String? {
    let url = Self.summaryURL(for: meeting)
    return try? String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Saves summary to the meeting's .summary.md file.
  func saveSummary(_ text: String, for meeting: MeetingFileInfo) {
    let url = Self.summaryURL(for: meeting)
    saveSummary(text, to: url)
  }

  /// Saves summary to the .summary.md file next to the given transcript URL (e.g. when meeting just ended).
  func saveSummary(_ text: String, transcriptFileURL: URL) {
    let url = Self.summaryURL(transcriptFileURL: transcriptFileURL)
    saveSummary(text, to: url)
  }

  private func saveSummary(_ text: String, to url: URL) {
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
      DebugLogger.log("MEETING-LIBRARY: Saved summary to \(url.lastPathComponent)")
    } catch {
      DebugLogger.logError("MEETING-LIBRARY: Save summary failed: \(error.localizedDescription)")
    }
  }

  /// Loads summary from file, or generates via Gemini and saves. Returns placeholder on error or no API key.
  func summary(for meeting: MeetingFileInfo) async -> String {
    if let loaded = loadSummary(for: meeting), !loaded.isEmpty { return loaded }
    return await generateAndSaveSummary(for: meeting)
  }

  /// Generates a Markdown summary from the meeting transcript via Gemini and saves it. Returns placeholder on error.
  func generateAndSaveSummary(for meeting: MeetingFileInfo) async -> String {
    guard let credential = await GeminiCredentialProvider.shared.getCredential() else {
      return ""
    }
    let meetingChunks = chunks(for: meeting)
    var transcriptText = meetingChunks.map { "\($0.timestampString) \($0.text)" }.joined(separator: "\n\n")
    if transcriptText.count > Self.contextMaxChars {
      transcriptText = String(transcriptText.suffix(Self.contextMaxChars))
    }
    guard !transcriptText.isEmpty else { return "" }
    let model: String
    #if SUBSCRIPTION_ENABLED
    if credential.isOAuth {
      model = SubscriptionModelsConfigService.effectiveMeetingSummaryModel().rawValue
    } else {
      model = PromptModel.loadSelectedMeetingSummary().rawValue
    }
    #else
    model = PromptModel.loadSelectedMeetingSummary().rawValue
    #endif
    do {
      let summaryText = try await GeminiAPIClient().generateMeetingSummary(transcript: transcriptText, model: model, credential: credential)
      let trimmed = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        saveSummary(trimmed, for: meeting)
        return trimmed
      }
    } catch {
      DebugLogger.logError("MEETING-LIBRARY: Generate summary failed: \(error.localizedDescription)")
    }
    return ""
  }

  // MARK: - Private

  private static func parseMeetingFilename(_ url: URL) -> MeetingFileInfo? {
    let filename = url.lastPathComponent
    let range = NSRange(filename.startIndex..., in: filename)
    guard let match = filenameRegex.firstMatch(in: filename, range: range) else { return nil }

    guard let yearRange = Range(match.range(at: 1), in: filename),
          let monthRange = Range(match.range(at: 2), in: filename),
          let dayRange = Range(match.range(at: 3), in: filename),
          let hourRange = Range(match.range(at: 4), in: filename),
          let minRange = Range(match.range(at: 5), in: filename),
          let secRange = Range(match.range(at: 6), in: filename) else { return nil }

    var components = DateComponents()
    components.year = Int(filename[yearRange])
    components.month = Int(filename[monthRange])
    components.day = Int(filename[dayRange])
    components.hour = Int(filename[hourRange])
    components.minute = Int(filename[minRange])
    components.second = Int(filename[secRange])

    guard let date = Calendar.current.date(from: components) else { return nil }

    let meetingId = String(filename.dropLast(4))
    let displayLabel: String
    if match.numberOfRanges > 7, let suffixRange = Range(match.range(at: 7), in: filename), !suffixRange.isEmpty {
      displayLabel = String(filename[suffixRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      displayLabel = displayDateFormatter.string(from: date)
    }
    return MeetingFileInfo(url: url, date: date, displayLabel: displayLabel, meetingId: meetingId)
  }

  static func parseTranscriptFile(at url: URL) -> [LiveMeetingChunk] {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

    var chunks: [LiveMeetingChunk] = []
    for line in content.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }

      let lineRange = NSRange(trimmed.startIndex..., in: trimmed)
      guard let match = chunkLineRegex.firstMatch(in: trimmed, range: lineRange) else { continue }

      guard let minRange = Range(match.range(at: 1), in: trimmed),
            let secRange = Range(match.range(at: 2), in: trimmed),
            let textRange = Range(match.range(at: 3), in: trimmed) else { continue }

      let minutes = Int(trimmed[minRange]) ?? 0
      let seconds = Int(trimmed[secRange]) ?? 0
      let startTime = TimeInterval(minutes * 60 + seconds)
      let text = String(trimmed[textRange])

      chunks.append(LiveMeetingChunk(startTime: startTime, text: text))
    }
    return chunks
  }
}

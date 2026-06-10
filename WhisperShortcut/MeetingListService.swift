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

  /// Parses the meeting date from a session's `meetingStem` / `meetingId`
  /// (e.g. "Meeting-2025-03-04-143000"). Returns nil if the stem isn't in the expected format.
  static func date(fromStem stem: String) -> Date? {
    guard stem.hasPrefix("Meeting-") else { return nil }
    let timestamp = String(stem.dropFirst("Meeting-".count))
    return timestampFilenameFormatter.date(from: timestamp)
  }

  /// Hard cap on transcript characters sent to the summary model. The full transcript is still
  /// scrollable in the UI; this just bounds the LLM request size.
  static let meetingContextMaxChars = 60_000

  // MARK: - List

  /// Scans the Meetings/ directory and updates the published `meetings` list.
  func refresh() {
    let dir = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)

    guard FileManager.default.fileExists(atPath: dir.path) else {
      meetings = []
      return
    }

    let files: [URL]
    do {
      files = try FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
    } catch {
      DebugLogger.logError("MEETING-LIBRARY: Failed to read meetings directory: \(error.localizedDescription)")
      meetings = []
      return
    }

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

  /// Clears the chunk cache (e.g. when a meeting file changes on disk).
  func invalidateCache(for url: URL? = nil) {
    if let url = url {
      chunkCache.removeValue(forKey: url)
    } else {
      chunkCache.removeAll()
    }
  }

  // MARK: - Summary

  /// URL for the Markdown summary file next to a transcript file (same stem, `.summary.md` extension).
  static func summaryURL(transcriptFileURL: URL) -> URL {
    transcriptFileURL.deletingPathExtension().appendingPathExtension("summary.md")
  }

  /// Saves summary to the .summary.md file next to the given transcript URL.
  func saveSummary(_ text: String, transcriptFileURL: URL) {
    let url = Self.summaryURL(transcriptFileURL: transcriptFileURL)
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
      DebugLogger.log("MEETING-LIBRARY: Saved summary to \(url.lastPathComponent)")
    } catch {
      DebugLogger.logError("MEETING-LIBRARY: Save summary failed: \(error.localizedDescription)")
    }
  }

  /// Generates a Markdown summary from the meeting transcript and saves it. Routes to whichever
  /// provider owns the selected meeting-summary model (Gemini / OpenAI / Grok). Returns "" on error.
  func generateAndSaveSummary(for meeting: MeetingFileInfo) async -> String {
    let model = PromptModel.loadSelectedMeetingSummary()
    guard model.hasRequiredCredential else {
      DebugLogger.logWarning("MEETING-LIBRARY: No credential for \(model.rawValue) — cannot generate summary")
      return ""
    }
    let meetingChunks = chunks(for: meeting)
    var transcriptText = meetingChunks.map { "\($0.timestampString) \($0.text)" }.joined(separator: "\n\n")
    if transcriptText.count > Self.meetingContextMaxChars {
      transcriptText = String(transcriptText.suffix(Self.meetingContextMaxChars))
    }
    guard !transcriptText.isEmpty else { return "" }
    do {
      let summaryText = try await Self.generateSummaryText(transcript: transcriptText, model: model)
      let trimmed = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        saveSummary(trimmed, transcriptFileURL: meeting.url)
        return trimmed
      }
    } catch {
      DebugLogger.logError("MEETING-LIBRARY: Generate summary failed: \(error.localizedDescription)")
    }
    return ""
  }

  // MARK: - Provider-routed generation
  //
  // Meeting summary, rolling summary, and speaker consolidation all route to whichever provider owns
  // the selected meeting-summary model — so a Grok/OpenAI model no longer gets sent to the Gemini
  // endpoint (which fails). Each call retries transient errors via `withRetry`.

  /// Final post-meeting summary for the given transcript + model.
  static func generateSummaryText(transcript: String, model: PromptModel) async throws -> String {
    try await generate(prompt: AppConstants.meetingSummaryPrompt(transcript: transcript), model: model, label: "MEETING-SUMMARY")
  }

  /// Rolling (live) summary update for the given model.
  static func updateRollingSummary(currentSummary: String, newText: String, model: PromptModel) async throws -> String {
    try await generate(
      prompt: AppConstants.meetingRollingSummaryPrompt(currentSummary: currentSummary, newTranscriptText: newText),
      model: model,
      label: "MEETING-ROLLING-SUMMARY")
  }

  /// Consolidates speaker labels across the full transcript for the given model.
  static func consolidateSpeakerLabels(transcript: String, model: PromptModel) async throws -> String {
    try await generate(prompt: AppConstants.meetingConsolidationPrompt(transcript: transcript), model: model, label: "MEETING-CONSOLIDATE")
  }

  /// Shared "route prompt → provider, with transient-error retry" helper for meeting-summary work.
  private static func generate(prompt: String, model: PromptModel, label: String) async throws -> String {
    let provider = LLMProviderFactory.provider(for: model)
    return try await withRetry(label: label) {
      try await provider.generateText(model: model.rawValue, prompt: prompt)
    }
  }

  /// Recovers a summary for a meeting identified by its filename stem (e.g. the end-of-meeting
  /// generation failed on a transient Gemini 503 and never wrote a `.summary.md`). Builds the
  /// transcript URL from the stem, parses it, and regenerates. Returns "" if the transcript is
  /// missing/unparseable or generation fails.
  func generateAndSaveSummary(forStem stem: String) async -> String {
    let transcriptURL = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)
      .appendingPathComponent("\(stem).txt")
    guard let info = Self.parseMeetingFilename(transcriptURL) else {
      DebugLogger.logWarning("MEETING-LIBRARY: Cannot recover summary — unparseable stem \(stem)")
      return ""
    }
    return await generateAndSaveSummary(for: info)
  }

  /// Runs an async throwing API op, retrying on transient (retryable) `TranscriptionError`s with
  /// exponential backoff (2s, 4s, …). Non-retryable errors — or exhausting `maxAttempts` — re-throw.
  /// Used so a single transient Gemini 503 doesn't permanently lose a meeting summary or title.
  static func withRetry<T>(
    maxAttempts: Int = 4,
    label: String,
    _ op: () async throws -> T
  ) async throws -> T {
    var attempt = 0
    while true {
      attempt += 1
      do {
        return try await op()
      } catch {
        let retryable = (error as? TranscriptionError)?.isRetryable ?? false
        guard retryable, attempt < maxAttempts else { throw error }
        let seconds = pow(2.0, Double(attempt))  // 2, 4, 8
        DebugLogger.logWarning(
          "\(label): attempt \(attempt)/\(maxAttempts) failed (\(error.localizedDescription)); retrying in \(Int(seconds))s")
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      }
    }
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

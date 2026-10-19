import Foundation

/// Counts over the local Smart Improvement logs.
///
/// An accepted Smart Improvement change rewrites a prompt section, and nothing measured whether
/// that change helped. This scorecard counts transcriptions, rejected-spelling hits, prompt
/// follow-ups, em-dash insertion, chat turns, and retries. It calls no model. Nothing leaves the device.
struct ScorecardMetrics: Codable, Equatable, Sendable {
  var transcriptions = 0
  var rejectedSpellingHits = 0
  var prompts = 0
  var promptFollowUps = 0
  var dashFreeSelections = 0
  var dashesInserted = 0
  var chatTurns = 0
  var promptRetries = 0
  var chatRetries = 0

  /// Hits per 100 transcriptions. Nil when nothing was transcribed.
  var rejectedSpellingHitsPer100: Double? {
    rate(rejectedSpellingHits, over: transcriptions)
  }

  /// Follow-ups per 100 prompts, as a percent. Nil when there are no prompts.
  var followUpRate: Double? {
    rate(promptFollowUps, over: prompts)
  }

  /// Em/en dashes inserted per 100 dash-free selections. Nil when the denominator is 0.
  var dashInsertionRate: Double? {
    rate(dashesInserted, over: dashFreeSelections)
  }

  /// Prompt retries per 100 prompts. Nil when there are no prompts.
  var promptRetriesPer100: Double? {
    rate(promptRetries, over: prompts)
  }

  /// Chat retries per 100 chat turns. Nil when there are no chat turns.
  var chatRetriesPer100: Double? {
    rate(chatRetries, over: chatTurns)
  }

  /// No transcription, prompt, or chat turn in the window. Signals alone do not count.
  var isEmpty: Bool {
    transcriptions + prompts + chatTurns == 0
  }

  init(
    transcriptions: Int = 0,
    rejectedSpellingHits: Int = 0,
    prompts: Int = 0,
    promptFollowUps: Int = 0,
    dashFreeSelections: Int = 0,
    dashesInserted: Int = 0,
    chatTurns: Int = 0,
    promptRetries: Int = 0,
    chatRetries: Int = 0
  ) {
    self.transcriptions = transcriptions
    self.rejectedSpellingHits = rejectedSpellingHits
    self.prompts = prompts
    self.promptFollowUps = promptFollowUps
    self.dashFreeSelections = dashFreeSelections
    self.dashesInserted = dashesInserted
    self.chatTurns = chatTurns
    self.promptRetries = promptRetries
    self.chatRetries = chatRetries
  }

  private enum CodingKeys: String, CodingKey {
    case transcriptions
    case rejectedSpellingHits
    case prompts
    case promptFollowUps
    case dashFreeSelections
    case dashesInserted
    case chatTurns
    case promptRetries
    case chatRetries
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    transcriptions = try container.decodeIfPresent(Int.self, forKey: .transcriptions) ?? 0
    rejectedSpellingHits = try container.decodeIfPresent(Int.self, forKey: .rejectedSpellingHits) ?? 0
    prompts = try container.decodeIfPresent(Int.self, forKey: .prompts) ?? 0
    promptFollowUps = try container.decodeIfPresent(Int.self, forKey: .promptFollowUps) ?? 0
    dashFreeSelections = try container.decodeIfPresent(Int.self, forKey: .dashFreeSelections) ?? 0
    dashesInserted = try container.decodeIfPresent(Int.self, forKey: .dashesInserted) ?? 0
    chatTurns = try container.decodeIfPresent(Int.self, forKey: .chatTurns) ?? 0
    promptRetries = try container.decodeIfPresent(Int.self, forKey: .promptRetries) ?? 0
    chatRetries = try container.decodeIfPresent(Int.self, forKey: .chatRetries) ?? 0
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(transcriptions, forKey: .transcriptions)
    try container.encode(rejectedSpellingHits, forKey: .rejectedSpellingHits)
    try container.encode(prompts, forKey: .prompts)
    try container.encode(promptFollowUps, forKey: .promptFollowUps)
    try container.encode(dashFreeSelections, forKey: .dashFreeSelections)
    try container.encode(dashesInserted, forKey: .dashesInserted)
    try container.encode(chatTurns, forKey: .chatTurns)
    try container.encode(promptRetries, forKey: .promptRetries)
    try container.encode(chatRetries, forKey: .chatRetries)
  }

  private func rate(_ numerator: Int, over denominator: Int) -> Double? {
    guard denominator > 0 else { return nil }
    return Double(numerator) / Double(denominator) * 100
  }
}

/// One ISO week of scorecard counts. `id` is `"2026-W42"`.
struct ScorecardWeek: Identifiable, Equatable, Sendable {
  let id: String
  /// Monday 00:00 in the calendar's time zone.
  let start: Date
  let metrics: ScorecardMetrics
}

/// Deterministic, counts-only scorecard over the UserContext interaction and signal logs.
enum SmartImprovementScorecard {
  /// A later prompt is a follow-up only when it starts within this many seconds of the previous one.
  static let followUpWindow: TimeInterval = 300
  /// Word-level similarity at or above this counts as the same text coming back.
  static let followUpSimilarity = 0.8
  /// Trailing window stored on a history entry and shown as "current".
  static let snapshotDays = 28

  /// ISO-8601 calendar (Monday first, four-day minimum), in the current time zone.
  static var isoCalendar: Calendar {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = .current
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
  }

  /// Rejected spellings from `X (not "Y")` / `X (nicht "Y, Z")` annotations.
  ///
  /// The keyword match is case-insensitive. The inner list is comma-separated, and each form is
  /// trimmed of spaces and `"` / `'`. Same pattern as SpeechService:
  /// `#"\((?:not|nicht)\s+[^)]*\)"#`. Deduplicated by folded form (case- and diacritic-insensitive);
  /// the first spelling is kept, in order of first appearance.
  static func rejectedSpellings(in glossaries: [String]) -> [String] {
    var seen = Set<String>()
    var spellings: [String] = []
    for glossary in glossaries {
      for spelling in annotationSpellings(in: glossary) {
        let key = fold(spelling)
        guard seen.insert(key).inserted else { continue }
        spellings.append(spelling)
      }
    }
    return spellings
  }

  /// Whole-word occurrences of any rejected form in `text`.
  ///
  /// Matching is case- and diacritic-insensitive. A whole word is not preceded or followed by a
  /// letter or digit, and a multi-word form matches as a phrase. An occurrence covered by a longer
  /// matching form is counted once ("Cloud" inside "Cloud CLI" is one hit). An occurrence directly
  /// preceded by a capitalised word is not counted ("Google Cloud" is 0, "die Cloud" is 1): the
  /// rejected form is often a legitimate part of an established compound.
  static func rejectedSpellingHits(in text: String, rejected: [String]) -> Int {
    guard !text.isEmpty else { return 0 }
    var ranges: [Range<String.Index>] = []
    for form in rejected {
      let trimmed = form.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      var search = text.startIndex..<text.endIndex
      while let match = text.range(
        of: trimmed,
        options: [.caseInsensitive, .diacriticInsensitive],
        range: search,
        locale: matchLocale
      ) {
        if isWholeWord(match, in: text), !precededByCapitalisedWord(match, in: text) {
          ranges.append(match)
        }
        guard match.upperBound > match.lowerBound, match.upperBound < text.endIndex else { break }
        search = match.upperBound..<text.endIndex
      }
    }
    let unique = Array(Set(ranges))
    return unique.filter { range in
      !unique.contains { other in
        other.lowerBound <= range.lowerBound && other.upperBound >= range.upperBound
          && (other.lowerBound < range.lowerBound || other.upperBound > range.upperBound)
      }
    }.count
  }

  /// Word-level similarity in `0...1`.
  ///
  /// Both sides are folded (case and diacritics), punctuation is dropped, whitespace is collapsed,
  /// and the strings are split on spaces. The result is `1 - levenshtein(words) / max(wordCount)`.
  /// Two empty strings are 0. When the shorter word list is under `followUpSimilarity` of the
  /// longer one, the result is 0 without running the edit distance.
  static func similarity(_ a: String, _ b: String) -> Double {
    let wordsA = normalisedWords(a)
    let wordsB = normalisedWords(b)
    if wordsA.isEmpty && wordsB.isEmpty { return 0 }
    let maxCount = max(wordsA.count, wordsB.count)
    let minCount = min(wordsA.count, wordsB.count)
    if Double(minCount) / Double(maxCount) < followUpSimilarity { return 0 }
    let distance = levenshtein(wordsA, wordsB)
    return 1 - Double(distance) / Double(maxCount)
  }

  /// Counts for entries whose `ts` falls in `[from, to)`.
  ///
  /// `ts` is ISO-8601, with or without fractional seconds. Unparsable rows are skipped.
  /// A prompt P is a follow-up of the immediately previous prompt Q (the previous prompt in the
  /// whole list, not only those inside the window) when `0 <= P.ts - Q.ts <= followUpWindow`,
  /// P's selection is non-empty after trimming, and
  /// `similarity(P.selectedText, Q.modelResponse) >= followUpSimilarity`.
  /// Pass every entry and let `from` / `to` decide what is counted.
  static func metrics(
    interactions: [InteractionLogEntry],
    signals: [SignalLogEntry],
    rejected: [String],
    from: Date,
    to: Date
  ) -> ScorecardMetrics {
    let parsed = interactions.compactMap { entry -> (entry: InteractionLogEntry, date: Date)? in
      guard let date = parseTimestamp(entry.ts) else { return nil }
      return (entry, date)
    }
    let prompts = parsed
      .filter { $0.entry.mode == "prompt" }
      .sorted { $0.date < $1.date }
    var followUp = Array(repeating: false, count: prompts.count)
    if prompts.count > 1 {
      for index in 1..<prompts.count {
        let gap = prompts[index].date.timeIntervalSince(prompts[index - 1].date)
        guard gap >= 0, gap <= followUpWindow else { continue }
        let selection = (prompts[index].entry.selectedText ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { continue }
        let previousResponse = prompts[index - 1].entry.modelResponse ?? ""
        if similarity(selection, previousResponse) >= followUpSimilarity {
          followUp[index] = true
        }
      }
    }

    var metrics = ScorecardMetrics()
    for item in parsed where item.date >= from && item.date < to {
      switch item.entry.mode {
      case "transcription":
        metrics.transcriptions += 1
        metrics.rejectedSpellingHits += rejectedSpellingHits(in: item.entry.result ?? "", rejected: rejected)
      case "geminiChat":
        metrics.chatTurns += 1
      default:
        break
      }
    }
    for (index, item) in prompts.enumerated() where item.date >= from && item.date < to {
      metrics.prompts += 1
      if followUp[index] { metrics.promptFollowUps += 1 }
      let selection = item.entry.selectedText ?? ""
      let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !containsEmOrEnDash(selection) else { continue }
      metrics.dashFreeSelections += 1
      if containsEmOrEnDash(item.entry.modelResponse ?? "") {
        metrics.dashesInserted += 1
      }
    }
    for signal in signals {
      guard let date = parseTimestamp(signal.ts), date >= from, date < to else { continue }
      switch signal.kind {
      case "promptRetry": metrics.promptRetries += 1
      case "chatRetry": metrics.chatRetries += 1
      default: break
      }
    }
    return metrics
  }

  /// One week per ISO week that has at least one interaction or signal, oldest first.
  static func weeks(
    interactions: [InteractionLogEntry],
    signals: [SignalLogEntry],
    rejected: [String],
    calendar: Calendar = SmartImprovementScorecard.isoCalendar
  ) -> [ScorecardWeek] {
    var starts: [String: Date] = [:]
    func note(_ ts: String) {
      guard let date = parseTimestamp(ts),
            let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return }
      let id = weekID(interval.start, calendar: calendar)
      if starts[id] == nil { starts[id] = interval.start }
    }
    for entry in interactions { note(entry.ts) }
    for signal in signals { note(signal.ts) }

    return starts.keys.sorted().compactMap { id in
      guard let start = starts[id],
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
      return ScorecardWeek(
        id: id,
        start: start,
        metrics: metrics(
          interactions: interactions, signals: signals, rejected: rejected, from: start, to: end)
      )
    }
  }

  /// Everything the review UI needs, read from a UserContext directory.
  struct Report: Equatable, Sendable {
    /// The last `weekCount` weeks that have data, oldest first.
    let weeks: [ScorecardWeek]
    /// Trailing `snapshotDays` ending at `now`.
    let current: ScorecardMetrics
    /// Newest history entry that carries a scorecard.
    let lastChange: Change?

    struct Change: Equatable, Sendable {
      let ts: Date
      /// `SystemPromptSection` raw value.
      let section: String
      /// `"auto"`, `"voice-feedback"`, `"chat"`, and the other history sources.
      let source: String
      /// Snapshot stored with that history entry.
      let before: ScorecardMetrics
      /// Counts from that entry's timestamp until now.
      let after: ScorecardMetrics
    }
  }

  /// Reads the last `lastDays` of interaction and signal files, plus `system-prompts-history.jsonl`.
  ///
  /// Rejected forms come from `currentGlossary` and every `whisperGlossary` history entry, so a
  /// form a later merge dropped still counts. `section` limits `lastChange` to that section; nil
  /// takes the newest scorecard of any section. A missing directory or file is an empty report.
  static func report(
    directory: URL,
    currentGlossary: String,
    section: String? = nil,
    weekCount: Int = 6,
    lastDays: Int = 90,
    now: Date = Date()
  ) -> Report {
    let loaded = load(directory: directory, lastDays: lastDays, now: now)
    let rejected = rejectedForms(currentGlossary: currentGlossary, history: loaded.history)
    let allWeeks = weeks(
      interactions: loaded.interactions, signals: loaded.signals, rejected: rejected)
    let shown = weekCount > 0 ? Array(allWeeks.suffix(weekCount)) : []
    let current = metrics(
      interactions: loaded.interactions,
      signals: loaded.signals,
      rejected: rejected,
      from: now.addingTimeInterval(-Double(snapshotDays) * 86_400),
      to: now)
    let lastChange = newestChange(
      history: loaded.history,
      section: section,
      interactions: loaded.interactions,
      signals: loaded.signals,
      rejected: rejected,
      now: now)
    return Report(weeks: shown, current: current, lastChange: lastChange)
  }

  /// Snapshot stored with a history entry: metrics over `[now - snapshotDays, now)`.
  static func snapshot(directory: URL, currentGlossary: String, now: Date = Date()) -> ScorecardMetrics {
    let loaded = load(directory: directory, lastDays: snapshotDays + 2, now: now)
    let rejected = rejectedForms(currentGlossary: currentGlossary, history: loaded.history)
    return metrics(
      interactions: loaded.interactions,
      signals: loaded.signals,
      rejected: rejected,
      from: now.addingTimeInterval(-Double(snapshotDays) * 86_400),
      to: now)
  }

  // MARK: - Glossary annotations

  private static let annotationPattern = #"\((?:not|nicht)\s+[^)]*\)"#
  private static let matchLocale = Locale(identifier: "en_US_POSIX")
  /// Em dash and en dash. Hyphen-minus is ordinary punctuation and is not a dash here.
  private static let dashCharacters: Set<Character> = ["\u{2014}", "\u{2013}"]

  private static func annotationSpellings(in glossary: String) -> [String] {
    var spellings: [String] = []
    var cursor = glossary[...]
    while let range = cursor.range(
      of: annotationPattern, options: [.regularExpression, .caseInsensitive])
    {
      let inner = cursor[range]
        .replacingOccurrences(
          of: #"^\((?:not|nicht)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: ")", with: "")
      for form in inner.components(separatedBy: ",") {
        let cleaned = form.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        if !cleaned.isEmpty { spellings.append(cleaned) }
      }
      cursor = cursor[range.upperBound...]
    }
    return spellings
  }

  private static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: matchLocale)
  }

  private static func isWholeWord(_ match: Range<String.Index>, in text: String) -> Bool {
    if match.lowerBound > text.startIndex {
      let previous = text[text.index(before: match.lowerBound)]
      if previous.isLetter || previous.isNumber { return false }
    }
    if match.upperBound < text.endIndex {
      let next = text[match.upperBound]
      if next.isLetter || next.isNumber { return false }
    }
    return true
  }

  /// True when the token immediately before `match` begins with an uppercase letter.
  /// Punctuation, digits, and the start of the text are not a preceding word.
  private static func precededByCapitalisedWord(_ match: Range<String.Index>, in text: String) -> Bool {
    var index = match.lowerBound
    while index > text.startIndex {
      let previous = text.index(before: index)
      if text[previous].isWhitespace {
        index = previous
        continue
      }
      break
    }
    guard index > text.startIndex else { return false }
    var wordStart = text.index(before: index)
    guard text[wordStart].isLetter else { return false }
    while wordStart > text.startIndex {
      let previous = text.index(before: wordStart)
      guard text[previous].isLetter else { break }
      wordStart = previous
    }
    return text[wordStart].isUppercase
  }

  private static func containsEmOrEnDash(_ text: String) -> Bool {
    text.contains { dashCharacters.contains($0) }
  }

  // MARK: - Similarity

  private static func normalisedWords(_ text: String) -> [String] {
    let folded = fold(text)
    let cleaned = String(folded.map { $0.isPunctuation ? " " : $0 })
    return cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  private static func levenshtein(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
        current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }

  // MARK: - Timestamps and weeks

  private static let fractionalTimestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let plainTimestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

  private static func parseTimestamp(_ ts: String) -> Date? {
    if let date = try? Date(ts, strategy: fractionalTimestamp) { return date }
    return try? Date(ts, strategy: plainTimestamp)
  }

  private static func weekID(_ date: Date, calendar: Calendar) -> String {
    let year = calendar.component(.yearForWeekOfYear, from: date)
    let week = calendar.component(.weekOfYear, from: date)
    return String(format: "%04d-W%02d", year, week)
  }

  // MARK: - Disk

  private struct LoadedLogs {
    var interactions: [InteractionLogEntry] = []
    var signals: [SignalLogEntry] = []
    var history: [UnifiedSystemPromptHistoryEntry] = []
  }

  private static func load(directory: URL, lastDays: Int, now: Date) -> LoadedLogs {
    var loaded = LoadedLogs()
    for url in logFileURLs(directory: directory, prefix: "interactions-", lastDays: lastDays, now: now) {
      loaded.interactions.append(contentsOf: decodeJSONL(url))
    }
    for url in logFileURLs(directory: directory, prefix: "signals-", lastDays: lastDays, now: now) {
      loaded.signals.append(contentsOf: decodeJSONL(url))
    }
    loaded.history = decodeJSONL(directory.appendingPathComponent("system-prompts-history.jsonl"))
    return loaded
  }

  private static func rejectedForms(
    currentGlossary: String, history: [UnifiedSystemPromptHistoryEntry]
  ) -> [String] {
    var glossaries = [currentGlossary]
    for entry in history where entry.section == SystemPromptSection.whisperGlossary.rawValue {
      glossaries.append(entry.content)
    }
    return rejectedSpellings(in: glossaries)
  }

  private static func newestChange(
    history: [UnifiedSystemPromptHistoryEntry],
    section: String?,
    interactions: [InteractionLogEntry],
    signals: [SignalLogEntry],
    rejected: [String],
    now: Date
  ) -> Report.Change? {
    var best: (entry: UnifiedSystemPromptHistoryEntry, date: Date)?
    for entry in history {
      guard entry.scorecard != nil else { continue }
      if let section, entry.section != section { continue }
      guard let date = parseTimestamp(entry.ts) else { continue }
      if let current = best, date < current.date { continue }
      best = (entry, date)
    }
    guard let best, let before = best.entry.scorecard else { return nil }
    let after = metrics(
      interactions: interactions,
      signals: signals,
      rejected: rejected,
      from: best.date,
      to: now)
    return Report.Change(
      ts: best.date,
      section: best.entry.section,
      source: best.entry.source,
      before: before,
      after: after)
  }

  /// Daily `prefixYYYY-MM-DD.jsonl` files, same filename date as `ContextLogger.logFiles`.
  private static func logFileURLs(directory: URL, prefix: String, lastDays: Int, now: Date) -> [URL] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    let cutoff = Calendar.current.date(byAdding: .day, value: -lastDays, to: now) ?? now
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    return contents.filter { url in
      let name = url.lastPathComponent
      guard name.hasPrefix(prefix), name.hasSuffix(".jsonl") else { return false }
      let dateString = String(name.dropFirst(prefix.count).dropLast(".jsonl".count))
      guard let fileDate = formatter.date(from: dateString) else { return false }
      return fileDate >= cutoff
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func decodeJSONL<T: Decodable>(_ url: URL) -> [T] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let decoder = JSONDecoder()
    var rows: [T] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
      guard let row = try? decoder.decode(T.self, from: data) else { continue }
      rows.append(row)
    }
    return rows
  }
}

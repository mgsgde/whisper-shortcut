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
  /// Read through `GlossaryDocument`, which is the same annotation parse the prompt uses.
  /// A private copy of the regex here used to be able to disagree with it. Deduplicated by
  /// folded form; the first spelling is kept, in order of first appearance.
  static func rejectedSpellings(in glossaries: [String]) -> [String] {
    var seen = Set<String>()
    var spellings: [String] = []
    for glossary in glossaries {
      for line in glossary.components(separatedBy: .newlines) {
        for spelling in GlossaryDocument.rejectedSpellings(on: line) {
          let key = GlossaryDocument.fold(spelling)
          guard seen.insert(key).inserted else { continue }
          spellings.append(spelling)
        }
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

  /// Counts for entries whose `ts` falls in `[from, to)`.
  ///
  /// `ts` is ISO-8601, with or without fractional seconds. Unparsable rows are skipped.
  /// A prompt P is a follow-up of the immediately previous prompt Q (the previous prompt in the
  /// whole list, not only those inside the window) when `PromptFollowUp.isFollowUp` says so —
  /// the same predicate that emits the `promptFollowUp` signal. A private word-Levenshtein
  /// cutoff of 0.8 used to count a different set.
  /// Pass every entry and let `from` / `to` decide what is counted.
  static func metrics(
    interactions: [InteractionLogEntry],
    signals: [SignalLogEntry],
    rejected: [String],
    from: Date,
    to: Date
  ) -> ScorecardMetrics {
    let parsed = interactions.compactMap { entry -> (entry: InteractionLogEntry, date: Date)? in
      guard let date = UserContextLog.timestamp(entry.ts) else { return nil }
      return (entry, date)
    }
    let prompts = parsed
      .filter { $0.entry.mode == "prompt" }
      .sorted { $0.date < $1.date }
    var followUp = Array(repeating: false, count: prompts.count)
    if prompts.count > 1 {
      for index in 1..<prompts.count {
        let gap = prompts[index].date.timeIntervalSince(prompts[index - 1].date)
        followUp[index] = PromptFollowUp.isFollowUp(
          selection: prompts[index].entry.selectedText ?? "",
          previousResponse: prompts[index - 1].entry.modelResponse ?? "",
          gap: gap)
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
      guard let date = UserContextLog.timestamp(signal.ts), date >= from, date < to else { continue }
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
      guard let date = UserContextLog.timestamp(ts),
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

  private static let matchLocale = Locale(identifier: "en_US_POSIX")
  /// Em dash and en dash. Hyphen-minus is ordinary punctuation and is not a dash here.
  private static let dashCharacters: Set<Character> = ["\u{2014}", "\u{2013}"]

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

  // MARK: - Timestamps and weeks

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
    loaded.interactions = UserContextLog.decodeLines(
      UserContextLog.files(stream: .interactions, in: directory, lastDays: lastDays, now: now),
      as: InteractionLogEntry.self)
    loaded.signals = UserContextLog.decodeLines(
      UserContextLog.files(stream: .signals, in: directory, lastDays: lastDays, now: now),
      as: SignalLogEntry.self)
    loaded.history = UserContextLog.decodeLines(
      [directory.appendingPathComponent("system-prompts-history.jsonl")],
      as: UnifiedSystemPromptHistoryEntry.self)
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
      guard let date = UserContextLog.timestamp(entry.ts) else { continue }
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

}

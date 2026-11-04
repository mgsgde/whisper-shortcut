import Foundation

/// How a chat or meeting row is named in the sidebar, the tab strip and search results.
///
/// The first-message title is what the app has always shown, and it stays the default: a chat
/// called "why does the build fail on CI" is easier to recognise than one called "2026-11-03".
/// Meeting notes and transcripts are the exception — there the date is the thing the user
/// remembers, and a row that starts with it sorts and scans like the transcript file it came
/// from (`Meeting-2026-11-03-103649`). So the date is an opt-in, not a new default.
///
/// The style is applied when a row is *displayed*, never written into the stored title: switching
/// back to `.firstMessage` has to give the user their old titles back, and a rename dialog has to
/// edit the topic rather than the date in front of it.
enum ChatTitleStyle: String, CaseIterable {
  /// Today's behaviour: the first user message, truncated.
  case firstMessage
  /// `2026-11-03 Topic`
  case dateTopic
  /// `2026-11-03`
  case dateOnly

  var displayName: String {
    switch self {
    case .firstMessage: return String(localized: "First message")
    case .dateTopic: return String(localized: "Date and topic")
    case .dateOnly: return String(localized: "Date only")
    }
  }

  /// Whether this style puts a date in front of the row. Used to decide whether a meeting may show
  /// its date before a summary title exists.
  var usesDatePrefix: Bool { self != .firstMessage }

  /// The style in effect right now.
  ///
  /// Read from UserDefaults on every call instead of cached: `displayTitle(for:)` asks once per
  /// sidebar row per render, and a dictionary lookup is far cheaper than the notification plumbing
  /// a cache would need to avoid showing a stale style after the user changes it in Settings.
  static var current: ChatTitleStyle {
    guard let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.chatTitleStyle),
          let style = ChatTitleStyle(rawValue: raw)
    else { return SettingsDefaults.chatTitleStyle }
    return style
  }

  // MARK: - Formatting

  /// `yyyy-MM-dd` — the same shape the meeting transcript stems use, so a row and its file sort
  /// the same way. Cached because `displayTitle(for:)` runs for every row on every render and
  /// allocating a `DateFormatter` there would cost more than the layout it feeds.
  ///
  /// `en_US_POSIX` + Gregorian keeps the digits ASCII and the field order fixed even for a user on
  /// a non-Gregorian system calendar; the time zone stays the user's own, so a meeting recorded at
  /// 23:30 local time is dated the day the user experienced.
  private static let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  static func dayString(from date: Date) -> String { dayFormatter.string(from: date) }

  /// The date a session's row should carry.
  ///
  /// A meeting takes it from its transcript stem, not from `lastUpdated`: the stem is when the
  /// meeting happened, while `lastUpdated` moves every time the user asks a follow-up question
  /// about it — a note from Tuesday must not be dated Thursday because it was read again.
  static func date(for session: ChatSession) -> Date {
    if let stem = session.meetingStem, let meetingDate = MeetingListService.date(fromStem: stem) {
      return meetingDate
    }
    return session.lastUpdated
  }

  /// Applies `style` to an already-derived topic title.
  ///
  /// `topic` is what the row would show without a date style (nil when there is nothing yet), so
  /// this is the single place that decides the final text — every caller keeps deriving the topic
  /// exactly as before. Returns nil only for `.firstMessage` with no topic, where the caller still
  /// has to choose between "New chat" and "Meeting".
  static func title(topic: String?, date: Date, style: ChatTitleStyle) -> String? {
    switch style {
    case .firstMessage:
      return topic
    case .dateOnly, .dateTopic:
      return datedTitle(topic: topic, date: date, style: style)
    }
  }

  /// The date-style text. Non-optional by construction: a date style always has at least the day,
  /// which is exactly why it can name a meeting before its summary title exists.
  static func datedTitle(topic: String?, date: Date, style: ChatTitleStyle) -> String {
    let day = dayString(from: date)
    guard style == .dateTopic, let topic, !topic.isEmpty else { return day }
    return "\(day) \(topic)"
  }

  // MARK: - Project names

  /// Words that make a capitalised phrase *look* like a proper noun without being one: sentence
  /// openers and function words, weekdays and months, and the vocabulary every meeting shares.
  /// A candidate made only of these is rejected, which is what keeps "Das Meeting" and
  /// "Die Migration" out of the title.
  private static let projectStopWords: Set<String> = [
    // German function words and sentence openers
    "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "eines",
    "und", "oder", "aber", "denn", "weil", "wenn", "dass", "ich", "wir", "sie", "er", "es",
    "ihr", "du", "man", "heute", "morgen", "gestern", "jetzt", "dann", "hier", "dort",
    "ja", "nein", "okay", "ok", "also", "gut", "super", "danke", "bitte", "hallo", "hi",
    // English function words and sentence openers
    "the", "a", "an", "and", "or", "but", "so", "we", "i", "you", "they", "he", "she", "it",
    "this", "that", "these", "those", "today", "tomorrow", "yesterday", "now", "then",
    "yes", "no", "hello", "thanks", "please",
    // weekdays and months
    "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag",
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    "januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september",
    "oktober", "november", "dezember",
    "january", "february", "march", "may", "june", "july", "october", "december",
    // meeting vocabulary
    "meeting", "call", "termin", "besprechung", "team", "update", "review", "sprint",
    "daily", "standup", "kickoff", "retro", "retrospektive", "workshop", "onboarding",
    "agenda", "protokoll", "notizen", "notes", "summary", "zusammenfassung", "projekt",
    "project", "management", "planung", "planning", "status", "frage", "fragen", "punkt",
    "punkte", "thema", "themen", "topic", "next", "steps", "action", "items",
  ]

  /// `Projekt X` / `Project X` — the one form that is unambiguous enough to trust on a single
  /// mention. The capture stays case-sensitive: a lowercase word after "Projekt" is a sentence,
  /// not a name.
  /// Same `[ \t]+` separator rule as `capitalisedPhraseRegex`: a newline after "Projekt" is a
  /// line break, not a name.
  private static let explicitProjectRegex = try! NSRegularExpression(
    pattern: #"(?i:\b(?:projekt|project))[ \t]+([A-ZÄÖÜ][\p{L}\p{N}&+_-]*(?:[ \t]+[A-ZÄÖÜ][\p{L}\p{N}&+_-]*){0,2})"#)

  /// A capitalised phrase of one to three words — the raw material for the repetition scan.
  ///
  /// No `.` in the token class: it would let "Zeit. ParkDepot" match as a single two-word phrase
  /// across a sentence boundary, which both hides the real name and invents a fake one. The
  /// separator is `[ \t]+`, not `\s+`: `\s` matches a newline, so a transcript line ending in
  /// "Die Migration" would join the next line's capitalised word into one invented phrase.
  private static let capitalisedPhraseRegex = try! NSRegularExpression(
    pattern: #"[A-ZÄÖÜ][\p{L}\p{N}&+_-]*(?:[ \t]+[A-ZÄÖÜ][\p{L}\p{N}&+_-]*){0,2}"#)

  /// A conservative guess at the project, product or client a text is about.
  ///
  /// This is a heuristic, not entity recognition. It knows exactly two signals:
  ///
  /// 1. an explicit `Projekt X` / `Project X` mention, trusted on a single occurrence;
  /// 2. a capitalised phrase the text *repeats* — at least twice — which is either two or three
  ///    words ("Park Depot") or a single CamelCase / all-caps token ("ParkDepot", "SAP").
  ///
  /// Everything else returns nil, and the caller falls back to a generated title. That asymmetry is
  /// deliberate: a wrong project name in a sidebar is worse than no project name, so the function
  /// stays silent whenever it is not sure. It does not know that "New York" is a place rather than
  /// a client, it does not resolve pronouns or abbreviations, and it only looks at the text it is
  /// handed — no transcript file, no chat history, no model.
  static func projectName(in text: String) -> String? {
    explicitProjectName(in: text) ?? repeatedProjectName(in: text)
  }

  /// Only the `Projekt X` / `Project X` form: a name the user said outright, as opposed to one the
  /// repetition scan inferred. Callers use it to protect an explicit name from being overwritten.
  static func explicitProjectName(in text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let full = NSRange(location: 0, length: (trimmed as NSString).length)
    if let match = explicitProjectRegex.firstMatch(in: trimmed, range: full),
       let range = Range(match.range(at: 1), in: trimmed) {
      let name = cleanProjectCandidate(String(trimmed[range]))
      if isPlausibleProjectName(name) { return name }
    }
    return nil
  }

  private static func repeatedProjectName(in text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let ns = trimmed as NSString
    let full = NSRange(location: 0, length: ns.length)

    // The explicit form is handled by `explicitProjectName`; here: : a capitalised phrase the text repeats. Counting is what separates a name the
    //    speaker keeps using from a noun that merely happened to start a sentence.
    var counts: [String: (count: Int, firstLocation: Int, tokens: Int)] = [:]
    for match in capitalisedPhraseRegex.matches(in: trimmed, range: full) {
      guard let range = Range(match.range, in: trimmed) else { continue }
      let name = cleanProjectCandidate(String(trimmed[range]))
      guard isPlausibleProjectName(name) else { continue }
      if var entry = counts[name] {
        entry.count += 1
        counts[name] = entry
      } else {
        counts[name] = (1, match.range.location, name.split(separator: " ").count)
      }
    }
    return counts
      .filter { $0.value.count >= 2 }
      .filter { $0.value.tokens >= 2 || isCamelOrAcronym($0.key) }
      .sorted {
        if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
        if $0.value.tokens != $1.value.tokens { return $0.value.tokens > $1.value.tokens }
        return $0.value.firstLocation < $1.value.firstLocation
      }
      .first?.key
  }

  /// Trims punctuation and leading function words off a raw match, so "Die Migration" and
  /// "Migration" count as the same candidate.
  private static func cleanProjectCandidate(_ raw: String) -> String {
    var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'„“”()[]"))
    var tokens = name.split(separator: " ").map(String.init)
    while tokens.count > 1, let first = tokens.first,
          projectStopWords.contains(first.lowercased()) {
      tokens.removeFirst()
    }
    while tokens.count > 1, let last = tokens.last,
          projectStopWords.contains(last.lowercased()) {
      tokens.removeLast()
    }
    return tokens.joined(separator: " ")
  }

  /// A candidate survives only if at least one of its words is not meeting or function vocabulary.
  private static func isPlausibleProjectName(_ name: String) -> Bool {
    let tokens = name.split(separator: " ").map(String.init)
    guard !tokens.isEmpty, tokens.count <= 3, name.count >= 2 else { return false }
    return tokens.contains { !projectStopWords.contains($0.lowercased()) }
  }

  /// A single token is only trusted when its shape says "name": all caps ("SAP") or an internal
  /// capital ("ParkDepot", "iPhone"). A plain capitalised word ("Magnus") is a person or a noun far
  /// more often than a project.
  private static func isCamelOrAcronym(_ name: String) -> Bool {
    guard !name.contains(" ") else { return false }
    let letters = name.filter(\.isLetter)
    guard letters.count >= 2 else { return false }
    if letters.allSatisfy({ $0.isUppercase }) { return true }
    return name.dropFirst().contains(where: { $0.isUppercase })
  }
}

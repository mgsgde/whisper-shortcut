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
}

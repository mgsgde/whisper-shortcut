import Foundation

/// One shared "when is it?" line for every prompt that needs a clock.
///
/// The chat, the meeting context and the title generator all ask the model to reason about time
/// ("what's left today?", "what did we agree last Tuesday?", "Planning — November"). Each of them
/// used to either carry no date at all or a hand-rolled one, so a transcript from last week and a
/// question asked now looked identical to the model.
///
/// The text is model input, not UI, so the wording stays English while the *values* follow the
/// caller's locale (weekday and month names) and time zone. `now`, `timeZone` and `locale` are
/// parameters rather than reads of the global state so the output is testable.
enum ChatDateContext {

  /// Label used for the line injected into the chat system instruction and the title prompts.
  static let currentLabel = "Current date and time"

  /// Compact line with weekday, full date, time and time zone identifier, e.g.
  /// `Current date and time: Wednesday, November 4, 2026, 17:42 (Europe/Berlin).`
  static func line(
    now: Date = Date(),
    timeZone: TimeZone = .current,
    locale: Locale = .current
  ) -> String {
    line(label: currentLabel, at: now, timeZone: timeZone, locale: locale)
  }

  /// Same line with a caller-chosen label, for a moment that is not "now" — a meeting that
  /// started at 14:30, for instance: `Meeting started: Wednesday, November 4, 2026, 14:30 (…).`
  static func line(
    label: String,
    at date: Date,
    timeZone: TimeZone = .current,
    locale: Locale = .current
  ) -> String {
    "\(label): \(dateText(date, timeZone: timeZone, locale: locale)), "
      + "\(timeText(date, timeZone: timeZone, locale: locale)) (\(timeZone.identifier))."
  }

  /// Line for a saved meeting, dated from its `Meeting-YYYY-MM-DD-HHMMSS` stem. Returns nil when
  /// the stem does not parse — an undated meeting is better than an invented date.
  static func meetingLine(
    stem: String,
    label: String = "Meeting date and time",
    timeZone: TimeZone = .current,
    locale: Locale = .current
  ) -> String? {
    guard let started = MeetingListService.date(fromStem: stem) else { return nil }
    return line(label: label, at: started, timeZone: timeZone, locale: locale)
  }

  /// Weekday plus full date. A template (not a fixed pattern) keeps the field order and the
  /// separators right in every locale: "Wednesday, November 4, 2026" vs "Mittwoch, 4. November 2026".
  private static func dateText(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.setLocalizedDateFormatFromTemplate("EEEEyMMMMd")
    return formatter.string(from: date)
  }

  /// 24-hour clock, so "17:42" cannot be misread as "7:42" in a prompt the model only sees as text.
  private static func timeText(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }
}

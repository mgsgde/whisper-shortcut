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
  ///
  /// Use this where the exact minute matters: a meeting that started at 14:30, a transcript line.
  /// For a prompt prefix use `stableLine` instead — see its doc comment.
  static func line(
    now: Date = Date(),
    timeZone: TimeZone = .current,
    locale: Locale = .current
  ) -> String {
    line(label: currentLabel, at: now, timeZone: timeZone, locale: locale)
  }

  /// Day-granularity line for the **top** of a system prompt: weekday, date and zone, no clock
  /// time, e.g. `Current date: Wednesday, November 4, 2026 (Europe/Berlin).`
  ///
  /// The prompt prefix is what providers cache (Anthropic's `cache_control` breakpoints, OpenAI's
  /// `prompt_cache_key`, Gemini's implicit prefix cache). A minute-precision time in that prefix
  /// changes the cached bytes every 60 seconds, so every turn pays full input price for the system
  /// prompt *and* the tool definitions that follow it. A date changes once a day, which keeps the
  /// prefix reusable; the clock time goes at the end of the prompt (`timeOfDayLine`), where the
  /// volatile tail already lives.
  static func stableLine(
    now: Date = Date(),
    timeZone: TimeZone = .current,
    locale: Locale = .current
  ) -> String {
    "Current date: \(dateText(now, timeZone: timeZone, locale: locale)) (\(timeZone.identifier))."
  }

  /// The clock time on its own, for the volatile tail of a system prompt.
  static func timeOfDayLine(
    now: Date = Date(),
    timeZone: TimeZone = .current,
    locale: Locale = .current
  ) -> String {
    "Current time: \(timeText(now, timeZone: timeZone, locale: locale)) (\(timeZone.identifier))."
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

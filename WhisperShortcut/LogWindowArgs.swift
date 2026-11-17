import Foundation

/// The arguments every log-reading tool shares: `limit` and `since`. `InteractionLogQuery`
/// (`get_recent_interactions`) and `ConfigHistoryQuery` (`get_config_history`) both parse them
/// here, so the clamping, the accepted `since` forms and the error text cannot drift apart.
struct LogWindowArgs: Equatable {
  var limit: Int
  /// Only rows at or after this moment; nil = the caller's default window.
  var since: Date?

  static let sinceError = "since must be a date (2026-10-01), an ISO-8601 timestamp, or a relative 14d / 48h."

  /// Clamps `limit` to 1...`maxLimit` and parses `since`. A malformed `since` returns an error
  /// message for the model instead of silently widening the read.
  static func parse(
    _ args: [String: Any], defaultLimit: Int, maxLimit: Int, now: Date = Date()
  ) -> (value: LogWindowArgs?, error: String?) {
    var out = LogWindowArgs(
      limit: min(max(ChatToolRegistry.intArgument(args, "limit", default: defaultLimit), 1), maxLimit),
      since: nil)
    if let raw = args["since"] as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
      guard let date = parseSince(raw, now: now) else { return (nil, sinceError) }
      out.since = date
    }
    return (out, nil)
  }

  /// `since` as a date: `2026-10-01`, a full ISO-8601 timestamp, or a relative `14d` / `48h`.
  static func parseSince(_ raw: String, now: Date = Date()) -> Date? {
    let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard !text.isEmpty else { return nil }
    if text.range(of: #"^\d{1,4}\s*[dh]$"#, options: .regularExpression) != nil,
      let unit = text.last, let amount = Int(text.dropLast().trimmingCharacters(in: .whitespaces))
    {
      let component: Calendar.Component = unit == "d" ? .day : .hour
      return Calendar.current.date(byAdding: component, value: -amount, to: now)
    }
    if let stamp = UserContextLog.timestamp(raw.trimmingCharacters(in: .whitespaces)) { return stamp }
    if text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
      // A plain day means the start of that day where the user is.
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.timeZone = .current
      formatter.dateFormat = "yyyy-MM-dd"
      return formatter.date(from: text)
    }
    return nil
  }

  /// Whether a row stamped `ts` is inside the window. No `since` keeps every row; with one, a row
  /// whose timestamp cannot be read is left out rather than guessed into the window.
  static func isAtOrAfter(since: Date?, ts: String) -> Bool {
    guard let since else { return true }
    guard let date = UserContextLog.timestamp(ts), date >= since else { return false }
    return true
  }

  /// `text` cut to `limit` characters plus an ellipsis, unchanged when it fits.
  static func cap(_ text: String, to limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit)) + "…" : text
  }
}

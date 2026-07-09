import Foundation

actor GoogleCalendarAPIClient {
  static let shared = GoogleCalendarAPIClient()

  private let baseURL = "https://www.googleapis.com/calendar/v3"
  private let maxResultsCap = 50

  /// Guards against accidental duplicate creates: maps a (summary|start|end)
  /// key to the event created for it and when. A repeated identical create
  /// within `dedupWindow` returns the existing event instead of POSTing again.
  private var recentCreates: [String: (id: String, at: Date)] = [:]
  private let dedupWindow: TimeInterval = 60

  // MARK: - List Events

  func listEvents(maxResults: Int = 10, hoursAhead: Int = 168, hoursBack: Int = 0) async throws -> [[String: Any]] {
    DebugLogger.logNetwork("GOOGLE-CALENDAR: listEvents maxResults=\(maxResults) hoursAhead=\(hoursAhead) hoursBack=\(hoursBack)")
    let cappedMax = min(max(maxResults, 1), maxResultsCap)
    let now = Date()
    let past = now.addingTimeInterval(-TimeInterval(max(hoursBack, 0) * 3600))
    let future = now.addingTimeInterval(TimeInterval(max(hoursAhead, 0) * 3600))

    let formatter = ISO8601DateFormatter()
    let timeMin = formatter.string(from: past)
    let timeMax = formatter.string(from: future)

    guard var components = URLComponents(string: "\(baseURL)/calendars/primary/events") else {
      throw CalendarAPIError.invalidResponse
    }
    components.queryItems = [
      URLQueryItem(name: "maxResults", value: String(cappedMax)),
      URLQueryItem(name: "timeMin", value: timeMin),
      URLQueryItem(name: "timeMax", value: timeMax),
      URLQueryItem(name: "singleEvents", value: "true"),
      URLQueryItem(name: "orderBy", value: "startTime"),
    ]

    guard let url = components.url else {
      throw CalendarAPIError.invalidURL
    }

    let data = try await authorizedRequest(url: url, httpMethod: "GET")

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = json["items"] as? [[String: Any]]
    else {
      return []
    }

    let mapped = items.map { item in
      var event: [String: Any] = [:]
      if let summary = item["summary"] as? String { event["summary"] = summary }
      if let htmlLink = item["htmlLink"] as? String { event["html_link"] = htmlLink }
      if let id = item["id"] as? String { event["event_id"] = id }
      if let start = item["start"] as? [String: Any],
         let startStr = start["dateTime"] as? String ?? start["date"] as? String {
        event["start"] = startStr
      }
      if let end = item["end"] as? [String: Any],
         let endStr = end["dateTime"] as? String ?? end["date"] as? String {
        event["end"] = endStr
      }
      if let location = item["location"] as? String { event["location"] = location }
      if let description = item["description"] as? String { event["description"] = description }
      if let status = item["status"] as? String { event["status"] = status }
      return event
    }
    DebugLogger.logNetwork("GOOGLE-CALENDAR: listEvents returned \(mapped.count) events")
    return mapped
  }

  // MARK: - Create Event

  func createEvent(summary: String, startISO: String, endISO: String, timeZone: String,
                   location: String? = nil, description: String? = nil,
                   recurrence: [String]? = nil, allDay: Bool = false) async throws -> [String: Any] {
    DebugLogger.logNetwork("GOOGLE-CALENDAR: createEvent summary=\(summary) start=\(startISO) end=\(endISO) allDay=\(allDay) recurrence=\(recurrence ?? [])")

    let dedupKey = "\(summary)|\(startISO)|\(endISO)|\((recurrence ?? []).joined(separator: ","))"
    let now = Date()
    if let recent = recentCreates[dedupKey], now.timeIntervalSince(recent.at) < dedupWindow {
      DebugLogger.logWarning(
        "GOOGLE-CALENDAR: duplicate create suppressed for '\(summary)' — identical to event \(recent.id) created \(Int(now.timeIntervalSince(recent.at)))s ago")
      return ["ok": true, "event_id": recent.id, "summary": summary, "deduplicated": true]
    }

    guard let url = URL(string: "\(baseURL)/calendars/primary/events") else {
      throw CalendarAPIError.invalidResponse
    }

    var body: [String: Any] = ["summary": summary]
    body["start"] = try startEndField(isStart: true, iso: startISO, timeZone: timeZone, allDay: allDay)
    body["end"] = try startEndField(isStart: false, iso: endISO, timeZone: timeZone, allDay: allDay,
                                    startISO: startISO)
    if let location { body["location"] = location }
    if let description { body["description"] = description }
    if let recurrence = normalizedRecurrence(recurrence) { body["recurrence"] = recurrence }

    let bodyData = try JSONSerialization.data(withJSONObject: body)
    let data = try await authorizedRequest(url: url, httpMethod: "POST", body: bodyData)

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CalendarAPIError.invalidResponse
    }

    var result: [String: Any] = ["ok": true]
    if let id = json["id"] as? String { result["event_id"] = id }
    if let htmlLink = json["htmlLink"] as? String { result["html_link"] = htmlLink }
    if let summary = json["summary"] as? String { result["summary"] = summary }
    if let start = json["start"] as? [String: Any], let startDT = start["dateTime"] as? String {
      result["start"] = startDT
    }
    if let end = json["end"] as? [String: Any], let endDT = end["dateTime"] as? String {
      result["end"] = endDT
    }
    if let location = json["location"] as? String { result["location"] = location }
    if let description = json["description"] as? String { result["description"] = description }
    if let recurrence = json["recurrence"] as? [String] { result["recurrence"] = recurrence }
    if let start = json["start"] as? [String: Any], let startDate = start["date"] as? String {
      result["start"] = startDate
      result["all_day"] = true
    }
    if let end = json["end"] as? [String: Any], let endDate = end["date"] as? String {
      result["end"] = endDate
    }
    if let id = result["event_id"] as? String {
      recentCreates = recentCreates.filter { now.timeIntervalSince($0.value.at) < dedupWindow }
      recentCreates[dedupKey] = (id, now)
    }
    DebugLogger.logSuccess("GOOGLE-CALENDAR: created event id=\(result["event_id"] ?? "?")")
    return result
  }

  // MARK: - Update Event

  func updateEvent(eventId: String, summary: String? = nil, startISO: String? = nil,
                   endISO: String? = nil, timeZone: String? = nil,
                   location: String? = nil, description: String? = nil,
                   recurrence: [String]? = nil, allDay: Bool = false) async throws -> [String: Any] {
    DebugLogger.logNetwork("GOOGLE-CALENDAR: updateEvent id=\(eventId) allDay=\(allDay) recurrence=\(recurrence ?? [])")
    let tz = timeZone ?? TimeZone.current.identifier

    var body: [String: Any] = [:]
    if let summary { body["summary"] = summary }
    if let startISO {
      body["start"] = try startEndField(isStart: true, iso: startISO, timeZone: tz, allDay: allDay)
    }
    if let endISO {
      body["end"] = try startEndField(isStart: false, iso: endISO, timeZone: tz, allDay: allDay,
                                      startISO: startISO)
    }
    if let location { body["location"] = location }
    if let description { body["description"] = description }
    if let recurrence = normalizedRecurrence(recurrence) { body["recurrence"] = recurrence }
    guard !body.isEmpty else { throw CalendarAPIError.noFieldsToUpdate }

    let encoded = encodedPathComponent(eventId)
    guard let url = URL(string: "\(baseURL)/calendars/primary/events/\(encoded)") else {
      throw CalendarAPIError.invalidResponse
    }

    let bodyData = try JSONSerialization.data(withJSONObject: body)
    // PATCH updates only the supplied fields, leaving the rest of the event intact.
    let data: Data
    do {
      data = try await authorizedRequest(url: url, httpMethod: "PATCH", body: bodyData)
    } catch CalendarAPIError.notFound {
      // The id is wrong or the event was deleted. Return actionable guidance so the model
      // lists events to get a valid id instead of burning tool rounds retrying bad ids.
      DebugLogger.logWarning("GOOGLE-CALENDAR: updateEvent got 404 for id=\(eventId)")
      return [
        "error": "Event not found (404). The event_id is wrong or the event was deleted. Call google_calendar_list_events to get the exact current event_id (verbatim), then retry the update. Do not guess or transform IDs.",
        "event_id": eventId,
      ]
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CalendarAPIError.invalidResponse
    }

    var result: [String: Any] = ["ok": true]
    if let id = json["id"] as? String { result["event_id"] = id }
    if let htmlLink = json["htmlLink"] as? String { result["html_link"] = htmlLink }
    if let summary = json["summary"] as? String { result["summary"] = summary }
    if let start = json["start"] as? [String: Any], let startDT = start["dateTime"] as? String {
      result["start"] = startDT
    }
    if let end = json["end"] as? [String: Any], let endDT = end["dateTime"] as? String {
      result["end"] = endDT
    }
    if let location = json["location"] as? String { result["location"] = location }
    if let description = json["description"] as? String { result["description"] = description }
    if let recurrence = json["recurrence"] as? [String] { result["recurrence"] = recurrence }
    if let start = json["start"] as? [String: Any], let startDate = start["date"] as? String {
      result["start"] = startDate
      result["all_day"] = true
    }
    if let end = json["end"] as? [String: Any], let endDate = end["date"] as? String {
      result["end"] = endDate
    }
    DebugLogger.logSuccess("GOOGLE-CALENDAR: updated event id=\(result["event_id"] ?? "?")")
    return result
  }

  // MARK: - Delete Event

  func deleteEvent(eventId: String) async throws -> [String: Any] {
    DebugLogger.logNetwork("GOOGLE-CALENDAR: deleteEvent id=\(eventId)")
    let encoded = encodedPathComponent(eventId)
    guard let url = URL(string: "\(baseURL)/calendars/primary/events/\(encoded)") else {
      throw CalendarAPIError.invalidResponse
    }
    do {
      _ = try await authorizedRequest(url: url, httpMethod: "DELETE")
    } catch CalendarAPIError.notFound {
      // The event is already gone or the id is wrong. Return actionable guidance so the
      // model lists events to get valid ids instead of blindly retrying the same delete.
      DebugLogger.logWarning("GOOGLE-CALENDAR: deleteEvent got 404 for id=\(eventId)")
      return [
        "error": "Event not found (404). It may already be deleted, or the event_id is wrong. Call google_calendar_list_events to get current event IDs, then retry the delete with a valid id.",
        "event_id": eventId,
      ]
    }
    DebugLogger.logSuccess("GOOGLE-CALENDAR: deleted event id=\(eventId)")
    return ["ok": true, "event_id": eventId, "deleted": true]
  }

  // MARK: - Authorized Request

  private func authorizedRequest(url: URL, httpMethod: String, body: Data? = nil) async throws -> Data {
    let token = try await GoogleAccountOAuthService.shared.getValidAccessToken()

    var request = URLRequest(url: url)
    request.httpMethod = httpMethod
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw CalendarAPIError.invalidResponse
    }

    if httpResponse.statusCode == 401 {
      DebugLogger.logNetwork("GOOGLE-CALENDAR: 401, refreshing token and retrying")
      let newToken = try await GoogleAccountOAuthService.shared.refreshAccessToken()

      var retryRequest = request
      retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
      let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)

      guard let retryHTTP = retryResponse as? HTTPURLResponse else {
        throw CalendarAPIError.invalidResponse
      }
      guard (200..<300).contains(retryHTTP.statusCode) else {
        throw CalendarAPIError.requestFailed(retryHTTP.statusCode)
      }
      return retryData
    }

    if !(200..<300).contains(httpResponse.statusCode) {
      if httpResponse.statusCode == 404 {
        DebugLogger.logError("GOOGLE-CALENDAR: API error 404: event/resource not found")
        throw CalendarAPIError.notFound
      }
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let error = json["error"] as? [String: Any],
         let message = error["message"] as? String {
        DebugLogger.logError("GOOGLE-CALENDAR: API error \(httpResponse.statusCode): \(message)")
        throw CalendarAPIError.apiError(message)
      }
      throw CalendarAPIError.requestFailed(httpResponse.statusCode)
    }

    return data
  }

  // MARK: - Validation

  private func isValidISO8601(_ string: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: string) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string) != nil
  }

  /// Best-effort coercion of a model-supplied date/time string into a strict, offset-bearing
  /// ISO-8601 string. Accepts an already-valid string verbatim; otherwise interprets common
  /// near-ISO shapes — missing timezone offset, a space instead of `T`, no seconds, or date-only —
  /// in `timeZone` and re-emits a proper offset. Returns nil only when nothing matches, so the
  /// caller still fails cleanly on genuine garbage. This is what stops a slightly-off date (the
  /// model dropping the offset) from hard-failing a create/update with "Invalid date format".
  private func normalizeToISO8601(_ raw: String, timeZone: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if isValidISO8601(trimmed) { return trimmed }

    let tz = TimeZone(identifier: timeZone) ?? .current
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = tz
    let patterns = [
      "yyyy-MM-dd'T'HH:mm:ss",
      "yyyy-MM-dd'T'HH:mm",
      "yyyy-MM-dd HH:mm:ss",
      "yyyy-MM-dd HH:mm",
      "yyyy-MM-dd",
    ]
    for pattern in patterns {
      parser.dateFormat = pattern
      if let date = parser.date(from: trimmed) {
        let out = ISO8601DateFormatter()
        out.timeZone = tz
        out.formatOptions = [.withInternetDateTime]
        return out.string(from: date)
      }
    }
    return nil
  }

  /// Builds a Google Calendar `start`/`end` object. For timed events it emits
  /// `{dateTime, timeZone}` after coercing the model's near-ISO string into a strict
  /// offset-bearing one. For all-day events it emits `{date: "yyyy-MM-dd"}`; the `end`
  /// date is exclusive per the Calendar API, so a single all-day event whose end is not
  /// strictly after the start is bumped to the day after the start.
  private func startEndField(isStart: Bool, iso: String, timeZone: String, allDay: Bool,
                             startISO: String? = nil) throws -> [String: Any] {
    if allDay {
      guard var date = dateOnly(iso, timeZone: timeZone) else { throw CalendarAPIError.invalidDateFormat }
      if !isStart, let startISO, let startDate = dateOnly(startISO, timeZone: timeZone), date <= startDate {
        date = addingDay(to: startDate, timeZone: timeZone) ?? date
      }
      return ["date": date]
    }
    guard let normalized = normalizeToISO8601(iso, timeZone: timeZone) else {
      throw CalendarAPIError.invalidDateFormat
    }
    return ["dateTime": normalized, "timeZone": timeZone]
  }

  /// Extracts the calendar date ("yyyy-MM-dd") of an instant, interpreted in `timeZone`.
  private func dateOnly(_ raw: String, timeZone: String) -> String? {
    let tz = TimeZone(identifier: timeZone) ?? .current
    guard let date = parseFlexibleDate(raw, timeZone: tz) else { return nil }
    let out = DateFormatter()
    out.locale = Locale(identifier: "en_US_POSIX")
    out.timeZone = tz
    out.dateFormat = "yyyy-MM-dd"
    return out.string(from: date)
  }

  private func addingDay(to dateString: String, timeZone: String) -> String? {
    let tz = TimeZone(identifier: timeZone) ?? .current
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = tz
    f.dateFormat = "yyyy-MM-dd"
    guard let date = f.date(from: dateString) else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    guard let next = cal.date(byAdding: .day, value: 1, to: date) else { return nil }
    return f.string(from: next)
  }

  private func parseFlexibleDate(_ raw: String, timeZone: TimeZone) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: trimmed) { return d }
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: trimmed) { return d }
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = timeZone
    for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                    "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
      parser.dateFormat = pattern
      if let d = parser.date(from: trimmed) { return d }
    }
    return nil
  }

  /// Normalizes model-supplied recurrence rules into the array of RFC-5545 strings the
  /// Calendar API expects. Each entry must carry an `RRULE:`/`RDATE:`/`EXDATE:`/`EXRULE:`
  /// prefix; a bare `FREQ=…` rule is prefixed with `RRULE:`. Returns nil only when the caller
  /// passed nil (field omitted → recurrence left unchanged). An explicitly empty array yields
  /// an empty array, which the Calendar API treats as "clear recurrence" on update.
  private func normalizedRecurrence(_ rules: [String]?) -> [String]? {
    guard let rules else { return nil }
    return rules.compactMap { raw in
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let upperPrefix = trimmed.uppercased()
      if upperPrefix.hasPrefix("RRULE:") || upperPrefix.hasPrefix("RDATE:")
        || upperPrefix.hasPrefix("EXDATE:") || upperPrefix.hasPrefix("EXRULE:") {
        return trimmed
      }
      return "RRULE:\(trimmed)"
    }
  }

  private func encodedPathComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  // MARK: - Errors

  enum CalendarAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case requestFailed(Int)
    case apiError(String)
    case invalidDateFormat
    case noFieldsToUpdate
    case notFound

    var errorDescription: String? {
      switch self {
      case .invalidURL: return "Invalid Calendar API URL."
      case .invalidResponse: return "Invalid response from Calendar API."
      case .requestFailed(let code): return "Calendar API request failed with status \(code)."
      case .apiError(let msg): return "Calendar API error: \(msg)"
      case .invalidDateFormat: return "Invalid date format. Use ISO 8601 (e.g. 2026-04-22T15:00:00+02:00)."
      case .noFieldsToUpdate: return "No fields to update. Provide at least one of: summary, start, end, location, description."
      case .notFound: return "Calendar event not found (it may have been deleted, or the event_id is wrong)."
      }
    }
  }
}

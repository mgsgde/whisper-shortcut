import Foundation

actor GoogleCalendarAPIClient {
  static let shared = GoogleCalendarAPIClient()

  private let baseURL = "https://www.googleapis.com/calendar/v3"
  private let maxResultsCap = 50

  // MARK: - List Events

  func listUpcomingEvents(maxResults: Int = 10, hoursAhead: Int = 168) async throws -> [[String: Any]] {
    DebugLogger.logNetwork("GOOGLE-CALENDAR: listUpcomingEvents maxResults=\(maxResults) hoursAhead=\(hoursAhead)")
    let cappedMax = min(max(maxResults, 1), maxResultsCap)
    let now = Date()
    let future = now.addingTimeInterval(TimeInterval(hoursAhead * 3600))

    let timeMin = ISO8601DateFormatter().string(from: now)
    let timeMax = ISO8601DateFormatter().string(from: future)

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
    DebugLogger.logNetwork("GOOGLE-CALENDAR: listUpcomingEvents returned \(mapped.count) events")
    return mapped
  }

  // MARK: - Create Event

  func createEvent(summary: String, startISO: String, endISO: String, timeZone: String,
                   location: String? = nil, description: String? = nil) async throws -> [String: Any] {
    DebugLogger.logNetwork("GOOGLE-CALENDAR: createEvent summary=\(summary) start=\(startISO) end=\(endISO)")
    guard isValidISO8601(startISO), isValidISO8601(endISO) else {
      throw CalendarAPIError.invalidDateFormat
    }

    guard let url = URL(string: "\(baseURL)/calendars/primary/events") else {
      throw CalendarAPIError.invalidResponse
    }

    var body: [String: Any] = [
      "summary": summary,
      "start": ["dateTime": startISO, "timeZone": timeZone],
      "end": ["dateTime": endISO, "timeZone": timeZone],
    ]
    if let location { body["location"] = location }
    if let description { body["description"] = description }

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
    DebugLogger.logSuccess("GOOGLE-CALENDAR: created event id=\(result["event_id"] ?? "?")")
    return result
  }

  // MARK: - Delete Event

  func deleteEvent(eventId: String) async throws -> [String: Any] {
    DebugLogger.logNetwork("GOOGLE-CALENDAR: deleteEvent id=\(eventId)")
    let encoded = encodedPathComponent(eventId)
    guard let url = URL(string: "\(baseURL)/calendars/primary/events/\(encoded)") else {
      throw CalendarAPIError.invalidResponse
    }
    _ = try await authorizedRequest(url: url, httpMethod: "DELETE")
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

    var errorDescription: String? {
      switch self {
      case .invalidURL: return "Invalid Calendar API URL."
      case .invalidResponse: return "Invalid response from Calendar API."
      case .requestFailed(let code): return "Calendar API request failed with status \(code)."
      case .apiError(let msg): return "Calendar API error: \(msg)"
      case .invalidDateFormat: return "Invalid date format. Use ISO 8601 (e.g. 2026-04-22T15:00:00+02:00)."
      }
    }
  }
}

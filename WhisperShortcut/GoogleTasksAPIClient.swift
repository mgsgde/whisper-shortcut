import Foundation

actor GoogleTasksAPIClient {
  static let shared = GoogleTasksAPIClient()

  private let baseURL = "https://www.googleapis.com/tasks/v1"
  private let maxResultsCap = 100
  /// Google Tasks pages with `nextPageToken`. Stop even if a token keeps arriving.
  private let maxListPages = 10

  // MARK: - List Task Lists

  func listTaskLists() async throws -> [[String: Any]] {
    let url = URL(string: "\(baseURL)/users/@me/lists")!
    let data = try await authorizedRequest(url: url, httpMethod: "GET")

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = json["items"] as? [[String: Any]]
    else {
      return []
    }

    return items.map { item in
      var list: [String: Any] = [:]
      if let id = item["id"] as? String { list["list_id"] = id }
      if let title = item["title"] as? String { list["title"] = title }
      return list
    }
  }

  // MARK: - List Tasks

  func listTasks(taskListId: String = "@default", maxResults: Int = 20, showCompleted: Bool = false) async throws -> [[String: Any]] {
    let cappedMax = min(max(maxResults, 1), maxResultsCap)
    let encodedList = taskListId.encodedPathSegment
    // Tasks completed in Google's own apps are hidden. showHidden must match showCompleted
    // or those tasks never come back.
    let show = String(showCompleted)

    var collected: [[String: Any]] = []
    var pageToken: String?
    for _ in 0..<maxListPages {
      if collected.count >= cappedMax { break }
      var components = URLComponents(string: "\(baseURL)/lists/\(encodedList)/tasks")!
      var query: [URLQueryItem] = [
        URLQueryItem(name: "maxResults", value: String(cappedMax - collected.count)),
        URLQueryItem(name: "showCompleted", value: show),
        URLQueryItem(name: "showHidden", value: show),
      ]
      if let pageToken {
        query.append(URLQueryItem(name: "pageToken", value: pageToken))
      }
      components.setQueryItemsStrictly(query)

      guard let url = components.url else {
        throw TasksAPIError.invalidURL
      }

      let data = try await authorizedRequest(url: url, httpMethod: "GET")
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        break
      }
      collected.append(contentsOf: json["items"] as? [[String: Any]] ?? [])
      guard let next = json["nextPageToken"] as? String, !next.isEmpty else { break }
      pageToken = next
    }

    return collected.prefix(cappedMax).map { item in
      var task: [String: Any] = [:]
      if let id = item["id"] as? String { task["task_id"] = id }
      if let title = item["title"] as? String { task["title"] = title }
      if let notes = item["notes"] as? String { task["notes"] = notes }
      if let due = item["due"] as? String { task["due"] = due }
      if let status = item["status"] as? String { task["status"] = status }
      if let updated = item["updated"] as? String { task["updated"] = updated }
      return task
    }
  }

  // MARK: - Create Task

  func createTask(title: String, notes: String? = nil, due: String? = nil, taskListId: String = "@default") async throws -> [String: Any] {
    let encodedList = taskListId.encodedPathSegment
    let url = URL(string: "\(baseURL)/lists/\(encodedList)/tasks")!

    var body: [String: Any] = ["title": title]
    if let notes { body["notes"] = notes }
    if let due, !due.isEmpty {
      // Google Tasks rejects a bare `yyyy-MM-dd` with 400 "invalid argument" even though it only
      // stores the date. Models (especially Grok) frequently emit exactly that, causing repeated
      // failed rounds — normalize to a full RFC 3339 timestamp before sending.
      guard let normalizedDue = Self.normalizedRFC3339Due(due) else {
        throw TasksAPIError.invalidDateFormat
      }
      body["due"] = normalizedDue
    }

    let bodyData = try JSONSerialization.data(withJSONObject: body)
    let data = try await authorizedRequest(url: url, httpMethod: "POST", body: bodyData)

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TasksAPIError.invalidResponse
    }

    var result: [String: Any] = ["ok": true]
    if let id = json["id"] as? String { result["task_id"] = id }
    if let title = json["title"] as? String { result["title"] = title }
    if let notes = json["notes"] as? String { result["notes"] = notes }
    if let due = json["due"] as? String { result["due"] = due }
    if let webViewLink = json["webViewLink"] as? String { result["web_view_link"] = webViewLink }
    return result
  }

  // MARK: - Complete Task

  func completeTask(taskId: String, taskListId: String = "@default") async throws -> [String: Any] {
    let encodedList = taskListId.encodedPathSegment
    let encodedTask = taskId.encodedPathSegment
    let url = URL(string: "\(baseURL)/lists/\(encodedList)/tasks/\(encodedTask)")!

    let body: [String: Any] = ["status": "completed"]
    let bodyData = try JSONSerialization.data(withJSONObject: body)
    let data = try await authorizedRequest(url: url, httpMethod: "PATCH", body: bodyData)

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TasksAPIError.invalidResponse
    }

    return ["ok": true, "task_id": taskId, "status": json["status"] as? String ?? "completed"]
  }

  // MARK: - Update Task

  /// PATCHes an existing task in place. Without this, "move these tasks to today" forces the model
  /// into a create+delete pair per task — two tool rounds each, which exhausts the chat tool loop on
  /// a handful of tasks and loses the task IDs, ordering, and completion history along the way.
  ///
  /// Only the fields the caller passes are sent, so a title-only edit never clobbers notes. Passing
  /// an empty `due` clears the due date (Google Tasks needs an explicit JSON null for that, which is
  /// unreachable through a plain optional).
  func updateTask(
    taskId: String,
    taskListId: String = "@default",
    title: String? = nil,
    notes: String? = nil,
    due: String? = nil,
    status: String? = nil
  ) async throws -> [String: Any] {
    let encodedList = taskListId.encodedPathSegment
    let encodedTask = taskId.encodedPathSegment
    let url = URL(string: "\(baseURL)/lists/\(encodedList)/tasks/\(encodedTask)")!

    var body: [String: Any] = [:]
    if let title, !title.isEmpty { body["title"] = title }
    if let notes { body["notes"] = notes }
    if let due {
      if due.isEmpty {
        body["due"] = NSNull()
      } else {
        // Same `yyyy-MM-dd` normalization as createTask — models emit bare dates constantly.
        guard let normalizedDue = Self.normalizedRFC3339Due(due) else {
          throw TasksAPIError.invalidDateFormat
        }
        body["due"] = normalizedDue
      }
    }
    if let status, !status.isEmpty {
      guard status == "needsAction" || status == "completed" else {
        throw TasksAPIError.apiError("status must be 'needsAction' or 'completed'")
      }
      body["status"] = status
      // Google keeps a stale `completed` timestamp when a task is re-opened unless it is
      // explicitly cleared, and then rejects the mismatch with a 400.
      if status == "needsAction" { body["completed"] = NSNull() }
    }
    guard !body.isEmpty else {
      throw TasksAPIError.apiError("Nothing to update — pass at least one of title, notes, due, status")
    }

    let bodyData = try JSONSerialization.data(withJSONObject: body)
    let data = try await authorizedRequest(url: url, httpMethod: "PATCH", body: bodyData)

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TasksAPIError.invalidResponse
    }

    var result: [String: Any] = ["ok": true, "task_id": taskId]
    if let title = json["title"] as? String { result["title"] = title }
    if let notes = json["notes"] as? String { result["notes"] = notes }
    if let due = json["due"] as? String { result["due"] = due }
    if let status = json["status"] as? String { result["status"] = status }
    if let webViewLink = json["webViewLink"] as? String { result["web_view_link"] = webViewLink }
    return result
  }

  // MARK: - Delete Task

  func deleteTask(taskId: String, taskListId: String = "@default") async throws -> [String: Any] {
    let encodedList = taskListId.encodedPathSegment
    let encodedTask = taskId.encodedPathSegment
    let url = URL(string: "\(baseURL)/lists/\(encodedList)/tasks/\(encodedTask)")!
    _ = try await authorizedRequest(url: url, httpMethod: "DELETE")
    return ["ok": true, "task_id": taskId, "deleted": true]
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

    let (data, response) = try await LLMHTTPSession.integrations.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TasksAPIError.invalidResponse
    }

    if httpResponse.statusCode == 401 {
      DebugLogger.logNetwork("GOOGLE-TASKS: 401, refreshing token and retrying")
      let newToken = try await GoogleAccountOAuthService.shared.refreshAccessToken()

      var retryRequest = request
      retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
      let (retryData, retryResponse) = try await LLMHTTPSession.integrations.data(for: retryRequest)

      guard let retryHTTP = retryResponse as? HTTPURLResponse else {
        throw TasksAPIError.invalidResponse
      }
      guard (200..<300).contains(retryHTTP.statusCode) else {
        throw TasksAPIError.requestFailed(retryHTTP.statusCode)
      }
      return retryData
    }

    if !(200..<300).contains(httpResponse.statusCode) {
      // Keys only — the body holds the task title and notes. The key list is enough
      // to attribute an "invalid argument" 400 to a field (see tasks_create failures).
      let bodyKeys = Self.loggedBodyKeys(body)
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let error = json["error"] as? [String: Any],
         let message = error["message"] as? String {
        DebugLogger.logError("GOOGLE-TASKS: API error \(httpResponse.statusCode): \(message) | \(httpMethod) body keys=[\(bodyKeys)]")
        throw TasksAPIError.apiError(message)
      }
      DebugLogger.logError("GOOGLE-TASKS: API error \(httpResponse.statusCode) | \(httpMethod) body keys=[\(bodyKeys)]")
      throw TasksAPIError.requestFailed(httpResponse.statusCode)
    }

    return data
  }

  /// Sorted JSON keys of a request body, for error logs. Never the title or notes.
  static func loggedBodyKeys(_ body: Data?) -> String {
    body.flatMap { data -> String? in
      (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
        .keys.sorted().joined(separator: ",")
    } ?? "none"
  }

  // MARK: - Validation

  /// Normalizes the `due` value the model emits into the RFC 3339 date-time Google Tasks requires.
  ///
  /// A full internet date-time passes through. A bare `yyyy-MM-dd` becomes midnight UTC. A string
  /// that starts with a date and then a time but is not a valid internet date-time (no offset, or
  /// a space instead of `T`) keeps only the date: Tasks stores a date, and `.withFullDate` would
  /// otherwise accept the time and produce `2026-11-10T09:00:00T00:00:00.000Z`. Anything else is
  /// nil so the caller can reject it up front.
  static func normalizedRFC3339Due(_ string: String) -> String? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
      return trimmed + "T00:00:00.000Z"
    }
    if isInternetDateTime(trimmed) { return trimmed }
    if let datePart = datePartBeforeTime(trimmed) {
      return datePart + "T00:00:00.000Z"
    }
    return nil
  }

  private static func isInternetDateTime(_ string: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: string) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string) != nil
  }

  /// The `yyyy-MM-dd` prefix when the next character is `T` or a space. Nil otherwise.
  private static func datePartBeforeTime(_ string: String) -> String? {
    guard let range = string.range(of: #"^\d{4}-\d{2}-\d{2}[T ]"#, options: .regularExpression) else {
      return nil
    }
    return String(string[range].dropLast())
  }

  // MARK: - Errors

  enum TasksAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case requestFailed(Int)
    case apiError(String)
    case invalidDateFormat

    var errorDescription: String? {
      switch self {
      case .invalidURL: return "Invalid Tasks API URL."
      case .invalidResponse: return "Invalid response from Tasks API."
      case .requestFailed(let code): return "Tasks API request failed with status \(code)."
      case .apiError(let msg): return "Tasks API error: \(msg)"
      case .invalidDateFormat: return "Invalid date format. Use ISO 8601 (e.g. 2026-04-22T00:00:00Z)."
      }
    }
  }
}

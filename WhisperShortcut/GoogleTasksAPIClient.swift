import Foundation

actor GoogleTasksAPIClient {
  static let shared = GoogleTasksAPIClient()

  private let baseURL = "https://www.googleapis.com/tasks/v1"
  private let maxResultsCap = 100

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

    var components = URLComponents(string: "\(baseURL)/lists/\(taskListId)/tasks")!
    components.queryItems = [
      URLQueryItem(name: "maxResults", value: String(cappedMax)),
      URLQueryItem(name: "showCompleted", value: String(showCompleted)),
      URLQueryItem(name: "showHidden", value: "false"),
    ]

    guard let url = components.url else {
      throw TasksAPIError.invalidURL
    }

    let data = try await authorizedRequest(url: url, httpMethod: "GET")

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = json["items"] as? [[String: Any]]
    else {
      return []
    }

    return items.map { item in
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
    let url = URL(string: "\(baseURL)/lists/\(taskListId)/tasks")!

    var body: [String: Any] = ["title": title]
    if let notes { body["notes"] = notes }
    if let due {
      guard isValidISO8601Date(due) else {
        throw TasksAPIError.invalidDateFormat
      }
      body["due"] = due
    }

    let bodyData = try JSONSerialization.data(withJSONObject: body)
    let data = try await authorizedRequest(url: url, httpMethod: "POST", body: bodyData)

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TasksAPIError.invalidResponse
    }

    var result: [String: Any] = ["ok": true]
    if let id = json["id"] as? String { result["task_id"] = id }
    if let title = json["title"] as? String { result["title"] = title }
    return result
  }

  // MARK: - Complete Task

  func completeTask(taskId: String, taskListId: String = "@default") async throws -> [String: Any] {
    let url = URL(string: "\(baseURL)/lists/\(taskListId)/tasks/\(taskId)")!

    let body: [String: Any] = ["status": "completed"]
    let bodyData = try JSONSerialization.data(withJSONObject: body)
    let data = try await authorizedRequest(url: url, httpMethod: "PATCH", body: bodyData)

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TasksAPIError.invalidResponse
    }

    return ["ok": true, "task_id": taskId, "status": json["status"] as? String ?? "completed"]
  }

  // MARK: - Delete Task

  func deleteTask(taskId: String, taskListId: String = "@default") async throws -> [String: Any] {
    let url = URL(string: "\(baseURL)/lists/\(taskListId)/tasks/\(taskId)")!
    _ = try await authorizedRequest(url: url, httpMethod: "DELETE")
    return ["ok": true, "task_id": taskId, "deleted": true]
  }

  // MARK: - Authorized Request

  private func authorizedRequest(url: URL, httpMethod: String, body: Data? = nil) async throws -> Data {
    let token = try await GoogleCalendarOAuthService.shared.getValidAccessToken()

    var request = URLRequest(url: url)
    request.httpMethod = httpMethod
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TasksAPIError.invalidResponse
    }

    if httpResponse.statusCode == 401 {
      DebugLogger.logNetwork("GOOGLE-TASKS: 401, refreshing token and retrying")
      let newToken = try await GoogleCalendarOAuthService.shared.refreshAccessToken()

      var retryRequest = request
      retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
      let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)

      guard let retryHTTP = retryResponse as? HTTPURLResponse, (200..<300).contains(retryHTTP.statusCode) else {
        throw TasksAPIError.requestFailed(httpResponse.statusCode)
      }
      return retryData
    }

    if !(200..<300).contains(httpResponse.statusCode) {
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let error = json["error"] as? [String: Any],
         let message = error["message"] as? String {
        DebugLogger.logError("GOOGLE-TASKS: API error \(httpResponse.statusCode): \(message)")
        throw TasksAPIError.apiError(message)
      }
      throw TasksAPIError.requestFailed(httpResponse.statusCode)
    }

    return data
  }

  // MARK: - Validation

  private func isValidISO8601Date(_ string: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: string) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime]
    if formatter.date(from: string) != nil { return true }
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string) != nil
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

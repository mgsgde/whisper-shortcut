import Foundation

actor GmailAPIClient {
  static let shared = GmailAPIClient()

  private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"

  // MARK: - Search / List Messages

  func searchMessages(query: String = "", maxResults: Int = 10) async throws -> [[String: Any]] {
    let cappedMax = min(max(maxResults, 1), 50)

    var components = URLComponents(string: "\(baseURL)/messages")!
    var queryItems = [URLQueryItem(name: "maxResults", value: String(cappedMax))]
    if !query.isEmpty {
      queryItems.append(URLQueryItem(name: "q", value: query))
    }
    components.queryItems = queryItems

    guard let url = components.url else {
      throw GmailAPIError.invalidURL
    }

    let data = try await authorizedRequest(url: url, httpMethod: "GET")
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let messages = json["messages"] as? [[String: Any]]
    else {
      return []
    }

    var results: [[String: Any]] = []
    let candidates = Array(messages.prefix(cappedMax))
    for msg in candidates {
      guard let id = msg["id"] as? String else { continue }
      if let detail = try? await getMessageSummary(messageId: id) {
        results.append(detail)
      }
    }
    let skipped = candidates.count - results.count
    if skipped > 0 {
      DebugLogger.logWarning("GMAIL: \(skipped) message(s) failed to fetch")
    }
    return results
  }

  // MARK: - Read Message

  func readMessage(messageId: String) async throws -> [String: Any] {
    let url = URL(string: "\(baseURL)/messages/\(messageId)?format=full")!
    let data = try await authorizedRequest(url: url, httpMethod: "GET")

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw GmailAPIError.invalidResponse
    }

    return parseMessage(json, includeBody: true)
  }

  // MARK: - Private Helpers

  private func getMessageSummary(messageId: String) async throws -> [String: Any] {
    let url = URL(string: "\(baseURL)/messages/\(messageId)?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Date")!
    let data = try await authorizedRequest(url: url, httpMethod: "GET")

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw GmailAPIError.invalidResponse
    }

    return parseMessage(json, includeBody: false)
  }

  private func parseMessage(_ json: [String: Any], includeBody: Bool) -> [String: Any] {
    var result: [String: Any] = [:]

    if let id = json["id"] as? String { result["message_id"] = id }
    if let threadId = json["threadId"] as? String { result["thread_id"] = threadId }
    if let snippet = json["snippet"] as? String { result["snippet"] = snippet }
    if let labels = json["labelIds"] as? [String] { result["labels"] = labels }

    if let payload = json["payload"] as? [String: Any],
       let headers = payload["headers"] as? [[String: Any]] {
      for header in headers {
        guard let name = header["name"] as? String,
              let value = header["value"] as? String else { continue }
        switch name.lowercased() {
        case "from": result["from"] = value
        case "to": result["to"] = value
        case "subject": result["subject"] = value
        case "date": result["date"] = value
        case "message-id": result["rfc_message_id"] = value
        default: break
        }
      }

      if includeBody {
        result["body"] = extractBody(from: payload)
      }
    }

    return result
  }

  private func extractBody(from payload: [String: Any]) -> String {
    if let body = payload["body"] as? [String: Any],
       let data = body["data"] as? String,
       let decoded = decodeBase64URL(data) {
      return decoded
    }

    if let parts = payload["parts"] as? [[String: Any]] {
      for part in parts {
        let mimeType = part["mimeType"] as? String ?? ""
        if mimeType == "text/plain",
           let body = part["body"] as? [String: Any],
           let data = body["data"] as? String,
           let decoded = decodeBase64URL(data) {
          return decoded
        }
      }
      for part in parts {
        let mimeType = part["mimeType"] as? String ?? ""
        if mimeType == "text/html",
           let body = part["body"] as? [String: Any],
           let data = body["data"] as? String,
           let decoded = decodeBase64URL(data) {
          return decoded
        }
      }
      for part in parts {
        if let nested = part["parts"] as? [[String: Any]] {
          let nestedPayload: [String: Any] = ["parts": nested]
          let result = extractBody(from: nestedPayload)
          if !result.isEmpty { return result }
        }
      }
    }

    return ""
  }

  private func decodeBase64URL(_ string: String) -> String? {
    var base64 = string
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 {
      base64 += "="
    }
    guard let data = Data(base64Encoded: base64) else { return nil }
    return String(data: data, encoding: .utf8)
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
      throw GmailAPIError.invalidResponse
    }

    if httpResponse.statusCode == 401 {
      DebugLogger.logNetwork("GMAIL: 401, refreshing token and retrying")
      let newToken = try await GoogleAccountOAuthService.shared.refreshAccessToken()

      var retryRequest = request
      retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
      let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)

      guard let retryHTTP = retryResponse as? HTTPURLResponse else {
        throw GmailAPIError.invalidResponse
      }
      guard (200..<300).contains(retryHTTP.statusCode) else {
        throw GmailAPIError.requestFailed(retryHTTP.statusCode)
      }
      return retryData
    }

    if !(200..<300).contains(httpResponse.statusCode) {
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let error = json["error"] as? [String: Any],
         let message = error["message"] as? String {
        DebugLogger.logError("GMAIL: API error \(httpResponse.statusCode): \(message)")
        throw GmailAPIError.apiError(message)
      }
      throw GmailAPIError.requestFailed(httpResponse.statusCode)
    }

    return data
  }

  // MARK: - Errors

  enum GmailAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case requestFailed(Int)
    case apiError(String)

    var errorDescription: String? {
      switch self {
      case .invalidURL: return "Invalid Gmail API URL."
      case .invalidResponse: return "Invalid response from Gmail API."
      case .requestFailed(let code): return "Gmail API request failed with status \(code)."
      case .apiError(let msg): return "Gmail API error: \(msg)"
      }
    }
  }
}

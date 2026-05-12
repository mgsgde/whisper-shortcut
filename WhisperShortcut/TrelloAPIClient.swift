import Foundation

/// Thin Trello REST client. Auth is done by appending `key=<apiKey>&token=<userToken>`
/// to every request as query parameters — Trello does *not* use a Bearer header.
///
/// API reference: https://developer.atlassian.com/cloud/trello/rest/
actor TrelloAPIClient {
  static let shared = TrelloAPIClient()

  private let baseURL = "https://api.trello.com/1"

  // MARK: - List Boards

  /// Boards the user is a member of (active, not closed).
  func listBoards() async throws -> [[String: Any]] {
    DebugLogger.logNetwork("TRELLO: listBoards")
    var components = URLComponents(string: "\(baseURL)/members/me/boards")!
    components.queryItems = [
      URLQueryItem(name: "filter", value: "open"),
      URLQueryItem(name: "fields", value: "name,url,desc,closed"),
    ]
    let data = try await authorizedRequest(components: components, httpMethod: "GET")
    guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    let mapped = items.compactMap { item -> [String: Any]? in
      guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
      var board: [String: Any] = ["board_id": id, "name": name]
      if let url = item["url"] as? String { board["url"] = url }
      if let desc = item["desc"] as? String, !desc.isEmpty { board["description"] = desc }
      return board
    }
    DebugLogger.logNetwork("TRELLO: listBoards returned \(mapped.count) boards")
    return mapped
  }

  // MARK: - List Lists on a Board

  func listLists(boardId: String) async throws -> [[String: Any]] {
    DebugLogger.logNetwork("TRELLO: listLists boardId=\(boardId)")
    let path = "\(baseURL)/boards/\(encodedPathComponent(boardId))/lists"
    var components = URLComponents(string: path)!
    components.queryItems = [
      URLQueryItem(name: "filter", value: "open"),
      URLQueryItem(name: "fields", value: "name,pos,closed"),
    ]
    let data = try await authorizedRequest(components: components, httpMethod: "GET")
    guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    let mapped = items.compactMap { item -> [String: Any]? in
      guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
      var list: [String: Any] = ["list_id": id, "name": name]
      if let pos = item["pos"] as? Double { list["position"] = pos }
      return list
    }
    DebugLogger.logNetwork("TRELLO: listLists returned \(mapped.count) lists")
    return mapped
  }

  // MARK: - List Cards

  /// Cards belonging to a list. If `listId` is nil, falls back to cards on the
  /// given `boardId`.
  func listCards(listId: String? = nil, boardId: String? = nil, maxResults: Int = 50) async throws -> [[String: Any]] {
    DebugLogger.logNetwork("TRELLO: listCards listId=\(listId ?? "-") boardId=\(boardId ?? "-")")
    let path: String
    if let listId {
      path = "\(baseURL)/lists/\(encodedPathComponent(listId))/cards"
    } else if let boardId {
      path = "\(baseURL)/boards/\(encodedPathComponent(boardId))/cards"
    } else {
      throw TrelloAPIError.invalidRequest("Either list_id or board_id is required")
    }

    var components = URLComponents(string: path)!
    components.queryItems = [
      URLQueryItem(name: "fields", value: "name,desc,due,dueComplete,closed,idList,idBoard,url,shortUrl"),
      URLQueryItem(name: "limit", value: String(min(max(maxResults, 1), 100))),
    ]
    let data = try await authorizedRequest(components: components, httpMethod: "GET")
    guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    let mapped = items.compactMap { item -> [String: Any]? in
      guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
      var card: [String: Any] = ["card_id": id, "name": name]
      if let desc = item["desc"] as? String, !desc.isEmpty { card["description"] = desc }
      if let due = item["due"] as? String { card["due"] = due }
      if let dueComplete = item["dueComplete"] as? Bool { card["due_complete"] = dueComplete }
      if let listId = item["idList"] as? String { card["list_id"] = listId }
      if let boardId = item["idBoard"] as? String { card["board_id"] = boardId }
      if let url = item["shortUrl"] as? String ?? item["url"] as? String { card["url"] = url }
      return card
    }
    DebugLogger.logNetwork("TRELLO: listCards returned \(mapped.count) cards")
    return mapped
  }

  // MARK: - Create Card

  func createCard(listId: String, name: String, description: String? = nil, due: String? = nil) async throws -> [String: Any] {
    DebugLogger.logNetwork("TRELLO: createCard listId=\(listId) name=\(name)")
    var components = URLComponents(string: "\(baseURL)/cards")!
    var items: [URLQueryItem] = [
      URLQueryItem(name: "idList", value: listId),
      URLQueryItem(name: "name", value: name),
    ]
    if let description, !description.isEmpty {
      items.append(URLQueryItem(name: "desc", value: description))
    }
    if let due, !due.isEmpty {
      items.append(URLQueryItem(name: "due", value: due))
    }
    components.queryItems = items
    let data = try await authorizedRequest(components: components, httpMethod: "POST")
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

    var result: [String: Any] = ["ok": true]
    if let id = json["id"] as? String { result["card_id"] = id }
    if let n = json["name"] as? String { result["name"] = n }
    if let url = json["shortUrl"] as? String ?? json["url"] as? String { result["url"] = url }
    if let due = json["due"] as? String { result["due"] = due }
    DebugLogger.logSuccess("TRELLO: createCard ok id=\(result["card_id"] ?? "?")")
    return result
  }

  // MARK: - Move Card (change list)

  func moveCard(cardId: String, listId: String) async throws -> [String: Any] {
    DebugLogger.logNetwork("TRELLO: moveCard id=\(cardId) listId=\(listId)")
    var components = URLComponents(string: "\(baseURL)/cards/\(encodedPathComponent(cardId))")!
    components.queryItems = [URLQueryItem(name: "idList", value: listId)]
    let data = try await authorizedRequest(components: components, httpMethod: "PUT")
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    var result: [String: Any] = ["ok": true, "card_id": cardId]
    if let listId = json["idList"] as? String { result["list_id"] = listId }
    if let url = json["shortUrl"] as? String ?? json["url"] as? String { result["url"] = url }
    return result
  }

  // MARK: - Update Card (name / description / due)

  func updateCard(cardId: String, name: String? = nil, description: String? = nil, due: String? = nil) async throws -> [String: Any] {
    DebugLogger.logNetwork("TRELLO: updateCard id=\(cardId)")
    var components = URLComponents(string: "\(baseURL)/cards/\(encodedPathComponent(cardId))")!
    var items: [URLQueryItem] = []
    if let name { items.append(URLQueryItem(name: "name", value: name)) }
    if let description { items.append(URLQueryItem(name: "desc", value: description)) }
    if let due {
      // Trello accepts empty string to clear the due date.
      items.append(URLQueryItem(name: "due", value: due))
    }
    guard !items.isEmpty else {
      throw TrelloAPIError.invalidRequest("At least one of name, description, or due is required")
    }
    components.queryItems = items
    let data = try await authorizedRequest(components: components, httpMethod: "PUT")
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    var result: [String: Any] = ["ok": true, "card_id": cardId]
    if let n = json["name"] as? String { result["name"] = n }
    if let due = json["due"] as? String { result["due"] = due }
    if let url = json["shortUrl"] as? String ?? json["url"] as? String { result["url"] = url }
    return result
  }

  // MARK: - Archive Card (the Trello equivalent of "complete")

  /// Trello has no native "completed" state for cards. Archiving (`closed=true`)
  /// is the standard "done with this card" action and is reversible.
  func archiveCard(cardId: String) async throws -> [String: Any] {
    DebugLogger.logNetwork("TRELLO: archiveCard id=\(cardId)")
    var components = URLComponents(string: "\(baseURL)/cards/\(encodedPathComponent(cardId))")!
    components.queryItems = [URLQueryItem(name: "closed", value: "true")]
    _ = try await authorizedRequest(components: components, httpMethod: "PUT")
    DebugLogger.logSuccess("TRELLO: archiveCard ok id=\(cardId)")
    return ["ok": true, "card_id": cardId, "archived": true]
  }

  // MARK: - Authorized Request

  /// Builds the final URL by appending `key=...&token=...` to `components`,
  /// then issues the request. Trello returns 401 when the token is invalid
  /// (e.g. revoked) — we surface that directly; there is no refresh path.
  private func authorizedRequest(components: URLComponents, httpMethod: String) async throws -> Data {
    let apiKey = TrelloOAuthConfig.apiKey
    guard !apiKey.isEmpty else {
      throw TrelloAPIError.missingAPIKey
    }
    let token = try await MainActor.run { try TrelloOAuthService.shared.getToken() }

    var components = components
    var items = components.queryItems ?? []
    items.append(URLQueryItem(name: "key", value: apiKey))
    items.append(URLQueryItem(name: "token", value: token))
    components.queryItems = items

    guard let url = components.url else {
      throw TrelloAPIError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = httpMethod
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TrelloAPIError.invalidResponse
    }

    if http.statusCode == 401 {
      DebugLogger.logError("TRELLO: 401 — token may have been revoked")
      throw TrelloAPIError.unauthorized
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      DebugLogger.logError("TRELLO: HTTP \(http.statusCode) body=\(body.prefix(300))")
      throw TrelloAPIError.requestFailed(http.statusCode, body)
    }
    return data
  }

  // MARK: - Helpers

  private func encodedPathComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  // MARK: - Errors

  enum TrelloAPIError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case invalidResponse
    case invalidRequest(String)
    case unauthorized
    case requestFailed(Int, String)

    var errorDescription: String? {
      switch self {
      case .missingAPIKey:
        return "Trello API key is not configured."
      case .invalidURL:
        return "Invalid Trello API URL."
      case .invalidResponse:
        return "Invalid response from Trello API."
      case .invalidRequest(let msg):
        return msg
      case .unauthorized:
        return "Trello token is invalid or revoked. Reconnect via /connect-trello or Settings."
      case .requestFailed(let code, let body):
        return "Trello API request failed (HTTP \(code))\(body.isEmpty ? "" : ": \(body)")"
      }
    }
  }
}

import Foundation

/// The models the signed-in ChatGPT account can pick from: `GET https://api.openai.com/v1/models`
/// with the plan's access token, keeping `visibility == "list"` in server order.
///
/// A listed model is a catalog entry, not an entitlement — only a completed request proves access.
/// The last result is cached in UserDefaults so pickers have something to show before (and without)
/// a network round trip. Refresh with `refresh()` after sign-in, when the picker opens, and when the
/// account changes; `sign out` clears the cache.
enum ChatGPTPlanModelCatalog {

  struct Entry: Codable, Equatable {
    let slug: String
    let displayName: String
  }

  /// Parses `{"models":[{"slug","display_name","visibility"}, …]}`; order is preserved and only
  /// `visibility == "list"` entries survive. A missing `display_name` falls back to the slug.
  static func parse(_ data: Data) -> [Entry] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let models = root["models"] as? [[String: Any]]
    else { return [] }
    return models.compactMap { model in
      guard (model["visibility"] as? String) == "list",
        let slug = model["slug"] as? String, !slug.isEmpty
      else { return nil }
      let name = (model["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      return Entry(slug: slug, displayName: name ?? slug)
    }
  }

  // MARK: Cache

  nonisolated static func cachedModels(defaults: UserDefaults = .standard) -> [Entry] {
    guard let data = defaults.data(forKey: UserDefaultsKeys.chatGPTPlanModelCatalog) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }

  nonisolated static func store(_ entries: [Entry], defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(entries) {
      defaults.set(data, forKey: UserDefaultsKeys.chatGPTPlanModelCatalog)
    }
  }

  nonisolated static func clearCache(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: UserDefaultsKeys.chatGPTPlanModelCatalog)
  }

  /// A saved slug the account's catalog does not list (other account, retired model) would fail on
  /// every request: replace it with the first listed model. No saved slug stays untouched.
  nonisolated static func reconcileSavedModel(with entries: [Entry], defaults: UserDefaults = .standard) {
    guard let first = entries.first else { return }
    let saved = (defaults.string(forKey: UserDefaultsKeys.chatGPTPlanModelID) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !saved.isEmpty, !entries.contains(where: { $0.slug == saved }) else { return }
    defaults.set(first.slug, forKey: UserDefaultsKeys.chatGPTPlanModelID)
  }

  // MARK: Fetch

  /// Fetches the account's models with a valid (refreshed if needed) access token and caches them.
  /// An empty list is not cached over a good one.
  @MainActor
  @discardableResult
  static func refresh(
    accessToken: String? = nil,
    transport: ChatGPTPlanTransport = ChatGPTPlanOAuthService.liveTransport,
    defaults: UserDefaults = .standard
  ) async throws -> [Entry] {
    if let accessToken {
      return try await load(token: accessToken, transport: transport, defaults: defaults)
    }
    // Same 401 rule as chat: an expired access token refreshes once instead of failing the list.
    return try await ChatGPTPlanOAuthService.shared.withAuthorizedRetry { token in
      try await load(token: token, transport: transport, defaults: defaults)
    }
  }

  private static func load(
    token: String, transport: ChatGPTPlanTransport, defaults: UserDefaults
  ) async throws -> [Entry] {
    var request = URLRequest(url: ChatGPTPlanOAuthConfig.modelsEndpoint)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, http) = try await transport(request)
    guard (200..<300).contains(http.statusCode) else {
      throw ChatGPTPlanError.fromHTTP(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
    }
    let entries = parse(data)
    if !entries.isEmpty {
      store(entries, defaults: defaults)
      reconcileSavedModel(with: entries, defaults: defaults)
    }
    DebugLogger.log("CHATGPT-PLAN: Model catalog refreshed (\(entries.count) listed)")
    return entries
  }
}

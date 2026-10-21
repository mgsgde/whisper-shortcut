import Foundation

/// The one Keychain record behind "Use your ChatGPT plan": the validated account identity, the
/// issued client registration, the OAuth tokens and their scopes.
///
/// Stored as JSON under `KeychainCredential.chatGPTPlan`. It is **not** an API key and has no
/// environment-variable fallback. Never log it, put it in session JSON, the usage log or telemetry.
///
/// Signing out or a terminal refresh error clears only the tokens (`clearingTokens()`): the issued
/// `client_id`, host id and account identity stay so the next sign-in reuses the registration
/// instead of creating a new client.
struct ChatGPTPlanCredentials: Codable, Equatable {
  var email: String
  var issuer: String
  /// Validated ID-token `sub`; the account identity (email is not unique across registrations).
  var subject: String
  /// The issued `oaiapp_…` id, never `dynamic_agent_client`.
  var clientID: String
  var extAgentHostID: String
  /// Retained for `id_token_hint` on the next sign-in; empty after an explicit sign-out.
  var idToken: String
  var accessToken: String?
  var refreshToken: String?
  var expiresAt: Date?
  var scopes: [String]
  var savedAt: Date

  enum CodingKeys: String, CodingKey {
    case email, issuer, subject
    case clientID = "client_id"
    case extAgentHostID = "ext_agent_host_id"
    case idToken = "id_token"
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresAt = "expires_at"
    case scopes
    case savedAt = "saved_at"
  }

  // MARK: Derived state

  /// True when the user granted `chatgpt.tokens.use.direct`. A valid ID token alone does not
  /// authorize plan usage: without the scope the sign-in is kept but the plan is disabled.
  var planEnabled: Bool { scopes.contains(ChatGPTPlanOAuthConfig.planScope) }

  /// True while there is a renewable or usable session (tokens present).
  var hasTokens: Bool {
    !(refreshToken ?? "").isEmpty || !(accessToken ?? "").isEmpty
  }

  /// True when the access token is missing or expires within `margin`.
  func needsRefresh(now: Date = Date(), margin: TimeInterval = ChatGPTPlanOAuthConfig.refreshMargin) -> Bool {
    guard let token = accessToken, !token.isEmpty, let expiresAt else { return true }
    return expiresAt.timeIntervalSince(now) <= margin
  }

  /// Drops the tokens, keeps registration and identity. `forgetIDToken` also drops the retained
  /// ID token (explicit sign-out: "omit `id_token_hint` after signing out").
  func clearingTokens(forgetIDToken: Bool = false) -> ChatGPTPlanCredentials {
    var copy = self
    copy.accessToken = nil
    copy.refreshToken = nil
    copy.expiresAt = nil
    if forgetIDToken { copy.idToken = "" }
    return copy
  }

  // MARK: Coding

  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  // MARK: Keychain

  /// Reads the record, or nil when absent or unreadable.
  static func load(
    from keychain: KeychainManaging = KeychainManager.shared, uncached: Bool = false
  ) -> ChatGPTPlanCredentials? {
    let stored = uncached ? keychain.getUncached(.chatGPTPlan) : keychain.get(.chatGPTPlan)
    guard let json = stored, let data = json.data(using: .utf8) else { return nil }
    return try? makeDecoder().decode(ChatGPTPlanCredentials.self, from: data)
  }

  @discardableResult
  func save(to keychain: KeychainManaging = KeychainManager.shared) -> Bool {
    guard let data = try? Self.makeEncoder().encode(self),
      let json = String(data: data, encoding: .utf8)
    else { return false }
    return keychain.save(json, for: .chatGPTPlan)
  }

  /// Removes the whole record, registration included ("use a different account").
  @discardableResult
  static func delete(from keychain: KeychainManaging = KeychainManager.shared) -> Bool {
    keychain.delete(.chatGPTPlan)
  }

  // MARK: Host id

  /// The stable `ext_agent_host_id`: `urn:uuid:<lowercased UUIDv4>`, generated once and kept in
  /// UserDefaults (opaque, not user-identifying). Reused for every sign-in on this Mac.
  static func hostID(defaults: UserDefaults = .standard) -> String {
    if let existing = defaults.string(forKey: UserDefaultsKeys.chatGPTPlanHostID), !existing.isEmpty {
      return existing
    }
    let created = "urn:uuid:" + UUID().uuidString.lowercased()
    defaults.set(created, forKey: UserDefaultsKeys.chatGPTPlanHostID)
    return created
  }
}

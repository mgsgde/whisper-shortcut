import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

// MARK: - Seams (injectable for tests)

/// Where the credential record lives. Production: the login Keychain.
protocol ChatGPTPlanCredentialStoring {
  func load() -> ChatGPTPlanCredentials?
  /// Reads the record bypassing any in-memory cache (another process may have rotated the tokens).
  func loadUncached() -> ChatGPTPlanCredentials?
  @discardableResult func save(_ credentials: ChatGPTPlanCredentials) -> Bool
  func delete()
}

extension ChatGPTPlanCredentialStoring {
  func loadUncached() -> ChatGPTPlanCredentials? { load() }
}

struct KeychainChatGPTPlanStore: ChatGPTPlanCredentialStoring {
  func load() -> ChatGPTPlanCredentials? { ChatGPTPlanCredentials.load() }
  func loadUncached() -> ChatGPTPlanCredentials? { ChatGPTPlanCredentials.load(uncached: true) }
  func save(_ credentials: ChatGPTPlanCredentials) -> Bool { credentials.save() }
  func delete() { ChatGPTPlanCredentials.delete() }
}

/// One HTTP round trip. Production: `LLMHTTPSession.integrations` (honours Offline Mode).
typealias ChatGPTPlanTransport = (URLRequest) async throws -> (Data, HTTPURLResponse)

// MARK: - Errors

/// Failures of the sign-in flow itself (not of inference; see `ChatGPTPlanError` for that).
enum ChatGPTPlanSignInError: LocalizedError, Equatable {
  case invalidURL
  case authorizationInProgress
  case authorizationStartFailed
  case noCallbackURL
  case stateMismatch
  case noAuthorizationCode
  /// A new registration came back without an issued `client_id`.
  case registrationIncomplete
  /// A reauthorization callback named a different client than the saved registration.
  case clientIDMismatch
  case oauthError(String)
  case tokenExchangeFailed(String)
  case invalidResponse
  case missingIDToken
  case keychainWriteFailed

  var errorDescription: String? {
    switch self {
    case .invalidURL: return "Failed to build the ChatGPT sign-in URL."
    case .authorizationInProgress: return "A ChatGPT sign-in is already in progress."
    case .authorizationStartFailed: return "Failed to open the ChatGPT sign-in window."
    case .noCallbackURL: return "ChatGPT did not return a callback."
    case .stateMismatch:
      return "ChatGPT sign-in was refused because the callback did not match this attempt. Try again."
    case .noAuthorizationCode: return "No authorization code in ChatGPT's callback."
    case .registrationIncomplete:
      return "ChatGPT did not finish registering WhisperShortcut. Try signing in again."
    case .clientIDMismatch:
      return "ChatGPT answered for a different registration than the saved one. Sign-in was refused."
    case .oauthError(let message): return "ChatGPT sign-in failed: \(message)"
    case .tokenExchangeFailed(let message): return "ChatGPT rejected the sign-in: \(message)"
    case .invalidResponse: return "Invalid response from ChatGPT."
    case .missingIDToken: return "ChatGPT's response contained no ID token."
    case .keychainWriteFailed: return "Could not save your ChatGPT sign-in to the Keychain."
    }
  }
}

// MARK: - Service

/// "Sign in with ChatGPT": OAuth (PKCE) against auth.openai.com, token storage and refresh, sign-out.
///
/// The UI binds to the published properties below and calls `connect()`, `signOut()`; request code
/// asks `validAccessToken()`, which refreshes when less than five minutes remain and serializes
/// concurrent refreshes (the refresh token rotates, two parallel refreshes would invalidate each
/// other). Nothing here ever logs a token, code, verifier, or an authorize URL — the reauthorization
/// URL carries `id_token_hint`. Log lines use the `CHATGPT-PLAN` prefix.
@MainActor
final class ChatGPTPlanOAuthService: NSObject, ObservableObject {
  static let shared = ChatGPTPlanOAuthService()

  // MARK: Published state (for the UI)

  /// The signed-in account's email, or nil when signed out / the session expired.
  @Published private(set) var accountEmail: String?
  /// True when signed in and `chatgpt.tokens.use.direct` was granted. False with a non-nil
  /// `accountEmail` means "signed in, but plan use wasn't allowed": offer a retry via `connect()`.
  @Published private(set) var planEnabled: Bool = false
  /// True while `connect()` or `signOut()` is running.
  @Published private(set) var isBusy: Bool = false
  /// User-facing message of the last failed `connect()` / `signOut()` / refresh; cleared on success.
  @Published private(set) var lastError: String?
  /// True after a terminal refresh error or a rejected token: sign in again (the registration is kept).
  @Published private(set) var needsSignIn: Bool = false

  // MARK: Dependencies

  private let store: ChatGPTPlanCredentialStoring
  private let transport: ChatGPTPlanTransport
  private let verifySignatureOverride: ChatGPTPlanIDTokenValidator.SignatureVerifier?
  private let now: () -> Date
  private let defaults: UserDefaults
  private let revocationRetryDelays: [UInt64]

  private var pendingContinuation: CheckedContinuation<URLComponents, Error>?
  private var authSession: ASWebAuthenticationSession?
  private var listener: LoopbackOAuthListener?
  private var refreshTask: Task<String, Error>?
  private var discovery: [String: Any]?
  private var cachedKeys: [ChatGPTPlanIDTokenValidator.JWK]?

  init(
    store: ChatGPTPlanCredentialStoring = KeychainChatGPTPlanStore(),
    transport: @escaping ChatGPTPlanTransport = ChatGPTPlanOAuthService.liveTransport,
    verifySignature: ChatGPTPlanIDTokenValidator.SignatureVerifier? = nil,
    defaults: UserDefaults = .standard,
    now: @escaping () -> Date = Date.init,
    revocationRetryDelays: [UInt64] = [0, 1_000_000_000, 2_000_000_000]
  ) {
    self.store = store
    self.transport = transport
    self.verifySignatureOverride = verifySignature
    self.defaults = defaults
    self.now = now
    self.revocationRetryDelays = revocationRetryDelays
    super.init()
    refreshState()
  }

  nonisolated static let liveTransport: ChatGPTPlanTransport = { request in
    var request = request
    request.timeoutInterval = 30
    let (data, response) = try await LLMHTTPSession.integrations.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw ChatGPTPlanSignInError.invalidResponse }
    return (data, http)
  }

  /// Re-reads the stored record into the published properties. Call after anything else may have
  /// changed the Keychain item.
  func refreshState() {
    let credentials = store.load()
    let signedIn = credentials?.hasTokens == true
    accountEmail = signedIn ? credentials?.email : nil
    planEnabled = signedIn && credentials?.planEnabled == true
  }

  // MARK: - Pure helpers (unit-tested)

  /// Percent-encodes for a query string or form body: unreserved characters only (a `+` in an
  /// email address must not turn into a space).
  static func percentEncode(_ value: String) -> String {
    // Explicit ASCII set: `CharacterSet.alphanumerics` also contains non-ASCII letters.
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  static func formEncode(_ pairs: [(String, String)]) -> String {
    pairs.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
  }

  /// The browser URL that starts an attempt.
  ///
  /// - New registration (`savedAccount == nil`): `client_id=dynamic_agent_client` plus
  ///   `agent_name_hint`, no hints.
  /// - Reauthorization: the saved issued `client_id`, `id_token_hint` (if one is retained) and
  ///   `login_hint`; **no** `agent_name_hint`. `prompt=consent` is added only when the saved sign-in
  ///   has plan use disabled, so a deliberate retry actually shows the consent screen.
  static func authorizeURL(
    savedAccount: ChatGPTPlanCredentials?,
    hostID: String,
    redirectURI: String,
    state: String,
    nonce: String,
    codeChallenge: String
  ) -> URL? {
    var pairs: [(String, String)] = []
    if let saved = savedAccount {
      pairs.append(("client_id", saved.clientID))
    } else {
      pairs.append(("client_id", ChatGPTPlanOAuthConfig.dynamicClientID))
      pairs.append(("agent_name_hint", ChatGPTPlanOAuthConfig.agentName))
    }
    pairs.append(("ext_agent_host_id", hostID))
    if let saved = savedAccount {
      if !saved.idToken.isEmpty { pairs.append(("id_token_hint", saved.idToken)) }
      if !saved.email.isEmpty { pairs.append(("login_hint", saved.email)) }
    }
    pairs += [
      ("response_type", "code"),
      ("redirect_uri", redirectURI),
      ("scope", ChatGPTPlanOAuthConfig.scopeParameter),
      ("resource", ChatGPTPlanOAuthConfig.resource),
      ("state", state),
      ("nonce", nonce),
      ("code_challenge_method", "S256"),
      ("code_challenge", codeChallenge),
    ]
    if let saved = savedAccount, !saved.planEnabled {
      pairs.append(("prompt", "consent"))
    }
    var components = URLComponents(url: ChatGPTPlanOAuthConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)
    components?.percentEncodedQuery = formEncode(pairs)
    return components?.url
  }

  /// What a valid callback means.
  enum CallbackOutcome: Equatable {
    /// `clientID` is the registration to exchange with: the one the callback issued (new
    /// registration) or the saved one (reauthorization).
    case authorized(code: String, clientID: String, scope: String?)
    /// The user declined (`error=access_denied`): stop, do not exchange.
    case declined
  }

  /// Evaluates the loopback redirect. `state` is checked first, before anything else is trusted.
  /// - Parameters:
  ///   - pendingClientID: the saved client id during reauthorization, nil for a new registration.
  static func evaluateCallback(
    _ components: URLComponents, expectedState: String, pendingClientID: String?
  ) throws -> CallbackOutcome {
    func value(_ name: String) -> String? {
      components.queryItems?.first(where: { $0.name == name })?.value
    }
    guard OAuthCSRF.accept(expected: expectedState, received: value("state"), logPrefix: "CHATGPT-PLAN") else {
      throw ChatGPTPlanSignInError.stateMismatch
    }
    if let error = value("error") {
      if error == "access_denied" { return .declined }
      let detail = value("error_description").map { ": \($0)" } ?? ""
      throw ChatGPTPlanSignInError.oauthError(error + detail)
    }
    guard let code = value("code"), !code.isEmpty else { throw ChatGPTPlanSignInError.noAuthorizationCode }

    let callbackClientID = value("client_id").flatMap { $0.isEmpty ? nil : $0 }
    let clientID: String
    if let pendingClientID {
      if let callbackClientID, callbackClientID != pendingClientID { throw ChatGPTPlanSignInError.clientIDMismatch }
      clientID = pendingClientID
    } else {
      guard let callbackClientID, callbackClientID != ChatGPTPlanOAuthConfig.dynamicClientID else {
        throw ChatGPTPlanSignInError.registrationIncomplete
      }
      clientID = callbackClientID
    }
    return .authorized(code: code, clientID: clientID, scope: value("scope"))
  }

  /// Splits a space-separated scope string. The callback form uses `+`, which `URLComponents` leaves
  /// as a literal plus, so both separators are accepted.
  static func parseScopes(_ scope: String?) -> [String] {
    (scope ?? "").split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init)
  }

  struct TokenResponse: Equatable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: TimeInterval
    /// nil when the response carried no `scope` field.
    let scopes: [String]?
  }

  static func parseTokenResponse(_ data: Data) throws -> TokenResponse {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let access = json["access_token"] as? String, !access.isEmpty
    else { throw ChatGPTPlanSignInError.invalidResponse }
    return TokenResponse(
      accessToken: access,
      refreshToken: (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
      idToken: (json["id_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
      expiresIn: (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600,
      scopes: (json["scope"] as? String).map { parseScopes($0) })
  }

  /// A successful refresh replaces access token, refresh token, expiry and scopes **together**. A
  /// response without a new refresh token keeps the old one; the ID token is untouched.
  static func applyingRefresh(
    _ response: TokenResponse, to credentials: ChatGPTPlanCredentials, now: Date
  ) -> ChatGPTPlanCredentials {
    var updated = credentials
    updated.accessToken = response.accessToken
    updated.refreshToken = response.refreshToken ?? credentials.refreshToken
    updated.expiresAt = now.addingTimeInterval(response.expiresIn)
    if let scopes = response.scopes { updated.scopes = scopes }
    updated.savedAt = now
    return updated
  }

  /// Machine-readable codes after which the refresh token is unusable.
  static let terminalRefreshErrorCodes: Set<String> = [
    "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
    "refresh_token_invalidated", "refresh_token_reused",
  ]

  /// The OAuth error code of a token-endpoint error body (`{"error":"invalid_grant"}` or a nested
  /// `{"error":{"code":…}}`), plus a description when there is one.
  static func oauthError(from data: Data) -> (code: String?, description: String?) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
    if let code = json["error"] as? String {
      return (code, json["error_description"] as? String)
    }
    if let nested = json["error"] as? [String: Any] {
      return (nested["code"] as? String, nested["message"] as? String)
    }
    return (json["code"] as? String, json["error_description"] as? String ?? json["message"] as? String)
  }

  // MARK: - PKCE

  private static func generateCodeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return base64URLEncode(Data(bytes))
  }

  private static func codeChallengeS256(verifier: String) -> String {
    base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  private static func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  // MARK: - Sign in

  /// Runs the browser flow and stores the result. Returns `false` when the user closed the sheet or
  /// declined consent (stay silent); throws for real failures (also mirrored into `lastError`).
  ///
  /// With a saved registration this reauthorizes it (same `client_id`, the new ID token's `sub`
  /// must match). `useDifferentAccount: true` ignores the saved registration and registers a new
  /// client; the saved record is only replaced once the new identity is validated.
  @discardableResult
  func connect(useDifferentAccount: Bool = false) async throws -> Bool {
    guard pendingContinuation == nil, !isBusy else { throw ChatGPTPlanSignInError.authorizationInProgress }
    isBusy = true
    lastError = nil
    defer { isBusy = false }
    // A refresh in flight would otherwise save its rotated tokens over the new sign-in.
    await awaitRefreshInFlight()
    do {
      let signedIn = try await runConnect(useDifferentAccount: useDifferentAccount)
      if signedIn { needsSignIn = false }
      return signedIn
    } catch {
      lastError = error.localizedDescription
      DebugLogger.logError("CHATGPT-PLAN: Sign-in failed: \(error.logDescription)")
      throw error
    }
  }

  private func runConnect(useDifferentAccount: Bool) async throws -> Bool {
    let saved = useDifferentAccount ? nil : store.load()
    let hostID = saved?.extAgentHostID.isEmpty == false ? saved!.extAgentHostID : ChatGPTPlanCredentials.hostID(defaults: defaults)

    let verifier = Self.generateCodeVerifier()
    let challenge = Self.codeChallengeS256(verifier: verifier)
    let state = OAuthCSRF.makeState()
    let nonce = OAuthCSRF.makeState()

    // The listener owns the port, and the port is part of the redirect URI that has to be sent
    // identically on authorize and on the code exchange.
    let listener = try LoopbackOAuthListener(
      callbackPath: ChatGPTPlanOAuthConfig.callbackPath,
      providerName: ChatGPTPlanOAuthConfig.callbackProviderName
    ) { [weak self] components in
      guard let self else { return }
      Task { @MainActor in self.finishAuthorization(with: .success(components ?? URLComponents())) }
    }
    self.listener = listener
    let redirectURI = listener.callbackURL

    guard
      let authURL = Self.authorizeURL(
        savedAccount: saved, hostID: hostID, redirectURI: redirectURI, state: state, nonce: nonce,
        codeChallenge: challenge)
    else {
      cleanUpAuthorization()
      throw ChatGPTPlanSignInError.invalidURL
    }

    // `callbackURLScheme` is nil on purpose (see OpenRouterOAuthService): the redirect lands on
    // 127.0.0.1, so the listener completes the flow and the session's handler only fires on cancel.
    let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: nil) { [weak self] _, error in
      guard let self else { return }
      Task { @MainActor in
        self.finishAuthorization(with: .failure(error ?? ChatGPTPlanSignInError.noCallbackURL))
      }
    }
    session.prefersEphemeralWebBrowserSession = false
    session.presentationContextProvider = self
    authSession = session

    DebugLogger.log("CHATGPT-PLAN: Starting \(saved == nil ? "registration" : "reauthorization")")
    let callback: URLComponents
    do {
      callback = try await withCheckedThrowingContinuation { continuation in
        self.pendingContinuation = continuation
        if !session.start() {
          finishAuthorization(with: .failure(ChatGPTPlanSignInError.authorizationStartFailed))
        }
      }
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      DebugLogger.log("CHATGPT-PLAN: User cancelled sign-in")
      return false
    }

    let outcome = try Self.evaluateCallback(callback, expectedState: state, pendingClientID: saved?.clientID)
    guard case .authorized(let code, let clientID, let callbackScope) = outcome else {
      DebugLogger.log("CHATGPT-PLAN: Authorization declined by the user")
      return false
    }

    let tokens = try await exchangeCode(code: code, verifier: verifier, clientID: clientID, redirectURI: redirectURI)
    guard let idToken = tokens.idToken else { throw ChatGPTPlanSignInError.missingIDToken }
    let claims = try await ChatGPTPlanIDTokenValidator.validate(
      idToken: idToken, expectedClientID: clientID, expectedNonce: nonce,
      expectedSubject: saved?.subject, now: now(), verifySignature: signatureVerifier)

    let timestamp = now()
    let record = ChatGPTPlanCredentials(
      email: claims.email ?? saved?.email ?? "",
      issuer: claims.issuer,
      subject: claims.subject,
      clientID: clientID,
      extAgentHostID: hostID,
      idToken: idToken,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      expiresAt: timestamp.addingTimeInterval(tokens.expiresIn),
      scopes: tokens.scopes ?? Self.parseScopes(callbackScope),
      savedAt: timestamp)
    let previous = store.loadUncached()
    // "Use a different account" replaces the record: end the old renewable session first.
    if useDifferentAccount, let previous, let oldToken = previous.refreshToken, !oldToken.isEmpty,
      oldToken != record.refreshToken
    {
      let revoked = await revoke(refreshToken: oldToken, clientID: previous.clientID)
      DebugLogger.log("CHATGPT-PLAN: Previous session revoked before switching account (\(revoked ? "confirmed" : "NOT confirmed"))")
    }
    guard store.save(record) else { throw ChatGPTPlanSignInError.keychainWriteFailed }

    if Self.isDifferentAccount(previous: previous, new: record) {
      // The saved slug belongs to the other account's catalog; let the fallback/catalog choice apply.
      defaults.removeObject(forKey: UserDefaultsKeys.chatGPTPlanModelID)
    }
    ChatGPTPlanModelCatalog.clearCache()
    refreshState()
    DebugLogger.logSuccess("CHATGPT-PLAN: Signed in (plan use \(record.planEnabled ? "enabled" : "NOT granted"))")
    if record.planEnabled {
      Task { _ = try? await ChatGPTPlanModelCatalog.refresh() }
    }
    return true
  }

  /// True when signing in produced a different registration or identity than the one it replaces.
  static func isDifferentAccount(previous: ChatGPTPlanCredentials?, new: ChatGPTPlanCredentials) -> Bool {
    guard let previous else { return false }
    return previous.clientID != new.clientID || previous.subject != new.subject
  }

  private func awaitRefreshInFlight() async {
    if let running = refreshTask { _ = try? await running.value }
  }

  private func exchangeCode(
    code: String, verifier: String, clientID: String, redirectURI: String
  ) async throws -> TokenResponse {
    let body = Self.formEncode([
      ("grant_type", "authorization_code"),
      ("client_id", clientID),
      ("code", code),
      ("code_verifier", verifier),
      ("redirect_uri", redirectURI),
      ("resource", ChatGPTPlanOAuthConfig.resource),
    ])
    let (data, http) = try await transport(Self.formRequest(url: ChatGPTPlanOAuthConfig.tokenEndpoint, body: body))
    guard http.statusCode == 200 else {
      let error = Self.oauthError(from: data)
      let message = error.description ?? error.code ?? "HTTP \(http.statusCode)"
      DebugLogger.logError("CHATGPT-PLAN: Code exchange failed: \(error.code ?? "HTTP \(http.statusCode)")")
      throw ChatGPTPlanSignInError.tokenExchangeFailed(message)
    }
    return try Self.parseTokenResponse(data)
  }

  private static func formRequest(url: URL, body: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Data(body.utf8)
    return request
  }

  // MARK: - Access token (for requests)

  /// A bearer token valid for at least five more minutes. Refreshes when needed; concurrent callers
  /// share one refresh. Throws `ChatGPTPlanError.signInRequired` when there is no usable session and
  /// `.planNotEnabled` when the plan scope was not granted. A temporary network failure keeps the
  /// stored tokens and rethrows (or, while the current token has not actually expired, returns it).
  ///
  /// `forceRefresh` refreshes regardless of expiry: used once after an inference 401, which per
  /// OpenAI's docs is not by itself a reason to drop the session.
  func validAccessToken(forceRefresh: Bool = false) async throws -> String {
    guard let credentials = store.load(), credentials.hasTokens else { throw ChatGPTPlanError.signInRequired }
    guard credentials.planEnabled else { throw ChatGPTPlanError.planNotEnabled }
    if !forceRefresh, !credentials.needsRefresh(now: now()), let token = credentials.accessToken { return token }

    if let running = refreshTask { return try await running.value }
    let task = Task { try await self.performRefresh(force: forceRefresh) }
    refreshTask = task
    defer { refreshTask = nil }
    return try await task.value
  }

  private func performRefresh(force: Bool) async throws -> String {
    // Another process (release app vs. dev build) may have rotated the tokens since our cached
    // read: always start from the Keychain's current state.
    guard var credentials = store.loadUncached(), let refreshToken = credentials.refreshToken, !refreshToken.isEmpty
    else {
      markSignInRequired()
      throw ChatGPTPlanError.signInRequired
    }
    if !force, !credentials.needsRefresh(now: now()), let token = credentials.accessToken {
      refreshState()
      return token  // the other process already refreshed
    }
    let body = Self.formEncode([
      ("grant_type", "refresh_token"),
      ("client_id", credentials.clientID),
      ("refresh_token", refreshToken),
      ("resource", ChatGPTPlanOAuthConfig.resource),
    ])
    let usedClientID = credentials.clientID
    let (data, http) = try await transport(Self.formRequest(url: ChatGPTPlanOAuthConfig.tokenEndpoint, body: body))
    try Task.checkCancellation()

    // What is stored now; the record may have changed during the network call.
    let current = store.loadUncached()
    let recordUnchanged = current?.clientID == usedClientID && current?.refreshToken == refreshToken

    guard http.statusCode == 200 else {
      let error = Self.oauthError(from: data)
      if let code = error.code, Self.terminalRefreshErrorCodes.contains(code) {
        guard recordUnchanged, let current else {
          // Someone else rotated or replaced the tokens: their record wins, ours was just stale.
          DebugLogger.log("CHATGPT-PLAN: Refresh token was superseded elsewhere (\(code)); adopting stored record")
          refreshState()
          if let stored = current, stored.hasTokens, let token = stored.accessToken, !token.isEmpty { return token }
          throw ChatGPTPlanError.signInRequired
        }
        DebugLogger.logError("CHATGPT-PLAN: Refresh token unusable (\(code)); sign-in required")
        // Keep client id, identity, ID token and host id; only the tokens go.
        credentials = current.clearingTokens()
        store.save(credentials)
        markSignInRequired()
        throw ChatGPTPlanError.signInRequired
      }
      DebugLogger.logError("CHATGPT-PLAN: Refresh failed (HTTP \(http.statusCode), \(error.code ?? "no code"))")
      // Temporary failure: a token that has not really expired yet is still good.
      if let expiresAt = credentials.expiresAt, expiresAt > now(), let token = credentials.accessToken, !token.isEmpty {
        return token
      }
      throw ChatGPTPlanError.other(
        status: http.statusCode, message: error.description ?? error.code ?? "token refresh failed",
        requestID: nil)
    }

    let response = try Self.parseTokenResponse(data)
    guard recordUnchanged, let current else {
      // Signed out, replaced or rotated while we were refreshing: do not overwrite it.
      DebugLogger.log("CHATGPT-PLAN: Stored record changed during refresh; discarding the result")
      refreshState()
      if let stored = self.store.loadUncached(), stored.hasTokens, let token = stored.accessToken, !token.isEmpty {
        return token
      }
      throw ChatGPTPlanError.signInRequired
    }
    let updated = Self.applyingRefresh(response, to: current, now: now())
    guard store.save(updated) else { throw ChatGPTPlanSignInError.keychainWriteFailed }
    refreshState()
    DebugLogger.log("CHATGPT-PLAN: Access token refreshed")
    return response.accessToken
  }

  private func markSignInRequired() {
    needsSignIn = true
    lastError = ChatGPTPlanError.signInRequired.errorDescription
    refreshState()
  }

  // MARK: - Sign out

  /// Revokes the renewable session at OpenAI, then clears the tokens locally **either way**
  /// (registration, identity and host id stay for the next sign-in). Returns whether OpenAI
  /// confirmed the revocation; `false` means the user should disconnect the app in ChatGPT Settings.
  @discardableResult
  func signOut() async -> Bool {
    isBusy = true
    defer { isBusy = false }
    // Let a refresh in flight finish first: its rotated refresh token is the one to revoke, and it
    // must not save tokens back after we cleared them.
    await awaitRefreshInFlight()

    guard let credentials = store.loadUncached() else {
      refreshState()
      return true
    }
    var confirmed = true
    if let refreshToken = credentials.refreshToken, !refreshToken.isEmpty {
      confirmed = await revoke(refreshToken: refreshToken, clientID: credentials.clientID)
    }
    store.save(credentials.clearingTokens(forgetIDToken: true))
    needsSignIn = false
    lastError = nil
    refreshState()
    ChatGPTPlanModelCatalog.clearCache()
    DebugLogger.log("CHATGPT-PLAN: Signed out (revocation \(confirmed ? "confirmed" : "NOT confirmed"))")
    return confirmed
  }

  /// Removes the saved registration entirely, so the next sign-in registers a new client. Use for
  /// "sign in with a different ChatGPT account" after a sign-out.
  func forgetAccount() {
    store.delete()
    needsSignIn = false
    lastError = nil
    refreshState()
    ChatGPTPlanModelCatalog.clearCache()
  }

  private func revoke(refreshToken: String, clientID: String) async -> Bool {
    for delay in revocationRetryDelays {
      if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
      do {
        let endpoint = try await revocationEndpoint()
        let body = Self.formEncode([
          ("token", refreshToken), ("token_type_hint", "refresh_token"), ("client_id", clientID),
        ])
        let (_, http) = try await transport(Self.formRequest(url: endpoint, body: body))
        if http.statusCode == 200 { return true }
        // A 4xx will not improve by retrying; only network failures and 5xx do.
        if !(500...599).contains(http.statusCode) { return false }
      } catch {
        continue
      }
    }
    return false
  }

  // MARK: - Discovery and JWKS

  private func discoveryDocument() async throws -> [String: Any] {
    if let discovery { return discovery }
    var request = URLRequest(url: ChatGPTPlanOAuthConfig.discoveryEndpoint)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, http) = try await transport(request)
    guard http.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ChatGPTPlanSignInError.invalidResponse
    }
    discovery = json
    return json
  }

  private func revocationEndpoint() async throws -> URL {
    let document = try await discoveryDocument()
    guard let text = document["revocation_endpoint"] as? String, let url = URL(string: text),
      url.scheme == "https", url.host?.hasSuffix("openai.com") == true
    else { throw ChatGPTPlanSignInError.invalidResponse }
    return url
  }

  private func jwks(reload: Bool) async throws -> [ChatGPTPlanIDTokenValidator.JWK] {
    if !reload, let cachedKeys { return cachedKeys }
    let uri = (try? await discoveryDocument())?["jwks_uri"] as? String
    let url = uri.flatMap(URL.init(string:)) ?? ChatGPTPlanOAuthConfig.fallbackJWKSURL
    guard url.scheme == "https", url.host?.hasSuffix("openai.com") == true else {
      throw ChatGPTPlanIDTokenValidator.ValidationError.jwksUnavailable
    }
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, http) = try await transport(request)
    guard http.statusCode == 200 else { throw ChatGPTPlanIDTokenValidator.ValidationError.jwksUnavailable }
    let keys = try ChatGPTPlanIDTokenValidator.parseJWKS(data)
    cachedKeys = keys
    return keys
  }

  private var signatureVerifier: ChatGPTPlanIDTokenValidator.SignatureVerifier {
    if let verifySignatureOverride { return verifySignatureOverride }
    return { [unowned self] jwt, _ in
      do {
        try ChatGPTPlanIDTokenValidator.verifyRS256(jwt: jwt, keys: try await self.jwks(reload: false))
      } catch ChatGPTPlanIDTokenValidator.ValidationError.keyNotFound {
        // OpenAI may have rotated keys since the cache was filled.
        try ChatGPTPlanIDTokenValidator.verifyRS256(jwt: jwt, keys: try await self.jwks(reload: true))
      }
    }
  }

  // MARK: - Flow completion

  /// Idempotent: the listener and the sheet's completion handler race by design (see
  /// `OpenRouterOAuthService.finishAuthorization`).
  private func finishAuthorization(with result: Result<URLComponents, Error>) {
    guard let continuation = pendingContinuation else { return }
    pendingContinuation = nil
    cleanUpAuthorization()
    switch result {
    case .success(let components): continuation.resume(returning: components)
    case .failure(let error): continuation.resume(throwing: error)
    }
  }

  private func cleanUpAuthorization() {
    authSession?.cancel()
    authSession = nil
    listener?.stop()
    listener = nil
  }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension ChatGPTPlanOAuthService: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? ASPresentationAnchor()
  }
}

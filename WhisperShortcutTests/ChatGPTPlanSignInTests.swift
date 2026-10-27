import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The sign-in contract from OpenAI's "Sign in with ChatGPT" preview docs: authorize URL shape,
/// callback validation, scope gating, and token refresh/clear semantics.
@Suite("ChatGPT plan sign-in", .serialized)
@MainActor
struct ChatGPTPlanSignInTests {
  typealias F = ChatGPTPlanFixtures

  private let redirect = "http://127.0.0.1:54321/auth/callback"

  private func authorizeURL(saved: ChatGPTPlanCredentials?) throws -> URL {
    try #require(
      ChatGPTPlanOAuthService.authorizeURL(
        savedAccount: saved, hostID: "urn:uuid:host", redirectURI: redirect, state: "st", nonce: "no",
        codeChallenge: "chal"))
  }

  // MARK: Authorize URL

  @Test("New registration: dynamic client, agent name and host id, no hints")
  func newRegistrationURL() throws {
    let url = try authorizeURL(saved: nil)
    #expect(url.host == "auth.openai.com")
    #expect(url.path == "/api/accounts/authorize")
    #expect(F.queryValue("client_id", in: url) == "dynamic_agent_client")
    #expect(F.queryValue("agent_name_hint", in: url) == "WhisperShortcut")
    #expect(F.queryValue("ext_agent_host_id", in: url) == "urn:uuid:host")
    let names = F.queryNames(in: url)
    #expect(!names.contains("id_token_hint"))
    #expect(!names.contains("login_hint"))
    #expect(!names.contains("prompt"))
  }

  @Test("Reauthorization: saved client id and hints, no agent_name_hint")
  func reauthURL() throws {
    let url = try authorizeURL(saved: F.credentials())
    #expect(F.queryValue("client_id", in: url) == "oaiapp_saved")
    #expect(F.queryValue("id_token_hint", in: url) == "saved.id.token")
    #expect(F.queryValue("login_hint", in: url) == "me@example.com")
    #expect(F.queryValue("ext_agent_host_id", in: url) == "urn:uuid:host")
    #expect(!F.queryNames(in: url).contains("agent_name_hint"))
    #expect(!F.queryNames(in: url).contains("prompt"))
  }

  @Test("After sign-out (no retained ID token) the hint is omitted but the email stays")
  func reauthWithoutIDToken() throws {
    let url = try authorizeURL(saved: F.credentials(idToken: ""))
    #expect(!F.queryNames(in: url).contains("id_token_hint"))
    #expect(F.queryValue("login_hint", in: url) == "me@example.com")
  }

  @Test("Retrying after plan use was not granted forces the consent screen")
  func reauthForcesConsentWhenPlanDisabled() throws {
    let url = try authorizeURL(saved: F.credentials(scopes: ["openid", "email"]))
    #expect(F.queryValue("prompt", in: url) == "consent")
  }

  @Test("Redirect is loopback 127.0.0.1 with /auth/callback, with PKCE S256, scopes and resource")
  func commonParameters() throws {
    let url = try authorizeURL(saved: nil)
    let redirectURI = try #require(F.queryValue("redirect_uri", in: url))
    let parsed = try #require(URLComponents(string: redirectURI))
    #expect(parsed.host == "127.0.0.1")
    #expect(parsed.path == "/auth/callback")
    #expect(parsed.scheme == "http")
    #expect(F.queryValue("response_type", in: url) == "code")
    #expect(F.queryValue("code_challenge_method", in: url) == "S256")
    #expect(F.queryValue("code_challenge", in: url) == "chal")
    #expect(F.queryValue("resource", in: url) == "https://api.openai.com/v1")
    #expect(F.queryValue("state", in: url) == "st")
    #expect(F.queryValue("nonce", in: url) == "no")
    let scopes = Set((F.queryValue("scope", in: url) ?? "").split(separator: " ").map(String.init))
    #expect(
      scopes == [
        "openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct",
      ])
  }

  @Test("A plus sign in an email address is encoded, not read back as a space")
  func plusInEmailSurvives() throws {
    let url = try authorizeURL(saved: F.credentials(email: "a+b@example.com"))
    #expect(url.absoluteString.contains("login_hint=a%2Bb%40example.com"))
    #expect(F.queryValue("login_hint", in: url) == "a+b@example.com")
  }

  @Test("Non-ASCII characters are percent-encoded as UTF-8, not passed through")
  func nonASCIILoginHint() throws {
    let url = try authorizeURL(saved: F.credentials(email: "jörg+ä@example.com"))
    #expect(url.absoluteString.contains("login_hint=j%C3%B6rg%2B%C3%A4%40example.com"))
    #expect(F.queryValue("login_hint", in: url) == "jörg+ä@example.com")
    #expect(ChatGPTPlanOAuthService.percentEncode("A-z0_9.~ é") == "A-z0_9.~%20%C3%A9")
  }

  @Test("The loopback listener hands out the exact path the docs require")
  func listenerUsesAuthCallbackPath() throws {
    let listener = try LoopbackOAuthListener(
      callbackPath: ChatGPTPlanOAuthConfig.callbackPath, providerName: "ChatGPT") { _ in }
    defer { listener.stop() }
    let parsed = try #require(URLComponents(string: listener.callbackURL))
    #expect(parsed.host == "127.0.0.1")
    #expect(parsed.path == "/auth/callback")
  }

  // MARK: Callback evaluation

  private func callback(_ items: [String: String]) -> URLComponents {
    var components = URLComponents()
    components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
    return components
  }

  @Test("A callback with the wrong state is refused")
  func stateMismatch() {
    #expect(throws: ChatGPTPlanSignInError.stateMismatch) {
      try ChatGPTPlanOAuthService.evaluateCallback(
        callback(["code": "c", "state": "other", "client_id": "oaiapp_x"]), expectedState: "st",
        pendingClientID: nil)
    }
  }

  @Test("State is checked before an error is believed")
  func stateCheckedBeforeDecline() {
    #expect(throws: ChatGPTPlanSignInError.stateMismatch) {
      try ChatGPTPlanOAuthService.evaluateCallback(
        callback(["error": "access_denied", "state": "other"]), expectedState: "st", pendingClientID: nil)
    }
  }

  @Test("access_denied stops the attempt without a code")
  func accessDenied() throws {
    let outcome = try ChatGPTPlanOAuthService.evaluateCallback(
      callback(["error": "access_denied", "state": "st"]), expectedState: "st", pendingClientID: nil)
    #expect(outcome == .declined)
  }

  @Test("A new registration without an issued client_id is incomplete")
  func registrationWithoutClientID() {
    #expect(throws: ChatGPTPlanSignInError.registrationIncomplete) {
      try ChatGPTPlanOAuthService.evaluateCallback(
        callback(["code": "c", "state": "st"]), expectedState: "st", pendingClientID: nil)
    }
    #expect(throws: ChatGPTPlanSignInError.registrationIncomplete) {
      try ChatGPTPlanOAuthService.evaluateCallback(
        callback(["code": "c", "state": "st", "client_id": "dynamic_agent_client"]),
        expectedState: "st", pendingClientID: nil)
    }
  }

  @Test("Reauthorization rejects a different client_id and tolerates an absent one")
  func reauthClientID() throws {
    #expect(throws: ChatGPTPlanSignInError.clientIDMismatch) {
      try ChatGPTPlanOAuthService.evaluateCallback(
        callback(["code": "c", "state": "st", "client_id": "oaiapp_other"]), expectedState: "st",
        pendingClientID: "oaiapp_saved")
    }
    let outcome = try ChatGPTPlanOAuthService.evaluateCallback(
      callback(["code": "c", "state": "st"]), expectedState: "st", pendingClientID: "oaiapp_saved")
    #expect(outcome == .authorized(code: "c", clientID: "oaiapp_saved", scope: nil))
  }

  @Test("A valid new-registration callback yields the code and the issued client id")
  func successfulCallback() throws {
    let outcome = try ChatGPTPlanOAuthService.evaluateCallback(
      callback(["code": "abc", "state": "st", "client_id": "oaiapp_new", "scope": "openid+email"]),
      expectedState: "st", pendingClientID: nil)
    #expect(outcome == .authorized(code: "abc", clientID: "oaiapp_new", scope: "openid+email"))
  }

  // MARK: Scopes

  @Test("Plan use needs chatgpt.tokens.use.direct; identity scopes alone do not enable it")
  func scopeGate() {
    #expect(F.credentials().planEnabled)
    #expect(!F.credentials(scopes: ["openid", "profile", "email", "offline_access"]).planEnabled)
    #expect(ChatGPTPlanOAuthService.parseScopes("a b+c") == ["a", "b", "c"])
  }

  // MARK: Refresh

  private func service(
    _ record: ChatGPTPlanCredentials?, transport: FakeTransport = FakeTransport([])
  ) -> (ChatGPTPlanOAuthService, MemoryChatGPTPlanStore, FakeTransport) {
    let store = MemoryChatGPTPlanStore(record)
    let service = ChatGPTPlanOAuthService(
      store: store, transport: transport.transport, verifySignature: { _, _ in },
      defaults: UserDefaults(suiteName: "chatgpt-plan-tests-\(UUID().uuidString)")!,
      now: { F.now }, revocationRetryDelays: [0, 0, 0])
    return (service, store, transport)
  }

  @Test("A fresh access token is returned without any network call")
  func freshTokenNoRefresh() async throws {
    let (service, _, transport) = service(F.credentials())
    #expect(try await service.validAccessToken() == "access-old")
    #expect(transport.requests.isEmpty)
  }

  @Test("A refresh replaces access, refresh, expiry and scopes together")
  func refreshReplacesEverything() async throws {
    let stale = F.credentials(expiresAt: F.now.addingTimeInterval(60))  // under the 5 min margin
    let transport = FakeTransport([
      .init(
        status: 200,
        body: #"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":3600,"scope":"openid email chatgpt.tokens.use.direct","token_type":"Bearer"}"#)
    ])
    let (service, store, _) = service(stale, transport: transport)

    #expect(try await service.validAccessToken() == "access-new")

    let saved = try #require(store.record)
    #expect(saved.accessToken == "access-new")
    #expect(saved.refreshToken == "refresh-new")
    #expect(saved.expiresAt == F.now.addingTimeInterval(3600))
    #expect(Set(saved.scopes) == ["openid", "email", "chatgpt.tokens.use.direct"])
    #expect(saved.clientID == "oaiapp_saved")

    let body = transport.formBody(at: 0)
    #expect(body["grant_type"] == "refresh_token")
    #expect(body["client_id"] == "oaiapp_saved")
    #expect(body["refresh_token"] == "refresh-old")
    #expect(body["resource"] == "https://api.openai.com/v1")
    #expect(body["scope"] == nil)
    #expect(transport.requests[0].url == ChatGPTPlanOAuthConfig.tokenEndpoint)
  }

  @Test("A terminal refresh error clears the tokens but keeps registration and identity")
  func terminalRefreshErrorClearsTokens() async throws {
    for code in ["invalid_grant", "refresh_token_reused", "token_expired"] {
      let stale = F.credentials(expiresAt: F.now.addingTimeInterval(-10))
      let (service, store, _) = service(
        stale, transport: FakeTransport([.init(status: 400, body: #"{"error":"\#(code)"}"#)]))

      await #expect(throws: ChatGPTPlanError.signInRequired) {
        _ = try await service.validAccessToken()
      }

      let saved = try #require(store.record)
      #expect(saved.accessToken == nil)
      #expect(saved.refreshToken == nil)
      #expect(saved.expiresAt == nil)
      #expect(saved.clientID == "oaiapp_saved")
      #expect(saved.email == "me@example.com")
      #expect(saved.subject == "sub-123")
      #expect(saved.idToken == "saved.id.token")
      #expect(saved.extAgentHostID == stale.extAgentHostID)
      #expect(service.needsSignIn)
      #expect(service.accountEmail == nil)
    }
  }

  @Test("A temporary failure keeps the tokens")
  func transientRefreshFailureKeepsTokens() async throws {
    let stale = F.credentials(expiresAt: F.now.addingTimeInterval(-10))
    let (service, store, _) = service(stale, transport: FakeTransport([.init(status: 503, body: "{}")]))
    await #expect(throws: (any Error).self) { _ = try await service.validAccessToken() }
    #expect(store.record?.refreshToken == "refresh-old")
    #expect(!service.needsSignIn)
  }

  @Test("A temporary failure inside the refresh margin returns the still-valid token")
  func transientFailureReturnsUnexpiredToken() async throws {
    let soon = F.credentials(expiresAt: F.now.addingTimeInterval(60))  // inside the margin, not expired
    let (service, store, _) = service(soon, transport: FakeTransport([.init(status: 503, body: "{}")]))
    #expect(try await service.validAccessToken() == "access-old")
    #expect(store.record?.refreshToken == "refresh-old")
  }

  @Test("forceRefresh refreshes a token that still looks valid (used once after an inference 401)")
  func forceRefreshIgnoresExpiry() async throws {
    let transport = FakeTransport([
      .init(status: 200, body: #"{"access_token":"access-forced","refresh_token":"refresh-2","expires_in":3600}"#)
    ])
    let (service, store, _) = service(F.credentials(), transport: transport)
    #expect(try await service.validAccessToken(forceRefresh: true) == "access-forced")
    #expect(transport.requests.count == 1)
    #expect(store.record?.refreshToken == "refresh-2")
  }

  @Test("A non-terminal failure on a forced refresh keeps the refresh token")
  func forcedRefreshFailureKeepsRefreshToken() async throws {
    let (service, store, _) = service(
      F.credentials(), transport: FakeTransport([.init(status: 503, body: "{}")]))
    _ = try? await service.validAccessToken(forceRefresh: true)
    #expect(store.record?.refreshToken == "refresh-old")
    #expect(!service.needsSignIn)
  }

  @Test("The refresh reads the Keychain uncached: a token another process rotated is used, not refreshed again")
  func refreshAdoptsExternallyRefreshedRecord() async throws {
    let stale = F.credentials(expiresAt: F.now.addingTimeInterval(-10))
    let (service, store, transport) = service(stale)
    store.externalRecord = F.credentials(accessToken: "access-other", refreshToken: "refresh-other")
    #expect(try await service.validAccessToken() == "access-other")
    #expect(transport.requests.isEmpty)
  }

  @Test("refresh_token_reused after another process rotated the token adopts the stored record instead of clearing it")
  func terminalErrorAdoptsRotatedRecord() async throws {
    let stale = F.credentials(expiresAt: F.now.addingTimeInterval(-10))
    let store = MemoryChatGPTPlanStore(stale)
    let rotated = F.credentials(accessToken: "access-other", refreshToken: "refresh-other")
    let transport: ChatGPTPlanTransport = { request in
      store.externalRecord = rotated  // the other process wins the race during our request
      let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
      return (Data(#"{"error":"refresh_token_reused"}"#.utf8), response)
    }
    let service = ChatGPTPlanOAuthService(
      store: store, transport: transport, verifySignature: { _, _ in },
      defaults: UserDefaults(suiteName: "chatgpt-plan-tests-\(UUID().uuidString)")!,
      now: { F.now }, revocationRetryDelays: [0])
    // First read (uncached) still sees the stale record; only the post-failure re-read sees the new one.
    #expect(try await service.validAccessToken() == "access-other")
    #expect(!service.needsSignIn)
    #expect(store.record?.refreshToken == "refresh-old")  // we did not clear or overwrite it
  }

  @Test("A successful refresh does not overwrite a record that was replaced during the request")
  func refreshDoesNotOverwriteReplacedRecord() async throws {
    let stale = F.credentials(expiresAt: F.now.addingTimeInterval(-10))
    let store = MemoryChatGPTPlanStore(stale)
    let replaced = F.credentials(clientID: "oaiapp_other", accessToken: "access-new-account", refreshToken: "refresh-new-account")
    let transport: ChatGPTPlanTransport = { request in
      store.record = replaced  // sign-in with another account completes meanwhile
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(#"{"access_token":"access-stale","refresh_token":"refresh-stale","expires_in":3600}"#.utf8), response)
    }
    let service = ChatGPTPlanOAuthService(
      store: store, transport: transport, verifySignature: { _, _ in },
      defaults: UserDefaults(suiteName: "chatgpt-plan-tests-\(UUID().uuidString)")!,
      now: { F.now }, revocationRetryDelays: [0])
    _ = try? await service.validAccessToken()
    #expect(store.record == replaced)
  }

  @Test("Configured means plan scope AND tokens: sign-out and expiry make it false")
  func configuredNeedsTokens() {
    #expect(ChatGPTPlanPreferences.isConfigured(for: F.credentials()))
    #expect(!ChatGPTPlanPreferences.isConfigured(for: F.credentials().clearingTokens()))
    #expect(!ChatGPTPlanPreferences.isConfigured(for: F.credentials(scopes: ["openid"])))
    #expect(!ChatGPTPlanPreferences.isConfigured(for: nil))
  }

  @Test("A different client or subject counts as a different account")
  func differentAccountDetection() {
    let base = F.credentials()
    #expect(!ChatGPTPlanOAuthService.isDifferentAccount(previous: nil, new: base))
    #expect(!ChatGPTPlanOAuthService.isDifferentAccount(previous: base, new: F.credentials(accessToken: "x")))
    #expect(ChatGPTPlanOAuthService.isDifferentAccount(previous: base, new: F.credentials(clientID: "oaiapp_b")))
    #expect(ChatGPTPlanOAuthService.isDifferentAccount(previous: base, new: F.credentials(subject: "sub-other")))
  }

  @Test("A saved model slug missing from a non-empty catalog is replaced by the first listed model")
  func catalogReconcilesSavedSlug() {
    let defaults = UserDefaults(suiteName: "chatgpt-plan-catalog-\(UUID().uuidString)")!
    let entries = [
      ChatGPTPlanModelCatalog.Entry(slug: "gpt-a", displayName: "A"),
      ChatGPTPlanModelCatalog.Entry(slug: "gpt-b", displayName: "B"),
    ]
    ChatGPTPlanModelCatalog.reconcileSavedModel(with: entries, defaults: defaults)
    #expect(defaults.string(forKey: UserDefaultsKeys.chatGPTPlanModelID) == nil)  // nothing saved: untouched

    defaults.set("gpt-b", forKey: UserDefaultsKeys.chatGPTPlanModelID)
    ChatGPTPlanModelCatalog.reconcileSavedModel(with: entries, defaults: defaults)
    #expect(defaults.string(forKey: UserDefaultsKeys.chatGPTPlanModelID) == "gpt-b")

    defaults.set("retired-model", forKey: UserDefaultsKeys.chatGPTPlanModelID)
    ChatGPTPlanModelCatalog.reconcileSavedModel(with: [], defaults: defaults)
    #expect(defaults.string(forKey: UserDefaultsKeys.chatGPTPlanModelID) == "retired-model")
    ChatGPTPlanModelCatalog.reconcileSavedModel(with: entries, defaults: defaults)
    #expect(defaults.string(forKey: UserDefaultsKeys.chatGPTPlanModelID) == "gpt-a")
  }

  @Test("No tokens, or no plan scope, never reaches the network")
  func guards() async throws {
    let (signedOut, _, transport) = service(F.credentials(accessToken: nil, refreshToken: nil))
    await #expect(throws: ChatGPTPlanError.signInRequired) { _ = try await signedOut.validAccessToken() }
    let (noPlan, _, _) = service(F.credentials(scopes: ["openid"]))
    await #expect(throws: ChatGPTPlanError.planNotEnabled) { _ = try await noPlan.validAccessToken() }
    #expect(transport.requests.isEmpty)
  }

  // MARK: Sign out

  private let discoveryReply = FakeTransport.Reply(
    status: 200, body: #"{"revocation_endpoint":"https://auth.openai.com/oauth/revoke","jwks_uri":"https://auth.openai.com/.well-known/jwks.json"}"#)

  @Test("Sign-out revokes the refresh token, clears the tokens and reports confirmation")
  func signOutConfirmed() async throws {
    let transport = FakeTransport([discoveryReply, .init(status: 200, body: "")])
    let (service, store, _) = service(F.credentials(), transport: transport)

    #expect(await service.signOut())

    let revoke = transport.formBody(at: 1)
    #expect(revoke["token"] == "refresh-old")
    #expect(revoke["token_type_hint"] == "refresh_token")
    #expect(revoke["client_id"] == "oaiapp_saved")
    let saved = try #require(store.record)
    #expect(saved.accessToken == nil && saved.refreshToken == nil)
    #expect(saved.idToken == "")
    #expect(saved.clientID == "oaiapp_saved")
    #expect(service.accountEmail == nil)
  }

  @Test("Sign-out clears locally even when revocation cannot be confirmed")
  func signOutUnconfirmed() async throws {
    let transport = FakeTransport([
      discoveryReply, .init(status: 503, body: ""), .init(status: 503, body: ""), .init(status: 503, body: ""),
    ])
    let (service, store, _) = service(F.credentials(), transport: transport)

    #expect(await service.signOut() == false)
    #expect(store.record?.refreshToken == nil)
    #expect(store.record?.clientID == "oaiapp_saved")
  }

  // MARK: Host id

  @Test("The host id is a lowercase urn:uuid, generated once and then stable")
  func hostID() {
    let defaults = UserDefaults(suiteName: "chatgpt-plan-host-\(UUID().uuidString)")!
    let first = ChatGPTPlanCredentials.hostID(defaults: defaults)
    #expect(first.hasPrefix("urn:uuid:"))
    #expect(first == first.lowercased())
    #expect(UUID(uuidString: String(first.dropFirst("urn:uuid:".count))) != nil)
    #expect(ChatGPTPlanCredentials.hostID(defaults: defaults) == first)
  }

  @Test("Credentials survive a JSON round trip")
  func codableRoundTrip() throws {
    let original = F.credentials()
    let data = try ChatGPTPlanCredentials.makeEncoder().encode(original)
    let decoded = try ChatGPTPlanCredentials.makeDecoder().decode(ChatGPTPlanCredentials.self, from: data)
    #expect(decoded == original)
  }

  // MARK: Host validation

  @Test("Only genuine HTTPS openai.com hosts are accepted; look-alikes are not")
  func openAIHostValidation() throws {
    #expect(ChatGPTPlanOAuthService.isOpenAIHost(try #require(URL(string: "https://auth.openai.com/x"))))
    #expect(ChatGPTPlanOAuthService.isOpenAIHost(try #require(URL(string: "https://openai.com/x"))))
    #expect(!ChatGPTPlanOAuthService.isOpenAIHost(try #require(URL(string: "https://evilopenai.com/x"))))
    #expect(!ChatGPTPlanOAuthService.isOpenAIHost(try #require(URL(string: "https://auth.openai.com.evil.io/x"))))
    #expect(!ChatGPTPlanOAuthService.isOpenAIHost(try #require(URL(string: "http://auth.openai.com/x"))))
  }
}

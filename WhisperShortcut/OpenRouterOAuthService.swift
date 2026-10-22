import Foundation

/// Connects an OpenRouter account without the user ever seeing an API key.
///
/// Mirrors `GoogleAccountOAuthService`'s structure, but the flow is shorter: OpenRouter hands back
/// a long-lived API key rather than an access/refresh token pair, so there is nothing to refresh
/// and nothing to expire. The key lands in the same Keychain slot the manual field writes to
/// (`KeychainCredential.openRouter`), which is what lets both entry paths coexist — `SpeechService`
/// reads one slot and does not care how it was filled.
@MainActor
class OpenRouterOAuthService: NSObject, ObservableObject {
  static let shared = OpenRouterOAuthService()

  /// True when a key is present, regardless of whether it arrived via OAuth or was pasted. The UI
  /// deliberately does not distinguish the two — "connected" is about whether dictation will work.
  @Published private(set) var isConnected: Bool = false

  /// True only while the browser sheet is up. Cleared before the key exchange, matching the old
  /// continuation which was nil again by the time the code was redeemed.
  private var browserFlowActive = false

  private override init() {
    super.init()
    refreshConnectionState()
  }

  /// Re-reads the Keychain. Call after the manual key field writes, so the button state does not
  /// drift from what is actually stored.
  func refreshConnectionState() {
    let stored = KeychainManager.shared.get(.openRouter) ?? ""
    isConnected = !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - Authorization

  /// Runs the full flow and stores the resulting key. Returns `false` when the user simply closed
  /// the sheet, so callers can stay silent instead of showing an error for a deliberate cancel.
  @discardableResult
  func connect() async throws -> Bool {
    guard !browserFlowActive else {
      throw OAuthError.authorizationInProgress
    }

    let (verifier, challenge) = PKCE.make()
    let state = OAuthCSRF.makeState()

    // OpenRouter has no top-level `state` query param; it preserves query already on
    // `callback_url` and appends `code`, so the CSRF token is baked into the redirect URI.
    browserFlowActive = true
    let callbackComponents: URLComponents?
    do {
      callbackComponents = try await LoopbackBrowserAuthorization.run(logPrefix: "OPENROUTER-OAUTH") { redirectURI in
        var callback = URLComponents(string: redirectURI)
        callback?.queryItems = [URLQueryItem(name: "state", value: state)]
        guard let callbackURL = callback?.string else { return nil }
        var components = URLComponents(url: OpenRouterOAuthConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
          URLQueryItem(name: "callback_url", value: callbackURL),
          URLQueryItem(name: "code_challenge", value: challenge),
          URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components?.url
      }
    } catch {
      browserFlowActive = false
      throw Self.mapBrowserError(error)
    }
    browserFlowActive = false

    guard let callbackComponents else {
      DebugLogger.log("OPENROUTER-OAUTH: User cancelled authorization")
      return false
    }

    let receivedState = callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value
    guard OAuthCSRF.accept(expected: state, received: receivedState, logPrefix: "OPENROUTER-OAUTH") else {
      throw OAuthError.stateMismatch
    }

    guard let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value,
          !code.isEmpty
    else {
      throw OAuthError.noAuthorizationCode
    }

    try await exchangeCodeForKey(code: code, verifier: verifier)
    DebugLogger.logSuccess("OPENROUTER-OAUTH: Connected — API key stored")
    return true
  }

  // MARK: - Key Exchange

  private func exchangeCodeForKey(code: String, verifier: String) async throws {
    var request = URLRequest(url: OpenRouterOAuthConfig.keyExchangeEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "code": code,
      "code_verifier": verifier,
      "code_challenge_method": "S256",
    ])

    let (data, response) = try await LLMHTTPSession.integrations.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw OAuthError.invalidResponse
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OAuthError.invalidResponse
    }

    guard httpResponse.statusCode == 200 else {
      let message = (json["error"] as? [String: Any])?["message"] as? String
        ?? json["error"] as? String
        ?? "HTTP \(httpResponse.statusCode)"
      DebugLogger.logError("OPENROUTER-OAUTH: Key exchange failed: \(message)")
      throw OAuthError.keyExchangeFailed(message)
    }

    guard let key = json["key"] as? String, !key.isEmpty else {
      throw OAuthError.missingKey
    }

    guard KeychainManager.shared.save(key, for: .openRouter) else {
      throw OAuthError.keychainWriteFailed
    }
    refreshConnectionState()
  }

  // MARK: - Disconnect

  /// Removes our copy of the key. The key still exists on OpenRouter's side — that is deliberate,
  /// since we cannot revoke it via this flow; the UI links to the dashboard for that.
  func disconnect() {
    _ = KeychainManager.shared.delete(.openRouter)
    refreshConnectionState()
    DebugLogger.log("OPENROUTER-OAUTH: Disconnected")
  }

  /// `LoopbackBrowserAuthorization` speaks three shared failures. Everything else (a listener
  /// error, a sheet error that is not cancel) already has the type the caller should see.
  private static func mapBrowserError(_ error: Error) -> Error {
    guard let failure = error as? LoopbackBrowserAuthorization.Failure else { return error }
    switch failure {
    case .invalidAuthorizeURL: return OAuthError.invalidURL
    case .startFailed: return OAuthError.authorizationStartFailed
    case .noCallback: return OAuthError.noCallbackURL
    }
  }

  // MARK: - Errors

  enum OAuthError: LocalizedError {
    case invalidURL
    case noCallbackURL
    case noAuthorizationCode
    case keyExchangeFailed(String)
    case missingKey
    case keychainWriteFailed
    case invalidResponse
    case authorizationInProgress
    case authorizationStartFailed
    case stateMismatch

    var errorDescription: String? {
      switch self {
      case .invalidURL: return "Failed to build the OpenRouter authorization URL."
      case .noCallbackURL: return "OpenRouter did not return a callback."
      case .noAuthorizationCode: return "No authorization code in OpenRouter's callback."
      case .stateMismatch: return "OpenRouter sign-in was refused because the callback did not match this attempt. Try connecting again."
      case .keyExchangeFailed(let msg): return "OpenRouter rejected the authorization: \(msg)"
      case .missingKey: return "OpenRouter's response contained no API key."
      case .keychainWriteFailed: return "Could not save the OpenRouter key to your Keychain."
      case .invalidResponse: return "Invalid response from OpenRouter."
      case .authorizationInProgress: return "An OpenRouter authorization is already in progress."
      case .authorizationStartFailed: return "Failed to open the OpenRouter authorization window."
      }
    }
  }
}

import AuthenticationServices
import CryptoKit
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

  private var pendingContinuation: CheckedContinuation<URLComponents, Error>?
  private var authSession: ASWebAuthenticationSession?
  private var listener: LoopbackOAuthListener?

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

  // MARK: - PKCE

  private func generateCodeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Self.base64URLEncode(Data(bytes))
  }

  private func codeChallengeS256(verifier: String) -> String {
    Self.base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  private static func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  // MARK: - Authorization

  /// Runs the full flow and stores the resulting key. Returns `false` when the user simply closed
  /// the sheet, so callers can stay silent instead of showing an error for a deliberate cancel.
  @discardableResult
  func connect() async throws -> Bool {
    guard pendingContinuation == nil else {
      throw OAuthError.authorizationInProgress
    }

    let verifier = generateCodeVerifier()
    let challenge = codeChallengeS256(verifier: verifier)

    // Started before the URL is built: the listener owns the port, and the port is part of the
    // callback OpenRouter must be told about.
    let listener = try LoopbackOAuthListener { [weak self] components in
      guard let self else { return }
      Task { @MainActor in self.finishAuthorization(with: .success(components ?? URLComponents())) }
    }
    self.listener = listener

    var components = URLComponents(url: OpenRouterOAuthConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "callback_url", value: listener.callbackURL),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]

    guard let authURL = components.url else {
      cleanUpAuthorization()
      throw OAuthError.invalidURL
    }

    // `callbackURLScheme` is nil on purpose: the redirect lands on 127.0.0.1, which the session
    // cannot intercept, so the listener is what completes the flow. The session's own completion
    // handler then only ever fires when the user closes the sheet.
    let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: nil) { [weak self] _, error in
      guard let self else { return }
      Task { @MainActor in
        self.finishAuthorization(with: .failure(error ?? OAuthError.noCallbackURL))
      }
    }

    // Users often already have an openrouter.ai session in Safari; reusing it turns this into a
    // single click instead of a fresh login.
    session.prefersEphemeralWebBrowserSession = false
    session.presentationContextProvider = self
    authSession = session

    let callbackComponents: URLComponents
    do {
      callbackComponents = try await withCheckedThrowingContinuation { continuation in
        self.pendingContinuation = continuation
        if !session.start() {
          finishAuthorization(with: .failure(OAuthError.authorizationStartFailed))
        }
      }
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      DebugLogger.log("OPENROUTER-OAUTH: User cancelled authorization")
      return false
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

    let (data, response) = try await URLSession.shared.data(for: request)

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

  // MARK: - Flow completion

  /// Idempotent: the listener and the sheet's completion handler race by design — whichever lands
  /// first wins, and the other is ignored. Without this, closing the sheet after a successful
  /// redirect would resume the same continuation twice and trap.
  private func finishAuthorization(with result: Result<URLComponents, Error>) {
    guard let continuation = pendingContinuation else { return }
    pendingContinuation = nil
    cleanUpAuthorization()
    switch result {
    case .success(let components):
      continuation.resume(returning: components)
    case .failure(let error):
      continuation.resume(throwing: error)
    }
  }

  private func cleanUpAuthorization() {
    // Closes the sheet once the listener has the code, so a successful sign-in does not leave the
    // user staring at the "you can close this tab" page.
    authSession?.cancel()
    authSession = nil
    listener?.stop()
    listener = nil
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

    var errorDescription: String? {
      switch self {
      case .invalidURL: return "Failed to build the OpenRouter authorization URL."
      case .noCallbackURL: return "OpenRouter did not return a callback."
      case .noAuthorizationCode: return "No authorization code in OpenRouter's callback."
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

// MARK: - ASWebAuthenticationPresentationContextProviding

extension OpenRouterOAuthService: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? ASPresentationAnchor()
  }
}

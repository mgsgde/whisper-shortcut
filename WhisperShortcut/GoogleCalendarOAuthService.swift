import AuthenticationServices
import CryptoKit
import Foundation

@MainActor
class GoogleCalendarOAuthService: NSObject, ObservableObject {
  static let shared = GoogleCalendarOAuthService()

  @Published private(set) var isConnected: Bool = false
  private(set) var accessToken: String?
  private var accessTokenExpiry: Date?
  private var pendingContinuation: CheckedContinuation<URL, Error>?

  private override init() {
    super.init()
    isConnected = KeychainManager.shared.hasGoogleCalendarRefreshToken()
  }

  // MARK: - PKCE

  private func generateCodeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func codeChallengeS256(verifier: String) -> String {
    let data = Data(verifier.utf8)
    let hash = SHA256.hash(data: data)
    return Data(hash).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  // MARK: - Authorization

  func startAuthorization() async throws {
    let verifier = generateCodeVerifier()
    let challenge = codeChallengeS256(verifier: verifier)

    var components = URLComponents(url: GoogleCalendarOAuthConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: GoogleCalendarOAuthConfig.clientID),
      URLQueryItem(name: "redirect_uri", value: GoogleCalendarOAuthConfig.redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: GoogleCalendarOAuthConfig.scope),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
    ]

    guard let authURL = components.url else {
      throw OAuthError.invalidURL
    }

    let callbackURL: URL
    let scheme = GoogleCalendarOAuthConfig.redirectScheme

    let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { [weak self] url, error in
      guard let self else { return }
      if let error {
        self.pendingContinuation?.resume(throwing: error)
        self.pendingContinuation = nil
        return
      }
      guard let url else {
        self.pendingContinuation?.resume(throwing: OAuthError.noCallbackURL)
        self.pendingContinuation = nil
        return
      }
      self.pendingContinuation?.resume(returning: url)
      self.pendingContinuation = nil
    }

    session.presentationContextProvider = self

    callbackURL = try await withCheckedThrowingContinuation { continuation in
      self.pendingContinuation = continuation
      session.start()
    }

    guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
          let code = components.queryItems?.first(where: { $0.name == "code" })?.value
    else {
      throw OAuthError.noAuthorizationCode
    }

    try await exchangeCodeForTokens(code: code, verifier: verifier)
    DebugLogger.logSuccess("GOOGLE-CALENDAR: OAuth authorization completed")
  }

  // MARK: - Token Exchange

  private func exchangeCodeForTokens(code: String, verifier: String) async throws {
    let body: [String: String] = [
      "grant_type": "authorization_code",
      "client_id": GoogleCalendarOAuthConfig.clientID,
      "code": code,
      "redirect_uri": GoogleCalendarOAuthConfig.redirectURI,
      "code_verifier": verifier,
    ]

    let tokenResponse = try await postTokenRequest(body: body)

    if let refreshToken = tokenResponse["refresh_token"] as? String {
      _ = KeychainManager.shared.saveGoogleCalendarRefreshToken(refreshToken)
    }

    accessToken = tokenResponse["access_token"] as? String
    if let expiresIn = tokenResponse["expires_in"] as? Int {
      accessTokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))
    }
    isConnected = true
  }

  // MARK: - Token Refresh

  func refreshAccessToken() async throws -> String {
    guard let refreshToken = KeychainManager.shared.getGoogleCalendarRefreshToken() else {
      disconnect()
      throw OAuthError.notConnected
    }

    let body: [String: String] = [
      "grant_type": "refresh_token",
      "client_id": GoogleCalendarOAuthConfig.clientID,
      "refresh_token": refreshToken,
    ]

    let tokenResponse: [String: Any]
    do {
      tokenResponse = try await postTokenRequest(body: body)
    } catch {
      if let oauthError = error as? OAuthError, case .tokenExchangeFailed(let msg) = oauthError,
         msg.contains("invalid_grant") {
        disconnect()
        throw OAuthError.refreshTokenRevoked
      }
      throw error
    }

    guard let newAccessToken = tokenResponse["access_token"] as? String else {
      throw OAuthError.missingAccessToken
    }

    accessToken = newAccessToken
    if let expiresIn = tokenResponse["expires_in"] as? Int {
      accessTokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))
    }
    return newAccessToken
  }

  func getValidAccessToken() async throws -> String {
    if let token = accessToken, let expiry = accessTokenExpiry, Date() < expiry {
      return token
    }
    return try await refreshAccessToken()
  }

  // MARK: - Disconnect

  func disconnect() {
    _ = KeychainManager.shared.deleteGoogleCalendarRefreshToken()
    accessToken = nil
    accessTokenExpiry = nil
    isConnected = false
    DebugLogger.log("GOOGLE-CALENDAR: Disconnected")
  }

  // MARK: - Redirect Handling

  func handleRedirect(url: URL) {
    pendingContinuation?.resume(returning: url)
    pendingContinuation = nil
  }

  // MARK: - Helpers

  private func postTokenRequest(body: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: GoogleCalendarOAuthConfig.tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    let bodyString = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
      .joined(separator: "&")
    request.httpBody = bodyString.data(using: .utf8)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw OAuthError.invalidResponse
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OAuthError.invalidResponse
    }

    if httpResponse.statusCode != 200 {
      let errorDesc = json["error"] as? String ?? "HTTP \(httpResponse.statusCode)"
      DebugLogger.logError("GOOGLE-CALENDAR: Token request failed: \(errorDesc)")
      throw OAuthError.tokenExchangeFailed(errorDesc)
    }

    return json
  }

  // MARK: - Errors

  enum OAuthError: LocalizedError {
    case invalidURL
    case noCallbackURL
    case noAuthorizationCode
    case tokenExchangeFailed(String)
    case missingAccessToken
    case notConnected
    case refreshTokenRevoked
    case invalidResponse

    var errorDescription: String? {
      switch self {
      case .invalidURL: return "Failed to build authorization URL."
      case .noCallbackURL: return "No callback URL received."
      case .noAuthorizationCode: return "No authorization code in callback."
      case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
      case .missingAccessToken: return "No access token in response."
      case .notConnected: return "Google Calendar is not connected. Connect it in Settings."
      case .refreshTokenRevoked: return "Google Calendar access was revoked. Please connect again in Settings."
      case .invalidResponse: return "Invalid response from Google."
      }
    }
  }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension GoogleCalendarOAuthService: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? ASPresentationAnchor()
  }
}

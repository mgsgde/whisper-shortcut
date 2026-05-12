import AppKit
import Foundation

/// Manages the Trello user token in the Keychain.
///
/// Trello does not allow custom URL schemes (e.g. `whispershortcut-trello://`)
/// as the `return_url` for its authorize endpoint — it rejects them with
/// "Invalid return_url. The return URL should match the application's allowed
/// origins." We therefore use Trello's *manual* token flow:
///
///   1. App opens the browser to `trello.com/1/authorize?...` (no `return_url`).
///   2. Trello shows the token on a page after the user clicks "Allow".
///   3. The user copies the token and pastes it back into the Settings UI.
///   4. The app stores it in the Keychain.
///
/// With `expiration=never` the token does not expire, so no refresh logic is
/// needed.
@MainActor
class TrelloOAuthService: ObservableObject {
  static let shared = TrelloOAuthService()

  @Published private(set) var isConnected: Bool = false

  private init() {
    isConnected = KeychainManager.shared.hasTrelloToken()
  }

  // MARK: - Authorization

  /// Opens the system browser to the Trello authorize page so the user can
  /// generate a token. After the user clicks "Allow", Trello displays the
  /// token; the user then pastes it via `submitToken(_:)`.
  func openAuthorizationInBrowser() throws {
    let apiKey = TrelloOAuthConfig.apiKey
    guard !apiKey.isEmpty else {
      throw OAuthError.missingAPIKey
    }

    var components = URLComponents(url: TrelloOAuthConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "expiration", value: TrelloOAuthConfig.expiration),
      URLQueryItem(name: "scope", value: TrelloOAuthConfig.scope),
      URLQueryItem(name: "response_type", value: "token"),
      URLQueryItem(name: "name", value: TrelloOAuthConfig.appDisplayName),
      URLQueryItem(name: "key", value: apiKey),
    ]

    guard let authURL = components.url else {
      throw OAuthError.invalidURL
    }

    NSWorkspace.shared.open(authURL)
    DebugLogger.log("TRELLO: opened authorization in browser")
  }

  /// Persists the token the user pasted from the browser and flips
  /// `isConnected` to true. Strips whitespace; rejects empty input.
  func submitToken(_ rawToken: String) throws {
    let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      throw OAuthError.emptyToken
    }
    guard KeychainManager.shared.saveTrelloToken(token) else {
      throw OAuthError.tokenStoreFailed
    }
    isConnected = true
    DebugLogger.logSuccess("TRELLO: token saved, connected")
  }

  // MARK: - Disconnect

  /// Clears the stored user token. The API key is left intact so reconnecting
  /// does not require re-pasting it.
  func disconnect() {
    _ = KeychainManager.shared.deleteTrelloToken()
    isConnected = false
    DebugLogger.log("TRELLO: Disconnected")
  }

  // MARK: - Token Access

  /// Returns the stored user token, or throws `.notConnected` if the user has
  /// not authorized the app yet. Trello tokens do not expire, so this is a
  /// straight Keychain read with no refresh path.
  func getToken() throws -> String {
    guard let token = KeychainManager.shared.getTrelloToken(), !token.isEmpty else {
      throw OAuthError.notConnected
    }
    return token
  }

  // MARK: - Errors

  enum OAuthError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case emptyToken
    case tokenStoreFailed
    case notConnected

    var errorDescription: String? {
      switch self {
      case .missingAPIKey:
        return "Trello API key is not configured. Enter your Power-Up API key in Settings > Chat first."
      case .invalidURL:
        return "Failed to build Trello authorization URL."
      case .emptyToken:
        return "Token is empty. Paste the token shown by Trello in the browser."
      case .tokenStoreFailed:
        return "Could not save the Trello token to the Keychain."
      case .notConnected:
        return "Trello is not connected. Connect it in Settings or use /connect-trello."
      }
    }
  }
}

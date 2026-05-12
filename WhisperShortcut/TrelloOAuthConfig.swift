import Foundation

/// Configuration for the Trello "manual" token authorize flow.
///
/// Trello does not accept custom URL schemes as `return_url`, so we don't use
/// a redirect — the user copies the token from Trello's authorization page
/// after clicking "Allow" and pastes it into the app.
///
/// Authorize endpoint: https://trello.com/1/authorize
/// REST API reference: https://developer.atlassian.com/cloud/trello/rest/
enum TrelloOAuthConfig {
  /// Power-Up API key. Each user creates their own Trello Power-Up at
  /// https://trello.com/power-ups/admin to obtain a personal API key, then
  /// pastes it into the Chat settings. We store it in the Keychain.
  static var apiKey: String {
    KeychainManager.shared.getTrelloAPIKey() ?? ""
  }

  /// Where the user can generate their personal Power-Up API key.
  static let powerUpAdminURL = URL(string: "https://trello.com/power-ups/admin")!

  /// Display name shown in the Trello authorize dialog
  /// ("WhisperShortcut Chat would like to access your account").
  static let appDisplayName = "WhisperShortcut Chat"

  /// Read + write access to boards, lists, and cards.
  static let scope = "read,write"

  /// `never` means the user does not have to re-authorize after a fixed period.
  static let expiration = "never"

  static let authorizationEndpoint = URL(string: "https://trello.com/1/authorize")!
}

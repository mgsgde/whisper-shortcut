import Foundation

/// Endpoints and constants for "Sign in with ChatGPT" (OpenAI's self-serve flow for open-source,
/// locally hosted apps): the user's ChatGPT Plus/Pro plan pays for Responses API requests, no API key.
///
/// Source: https://developers.openai.com/siwc/llms-full.txt (a preview; re-read "Preview limitations"
/// and "Registration and sign-in" before changing anything here). The endpoint URLs below are the
/// production values from OpenAI's OpenID Connect discovery document.
enum ChatGPTPlanOAuthConfig {
  static let issuer = "https://auth.openai.com"
  static let authorizationEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
  static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
  static let discoveryEndpoint = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
  /// Used only if the discovery document cannot be read; otherwise its `jwks_uri` wins.
  static let fallbackJWKSURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!

  /// `resource` on authorize, code exchange and refresh; also the API base for inference.
  static let resource = "https://api.openai.com/v1"
  static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!
  static let responsesEndpoint = "https://api.openai.com/v1/responses"

  /// First-time registration entry point. Never saved or used for token exchange.
  static let dynamicClientID = "dynamic_agent_client"
  /// Display name offered to the user on the consent screen; sent on first registration only.
  static let agentName = "WhisperShortcut"

  /// The redirect must be exactly `http://127.0.0.1:<port>/auth/callback`: only the port may vary,
  /// `/callback` does not match and `localhost` is refused.
  static let callbackPath = "/auth/callback"
  static let callbackProviderName = "ChatGPT"

  /// Identity scopes plus the three that enable ChatGPT plan usage.
  static let planScope = "chatgpt.tokens.use.direct"
  static let scopes = [
    "openid", "profile", "email", "offline_access", "resource.invoke", planScope,
  ]
  static var scopeParameter: String { scopes.joined(separator: " ") }

  /// Where users review usage and manage this app's limit. Linked from usage-limit errors.
  static let usageSettingsURL = URL(string: "https://chatgpt.com/settings/usage")!

  /// Access tokens live one hour; refresh when less than this is left.
  static let refreshMargin: TimeInterval = 5 * 60
}

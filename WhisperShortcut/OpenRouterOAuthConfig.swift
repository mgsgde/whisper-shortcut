import Foundation

/// Configuration for OpenRouter's OAuth PKCE flow.
///
/// The point of this flow is that the user never handles an API key: they click Connect, sign in
/// (or sign up — OpenRouter redirects account-less visitors straight to `/sign-up` and returns them
/// here afterwards), approve, and the app receives a key it stores in the Keychain under
/// `KeychainCredential.openRouter`.
///
/// Unlike Google's OAuth this has **no client ID and no app registration** — the `code_challenge`
/// is the only thing tying the authorization to us, which is why S256 is mandatory here rather
/// than merely recommended.
///
/// Reference: https://openrouter.ai/docs/use-cases/oauth-pkce
enum OpenRouterOAuthConfig {
  static let authorizationEndpoint = URL(string: "https://openrouter.ai/auth")!

  /// Exchanges the one-time `code` for a real API key. Note this is *not* a standard OAuth token
  /// endpoint: it takes JSON, not form encoding, and returns `{"key": "sk-or-v1-…"}`.
  static let keyExchangeEndpoint = URL(string: "https://openrouter.ai/api/v1/auth/keys")!

  // The callback URL is not a constant: `LoopbackOAuthListener` binds an OS-assigned free port per
  // attempt and reports its own `http://127.0.0.1:<port>/…` address.
  //
  // A custom URL scheme was tried first and does not work. Verified 2026-08-02: `openrouter.ai/auth`
  // accepts `whispershortcut://…` unauthenticated, but once the user is signed in it silently drops
  // the request and lands them on the homepage — no consent screen, no error, and the app waits
  // forever. OpenRouter documents only https URLs and `localhost` on any port.

  /// Where users top up. Surfaced in the UI because a connected key with a zero balance is the one
  /// failure this flow cannot prevent.
  static let creditsURL = URL(string: "https://openrouter.ai/credits")!

  /// Where users can inspect or revoke the key we were issued.
  static let keysDashboardURL = URL(string: "https://openrouter.ai/keys")!
}

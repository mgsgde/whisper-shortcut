import Foundation

/// URL shaping and auth-header selection for a **bring-your-own-endpoint** deployment.
///
/// The custom-endpoint path already spoke plain OpenAI (`Authorization: Bearer` + base URL with
/// `/chat/completions` appended), which is all a proxy like OpenRouter, LiteLLM or OpenInference
/// needs. Two tenant-hosted deployments customers actually run do *not* fit that shape, and both
/// are handled here rather than in the providers:
///
///   - **Azure OpenAI / Foundry** authenticates an API key with an `api-key:` header, not a bearer
///     token. `Authorization: Bearer <azure key>` is rejected on the classic deployment surface —
///     that header is reserved for Entra ID tokens there — so a key-based Azure setup cannot work
///     without this. Detected from the host; see `isAzureHost`.
///   - **Vertex AI** is plain bearer, so it needs no special auth. What it does need is a base URL
///     carrying a query string (`?api-version=`, on the Azure side) to survive path appending,
///     which naive string concatenation broke.
///
/// Everything here is pure so the URL and header decisions are pinned by tests instead of by
/// pasting a real tenant URL into Settings and watching for a 401.
enum CustomEndpointAuth {

  /// How a given endpoint expects its API key to be presented.
  enum Flavor: Equatable {
    /// Azure OpenAI / Microsoft Foundry — key goes in `api-key`.
    case azure
    /// Everything else (OpenAI, OpenRouter, LiteLLM, Vertex AI, self-hosted) — `Authorization: Bearer`.
    case bearer
  }

  /// `api-version` used only when the user pasted a **classic** Azure deployment URL
  /// (`/openai/deployments/<name>/…`) and left the required query parameter off. The modern
  /// `/openai/v1/` surface needs no `api-version` at all and never reaches this.
  ///
  /// Pinned to a GA version on purpose: it is a rescue for a URL that would otherwise 404, not a
  /// version the app tracks. Users who need a specific one put it in the URL, and that wins.
  static let fallbackAzureAPIVersion = "2024-10-21"

  // MARK: - Flavor detection

  /// True for the Azure hosts that serve OpenAI models: `*.openai.azure.com` (Azure OpenAI),
  /// `*.services.ai.azure.com` (Foundry), `*.cognitiveservices.azure.com`, and `*.azure-api.net`
  /// (API Management, the usual front door for a locked-down tenant).
  static func isAzureHost(_ host: String) -> Bool {
    let h = host.lowercased()
    return h == "azure.com" || h.hasSuffix(".azure.com") || h.hasSuffix(".azure-api.net")
  }

  /// Picks the auth style for a base URL. Unparseable URLs fall back to bearer — the generic case,
  /// and the one that fails with a legible 401 rather than a silent misroute.
  static func flavor(forBaseURL base: String) -> Flavor {
    guard let host = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines))?.host,
          isAzureHost(host)
    else {
      return .bearer
    }
    return .azure
  }

  /// The auth headers to send with `apiKey` for this endpoint.
  /// An empty key produces no header — keyless local servers exist, and
  /// `Authorization: Bearer ` (trailing space, no token) is worse than sending nothing.
  static func headers(baseURL: String, apiKey: String) -> [String: String] {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return [:] }
    switch flavor(forBaseURL: baseURL) {
    case .azure:
      // Deliberately *only* `api-key`. Sending both headers looks harmless but is not: on the
      // classic deployment surface Azure reads `Authorization` as an Entra token and rejects the
      // request outright rather than falling back to the key.
      return ["api-key": key]
    case .bearer:
      return ["Authorization": "Bearer \(key)"]
    }
  }

  /// Whether an `sk-…` key issued by OpenAI could conceivably authenticate here.
  ///
  /// True for an **https** proxy (LiteLLM, a self-hosted gateway) — those commonly forward to
  /// api.openai.com using the caller's own OpenAI key, which is why the custom endpoint falls
  /// back to it at all. Also true for loopback over `http://` (`localhost`, `127.0.0.0/8`,
  /// `::1`): the key never leaves this Mac, and a local LiteLLM needs it. False for:
  ///   - a customer's own tenant (Azure, Vertex): that key cannot work and would be handed to
  ///     someone else's endpoint for a 401;
  ///   - any other `http://` host, including a LAN Whisper box: sending the personal OpenAI key
  ///     in cleartext is a leak, and a keyless local server does not need it.
  /// An unparseable or empty URL keeps the fallback — no request goes out until a real URL exists.
  static func acceptsOpenAIAPIKey(baseURL: String) -> Bool {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let components = URLComponents(string: trimmed),
          let host = components.host?.lowercased(), !host.isEmpty
    else {
      return true
    }
    // Cleartext stays on this machine for loopback. A LAN box or an http proxy does not.
    if components.scheme?.lowercased() != "https" { return isLoopbackHost(host) }
    if isAzureHost(host) { return false }
    // Vertex AI and every other Google API front door.
    if host == "googleapis.com" || host.hasSuffix(".googleapis.com") { return false }
    return true
  }

  /// This Mac only: `localhost`, `127.0.0.0/8`, and `::1` (URLComponents keeps the brackets
  /// on an IPv6 literal, so `[::1]` is the same host).
  private static func isLoopbackHost(_ host: String) -> Bool {
    let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if h == "localhost" || h == "::1" || h == "0:0:0:0:0:0:0:1" { return true }
    let parts = h.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    var octets: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else {
        return false
      }
      octets.append(value)
    }
    return octets[0] == 127
  }

  /// Azure follows OpenAI's own rule that reasoning models reject `max_tokens` and require
  /// `max_completion_tokens`; the OpenAI-compatible proxies and self-hosted servers behind the
  /// generic flavor only reliably understand `max_tokens`. Sending the wrong one is a hard 400,
  /// so the key is chosen per endpoint. Mirrors the split in `OpenAIChatProvider`.
  static func maxTokensKey(forBaseURL base: String) -> String {
    flavor(forBaseURL: base) == .azure ? "max_completion_tokens" : "max_tokens"
  }

  // MARK: - URL shaping

  /// Appends an API path (`chat/completions`, `audio/transcriptions`) to a user-supplied base URL.
  ///
  /// Three things this does that string concatenation did not:
  ///   - **Preserves the query string.** An Azure classic URL ends in `?api-version=…`; appending
  ///     text to it produced `…/v1?api-version=2024-10-21/chat/completions`, a 404.
  ///   - **Expands a bare Azure host** to the modern `/openai/v1` surface, so pasting the endpoint
  ///     exactly as Azure's portal shows it (`https://my-res.openai.azure.com`) works.
  ///   - **Adds a missing `api-version`** on a classic Azure deployment URL, which is required
  ///     there and is the single most common way that URL is pasted wrong.
  ///   - **Treats a pasted full endpoint as a base.** A trailing `/chat/completions`,
  ///     `/audio/transcriptions` or `/completions` is removed before the new suffix is
  ///     appended, so Dictate and Chat do not stack paths. The query string stays
  ///     (Azure `api-version`).
  ///
  /// Returns `nil` for a URL that cannot be parsed, so the caller can surface a real error rather
  /// than POST to a mangled string.
  static func endpointURL(appending pathSuffix: String, to base: String) -> String? {
    let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var components = URLComponents(string: trimmed), components.host != nil
    else {
      return nil
    }

    let isAzure = isAzureHost(components.host ?? "")

    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }

    // A bare Azure resource host is the form the portal shows. Point it at the v1 surface, which
    // needs no api-version and takes the deployment name as the `model` field.
    if isAzure && path.isEmpty {
      path = "/openai/v1"
    }

    // Longer suffixes first: `/chat/completions` also ends in `/completions`, and trimming
    // only the short one would leave `/v1/chat` in front of the new route.
    let pastedEndpointSuffixes = ["/chat/completions", "/audio/transcriptions", "/completions"]
    if let pasted = pastedEndpointSuffixes.first(where: { path.hasSuffix($0) }) {
      path.removeLast(pasted.count)
      while path.hasSuffix("/") { path.removeLast() }
    }

    if !path.hasSuffix("/\(pathSuffix)") {
      path += "/\(pathSuffix)"
    }
    components.path = path

    // Classic Azure (`/openai/deployments/<name>/…`) requires api-version; the v1 surface does not.
    if isAzure, path.contains("/deployments/") {
      var items = components.queryItems ?? []
      if !items.contains(where: { $0.name.lowercased() == "api-version" }) {
        items.append(URLQueryItem(name: "api-version", value: fallbackAzureAPIVersion))
        components.queryItems = items
      }
    }

    return components.string
  }
}

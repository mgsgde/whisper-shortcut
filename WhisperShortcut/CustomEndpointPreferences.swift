import Foundation

/// One OpenAI-compatible server for Dictate, Dictate Prompt and Chat.
///
/// Chat already stored the base URL and key (`OpenAIChatPreferences`). Dictate stored a full
/// transcription URL and its own bearer token. This type is the single read path: the Chat keys
/// stay canonical, so an existing Chat setup needs no migration, and a legacy transcription URL
/// that is just `{base}/audio/transcriptions` is folded into those keys once.
///
/// A URL that is not that shape (a bare host, whisper-asr-webservice's `/asr`, …) stays as an
/// override and keeps the previous request list. The planner is pure so those decisions are
/// pinned by tests instead of by launching the app against a user's Keychain.
enum CustomEndpointPreferences {

  /// What `migrateLegacyTranscriptionEndpointIfNeeded` should write. Nil fields mean "leave it".
  struct LegacyMigrationPlan: Equatable {
    var newChatBaseURL: String?
    var newChatKey: String?
    var clearLegacyTranscription: Bool
  }

  /// Base URL up to `/v1`, the same value Chat reads.
  static var baseURL: String? { OpenAIChatPreferences.customEndpointBaseURL }

  /// Legacy full transcription URL. Nil when unset or whitespace. Kept only for endpoints whose
  /// base cannot be derived (see `legacyMigrationPlan`).
  static var transcriptionURLOverride: String? {
    nonempty(UserDefaults.standard.string(forKey: UserDefaultsKeys.customTranscriptionAPIURL))
  }

  /// Model id sent as the multipart `model` field. Empty storage falls back to `whisper-1`,
  /// which is what the self-hosted path used to hardcode.
  static var transcriptionModelID: String {
    let stored = (UserDefaults.standard.string(forKey: UserDefaultsKeys.customTranscriptionModelID) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return stored.isEmpty ? SettingsDefaults.customTranscriptionModelID : stored
  }

  /// Where Dictate posts audio. The legacy override wins; otherwise `{base}/audio/transcriptions`,
  /// shaped the same way Chat shapes `/chat/completions` (Azure path, preserved query string).
  static var transcriptionURL: String? {
    if let override = transcriptionURLOverride { return override }
    guard let base = baseURL else { return nil }
    return CustomEndpointAuth.endpointURL(appending: "audio/transcriptions", to: base)
  }

  /// A key is optional: keyless self-hosted servers exist. Configured means a URL to POST to.
  static var isTranscriptionConfigured: Bool { transcriptionURL != nil }

  /// Chat needs a base URL and a usable key. Dictate Prompt uses the same bar.
  static var isConfigured: Bool { OpenAIChatPreferences.isConfigured }

  /// Extra headers shared by Dictate and Chat. Entries with an empty name are dropped.
  static var extraHeaders: [String: String] {
    var headers: [String: String] = [:]
    for entry in KeychainManager.shared.getCustomTranscriptionHeaders() {
      let name = (entry["key"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { continue }
      headers[name] = entry["value"] ?? ""
    }
    return headers
  }

  /// Credential for a transcription request.
  ///
  /// A legacy override that still has its own bearer token keeps that token — it may be a
  /// different server from Chat. Otherwise the Chat key (including the OpenAI-key fallback
  /// `OpenAIChatPreferences` already applies). Nil when neither is set.
  static var transcriptionCredential: String? {
    if transcriptionURLOverride != nil {
      let legacy = (KeychainManager.shared.get(.customTranscriptionBearerToken) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !legacy.isEmpty { return legacy }
    }
    return OpenAIChatPreferences.resolvedAPIKey
  }

  /// Shown when Dictate or Dictate Prompt needs the shared server and no URL is stored.
  static var transcriptionNotConfiguredMessage: String {
    String(localized: "Your own server is not set up. Add its base URL in Settings → Dictate.")
  }

  // MARK: - Legacy migration

  /// Plans the one-time fold of a legacy transcription URL into the Chat base URL.
  ///
  /// Trims every input first; empty is nil. Returns nil when there is nothing to do, or when
  /// the legacy URL must stay an override (not derivable, a different base, or two different keys).
  static func legacyMigrationPlan(
    chatBaseURL: String?,
    chatKey: String?,
    transcriptionURL: String?,
    transcriptionToken: String?
  ) -> LegacyMigrationPlan? {
    guard let transcriptionURL = nonempty(transcriptionURL) else { return nil }
    guard let derivedBase = chatBaseDerived(from: transcriptionURL) else { return nil }

    let token = nonempty(transcriptionToken)
    let key = nonempty(chatKey)
    guard let chatBase = nonempty(chatBaseURL) else {
      return LegacyMigrationPlan(
        newChatBaseURL: derivedBase,
        newChatKey: token,
        clearLegacyTranscription: true)
    }
    guard endpointsMatch(chatBase, derivedBase) else { return nil }
    if token == nil || token == key {
      return LegacyMigrationPlan(newChatBaseURL: nil, newChatKey: nil, clearLegacyTranscription: true)
    }
    if key == nil {
      return LegacyMigrationPlan(newChatBaseURL: nil, newChatKey: token, clearLegacyTranscription: true)
    }
    return nil
  }

  /// Applies `legacyMigrationPlan` once. A failed key save leaves the flag unset so the next
  /// launch retries. The log line names what changed and never the URL or the key.
  @MainActor
  static func migrateLegacyTranscriptionEndpointIfNeeded() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: UserDefaultsKeys.customEndpointUnifiedMigrationDone) else { return }

    let plan = legacyMigrationPlan(
      chatBaseURL: defaults.string(forKey: UserDefaultsKeys.customOpenAIChatEndpointURL),
      chatKey: KeychainManager.shared.get(.customOpenAIChatAPIKey),
      transcriptionURL: defaults.string(forKey: UserDefaultsKeys.customTranscriptionAPIURL),
      transcriptionToken: KeychainManager.shared.get(.customTranscriptionBearerToken))

    guard let plan else {
      defaults.set(true, forKey: UserDefaultsKeys.customEndpointUnifiedMigrationDone)
      DebugLogger.log("CUSTOM-ENDPOINT: legacy transcription migration done (kept separate or nothing to move)")
      return
    }

    if let key = plan.newChatKey, !KeychainManager.shared.save(key, for: .customOpenAIChatAPIKey) {
      DebugLogger.logWarning("CUSTOM-ENDPOINT: could not save migrated key; migration postponed")
      return
    }
    if let base = plan.newChatBaseURL {
      defaults.set(base, forKey: UserDefaultsKeys.customOpenAIChatEndpointURL)
    }
    if plan.clearLegacyTranscription {
      defaults.removeObject(forKey: UserDefaultsKeys.customTranscriptionAPIURL)
      KeychainManager.shared.delete(.customTranscriptionBearerToken)
    }
    defaults.set(true, forKey: UserDefaultsKeys.customEndpointUnifiedMigrationDone)
    DebugLogger.log(
      "CUSTOM-ENDPOINT: legacy transcription migration done (base updated=\(plan.newChatBaseURL != nil), key updated=\(plan.newChatKey != nil), legacy cleared=\(plan.clearLegacyTranscription))")
  }

  // MARK: - URL helpers

  private static func nonempty(_ value: String?) -> String? {
    let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Strips a trailing `/audio/transcriptions` (and any trailing slashes) and keeps scheme, host,
  /// port and query. Nil when the path does not end in that component.
  private static func chatBaseDerived(from transcriptionURL: String) -> String? {
    guard var components = URLComponents(string: transcriptionURL), components.host != nil else {
      return nil
    }
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    let suffix = "/audio/transcriptions"
    guard path.hasSuffix(suffix) else { return nil }
    path.removeLast(suffix.count)
    while path.hasSuffix("/") { path.removeLast() }
    components.path = path
    guard var result = components.string else { return nil }
    while result.hasSuffix("/") { result.removeLast() }
    return result
  }

  /// Case-insensitive scheme and host, trailing slashes ignored, path and query exact.
  private static func endpointsMatch(_ lhs: String, _ rhs: String) -> Bool {
    guard let a = endpointParts(lhs), let b = endpointParts(rhs) else { return false }
    return a.scheme == b.scheme && a.host == b.host && a.port == b.port && a.path == b.path && a.query == b.query
  }

  private static func endpointParts(_ raw: String) -> (scheme: String, host: String, port: Int?, path: String, query: String?)? {
    guard let components = URLComponents(string: raw), let host = components.host, !host.isEmpty else {
      return nil
    }
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    return (components.scheme?.lowercased() ?? "", host.lowercased(), components.port, path, components.query)
  }
}

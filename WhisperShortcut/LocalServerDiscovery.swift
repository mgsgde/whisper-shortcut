import Foundation

/// A server found by probing the usual local ports.
///
/// Deliberately at file scope rather than nested in `LocalServerDiscovery`: the UI holds one of
/// these as `@State`, and a nested type inside an actor-isolated enum would drag the value across
/// an actor hop for no reason.
struct DiscoveredServer: Identifiable, Equatable {
  /// Which server software answered. Only used for the label — every one of them speaks the same
  /// `GET /v1/models` and `POST /v1/audio/transcriptions`, so the request shape never changes.
  enum Kind: Equatable {
    case mlxAudio
    case lmStudio
    case liteLLM
    case ollama
    case llamaCpp
    case unknown

    /// Product names stay untranslated; only the fallback is prose.
    var displayName: String {
      switch self {
      case .mlxAudio: return "MLX"
      case .lmStudio: return "LM Studio"
      case .liteLLM: return "LiteLLM"
      case .ollama: return "Ollama"
      case .llamaCpp: return "llama.cpp"
      case .unknown: return String(localized: "Unknown server")
      }
    }
  }

  var id: String { baseURL }
  /// Base URL up to `/v1`, the shape the form stores.
  let baseURL: String
  /// `host:port`, for the one-line label in the result list.
  let host: String
  /// Model ids from `GET /v1/models`. Empty when the server answered without a list.
  let modelIDs: [String]
  let kind: Kind
}

/// Probes the ports an OpenAI-compatible server usually listens on, and reads its model list.
///
/// Setting up the own-server form meant knowing three things the user cannot see: the URL, the
/// port and the exact model id the server serves. All three were guesswork, and a wrong guess
/// surfaced as a failed dictation rather than as a wrong setting. This turns the first two into a
/// click and the third into a list the server itself reports.
///
/// Nothing here runs on its own: `probeAll()` is called from a button, and only ever against
/// `localhost`. `probe(baseURL:)` takes whatever the user typed, which is why it is never called
/// automatically — a remote host should not learn that this Mac exists because a settings pane
/// was opened.
enum LocalServerDiscovery {

  /// The five defaults, in the order the "nothing answered" line lists them.
  static let candidates: [(port: Int, kind: DiscoveredServer.Kind)] = [
    (8000, .mlxAudio),      // mlx-audio / mlx_lm.server
    (1234, .lmStudio),      // LM Studio
    (4000, .liteLLM),       // LiteLLM
    (11434, .ollama),       // Ollama
    (8080, .llamaCpp),      // llama.cpp server
  ]

  /// Two seconds for loopback: a server on this Mac either answers at once or is not running. A
  /// longer wait would make "Find servers…" feel broken rather than empty.
  static let timeout: TimeInterval = 2

  /// A typed non-local host (LAN box, VPN, remote gateway) needs time for DNS and TLS.
  static let remoteTimeout: TimeInterval = 8

  /// Loopback probes: a session of its own, not `LLMHTTPSession.integrations`, which inherits the
  /// system proxy settings and a 60 s timeout. A probe has to reach the server on this Mac, not a
  /// proxy the user configured for the internet, and it must give up quickly.
  private static let localSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.connectionProxyDictionary = [:]
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    // The Offline Mode guard allows loopback, so a local server keeps working with the mode on;
    // a typed remote URL is blocked there, which is the correct answer.
    OfflineModeURLProtocol.install(on: config)
    return URLSession(configuration: config)
  }()

  /// Typed non-local hosts: system proxy settings apply and the timeout is longer, because a
  /// remote server may only be reachable through the proxy the user configured.
  private static let remoteSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = remoteTimeout
    config.timeoutIntervalForResource = remoteTimeout
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    OfflineModeURLProtocol.install(on: config)
    return URLSession(configuration: config)
  }()

  private static func isLoopback(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
      || host.hasSuffix(".localhost")
  }

  // MARK: - Probing

  /// Probes all five ports concurrently and returns only the ones that answered 2xx, by port.
  static func probeAll() async -> [DiscoveredServer] {
    let found = await withTaskGroup(of: DiscoveredServer?.self) { group -> [DiscoveredServer] in
      for candidate in candidates {
        group.addTask { await probe(port: candidate.port, kind: candidate.kind) }
      }
      var servers: [DiscoveredServer] = []
      for await server in group {
        if let server { servers.append(server) }
      }
      return servers
    }

    let sorted = found.sorted { (port(of: $0.baseURL) ?? 0) < (port(of: $1.baseURL) ?? 0) }
    DebugLogger.log(
      "SERVER-DISCOVERY: probed \(candidates.count) ports, \(sorted.count) answered"
        + (sorted.isEmpty ? "" : ": \(sorted.map(\.host).joined(separator: ", "))"))
    return sorted
  }

  /// Probes one URL the user typed. The only path that may touch a non-localhost host, and only
  /// from an explicit button.
  ///
  /// `apiKey` is the credential the form would actually send, so a server that requires auth
  /// answers here instead of reporting "No answer" for a setup that works. It is passed in rather
  /// than read from the Keychain so the probe has no hidden dependency on the current settings.
  static func probe(
    baseURL: String, apiKey: String? = nil, headers: [String: String] = [:]
  ) async -> DiscoveredServer? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return await probe(baseURL: trimmed, kind: kind(forBaseURL: trimmed), apiKey: apiKey, headers: headers)
  }

  private static func probe(port: Int, kind: DiscoveredServer.Kind) async -> DiscoveredServer? {
    // The five default ports are probed keyless: they are loopback, and the key field belongs to
    // whichever server the URL names, not to a port scan.
    await probe(baseURL: "http://localhost:\(port)/v1", kind: kind, apiKey: nil, headers: [:])
  }

  private static func probe(
    baseURL: String, kind: DiscoveredServer.Kind, apiKey: String?, headers: [String: String]
  ) async -> DiscoveredServer? {
    guard let url = modelsURL(forBaseURL: baseURL) else {
      DebugLogger.log("SERVER-DISCOVERY: \(baseURL) is not a usable URL")
      return nil
    }

    do {
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      let loopback = isLoopback(url)
      request.timeoutInterval = loopback ? timeout : remoteTimeout
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      // Same header shaping as the real request (Azure `api-key`, everything else `Bearer`), and
      // no header at all for an empty key — a keyless local server must not receive
      // `Authorization: Bearer `.
      for (name, value) in CustomEndpointAuth.headers(baseURL: baseURL, apiKey: apiKey ?? "") {
        request.setValue(value, forHTTPHeaderField: name)
      }
      // The form's custom headers (Cloudflare Access etc.), as the real requests send them.
      for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
      let (data, response) = try await (loopback ? localSession : remoteSession).data(for: request)
      // A cancelled probe is not an answer: the caller replaced it with a newer one, so it must
      // not overwrite that newer result with "no answer".
      if Task.isCancelled { return nil }
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      let server = server(baseURL: baseURL, kind: kind, statusCode: status, data: data)
      DebugLogger.log(
        "SERVER-DISCOVERY: \(url.absoluteString) → HTTP \(status), \(server?.modelIDs.count ?? 0) models")
      return server
    } catch is CancellationError {
      DebugLogger.log("SERVER-DISCOVERY: \(url.absoluteString) → cancelled")
      return nil
    } catch let error as URLError where error.code == .cancelled {
      DebugLogger.log("SERVER-DISCOVERY: \(url.absoluteString) → cancelled")
      return nil
    } catch {
      DebugLogger.log("SERVER-DISCOVERY: \(url.absoluteString) → no answer (\(error.logDescription))")
      return nil
    }
  }

  // MARK: - Pure parts

  /// Turns one response into a server, or nil. Split out from the request so the status and body
  /// rules are pinned by tests instead of by whichever server happens to be running.
  static func server(
    baseURL: String,
    kind: DiscoveredServer.Kind,
    statusCode: Int,
    data: Data
  ) -> DiscoveredServer? {
    guard (200..<300).contains(statusCode) else { return nil }
    guard let modelIDs = decodeModelIDs(from: data) else { return nil }
    return DiscoveredServer(
      baseURL: baseURL,
      host: hostLabel(forBaseURL: baseURL),
      modelIDs: modelIDs,
      kind: kind)
  }

  /// `{"object":"list","data":[{"id":"…"}]}` — the shape OpenAI, mlx-audio, LM Studio, LiteLLM,
  /// Ollama and llama.cpp all return. Nil for anything else, so a proxy's HTML error page is not
  /// mistaken for a model list.
  static func decodeModelIDs(from data: Data) -> [String]? {
    guard let payload = try? JSONDecoder().decode(LocalModelsResponse.self, from: data) else {
      return nil
    }
    return payload.data.map(\.id)
  }

  /// `{base}/models`, with `/v1` added when the user typed only a host and port. The form's field
  /// keeps exactly what was typed; this shapes the probe only.
  ///
  /// Strips a pasted endpoint suffix first, the same way `CustomEndpointAuth.endpointURL` does for
  /// the real request: users paste the full `/v1/audio/transcriptions` URL as often as the bare
  /// base, and probing `…/audio/transcriptions/v1/models` would report "no answer" for a server
  /// that is running fine.
  static func modelsURL(forBaseURL baseURL: String) -> URL? {
    guard var components = URLComponents(string: baseURL), components.host != nil else { return nil }
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    for suffix in ["/chat/completions", "/audio/transcriptions", "/audio/speech", "/completions"]
    where path.hasSuffix(suffix) {
      path.removeLast(suffix.count)
      while path.hasSuffix("/") { path.removeLast() }
      break
    }
    if !path.hasSuffix("/v1") { path += "/v1" }
    components.path = path + "/models"
    components.query = nil
    return components.url
  }

  /// `localhost:1234` — what the result list shows.
  static func hostLabel(forBaseURL baseURL: String) -> String {
    guard let components = URLComponents(string: baseURL), let host = components.host else {
      return baseURL
    }
    return components.port.map { "\(host):\($0)" } ?? host
  }

  /// The kind of a URL the user typed: the known one when its port is a candidate's, else unknown.
  static func kind(forBaseURL baseURL: String) -> DiscoveredServer.Kind {
    guard let port = port(of: baseURL) else { return .unknown }
    return candidates.first { $0.port == port }?.kind ?? .unknown
  }

  private static func port(of baseURL: String) -> Int? {
    URLComponents(string: baseURL)?.port
  }
}

// MARK: - Wire format

private struct LocalModelsResponse: Decodable {
  let data: [Entry]

  struct Entry: Decodable {
    let id: String
  }
}

// MARK: - Known speech models

/// A short list of speech-to-text models known to work behind an OpenAI-compatible server.
///
/// These are **not** offline models of this app: they run on the user's own server, are downloaded
/// by that server (mlx-audio pulls them from Hugging Face on first use), and are never touched by
/// `ModelManager` or `OfflineModelType`. Do not wire them into the download path — the app only
/// sends the repo id as the multipart `model` field.
///
/// A curated list rather than a live Hugging Face search: the point is to remove the guesswork for
/// the common case, and a search would put the user back in front of a hundred repos with no
/// telling which ones the server can actually load.
enum KnownSpeechModels {

  struct Entry: Identifiable {
    /// The Hugging Face repo id, which is also the model id mlx-audio serves.
    let repoID: String
    /// Product name, shown as-is.
    let displayName: String
    /// Download size on the server, rounded.
    let sizeLabel: String
    /// One line on what it is for. Product facts, not prose to translate.
    let note: String

    var id: String { repoID }
  }

  static let all: [Entry] = [
    Entry(
      repoID: "mlx-community/Qwen3-ASR-0.6B-8bit",
      displayName: "Qwen3-ASR 0.6B",
      sizeLabel: "1.0 GB",
      note: "Multilingual, the popular default"),
    Entry(
      repoID: "mlx-community/Qwen3-ASR-1.7B-8bit",
      displayName: "Qwen3-ASR 1.7B",
      sizeLabel: "2.4 GB",
      note: "Multilingual, larger sibling"),
    Entry(
      repoID: "mlx-community/nemotron-3.5-asr-streaming-0.6b",
      displayName: "Nemotron 3.5 ASR 0.6B",
      sizeLabel: "1.2 GB",
      note: "Streaming, German tagged"),
    Entry(
      repoID: "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit",
      displayName: "Voxtral Mini 4B Realtime",
      sizeLabel: "3.1 GB",
      note: "Mistral, realtime, German tagged"),
    Entry(
      repoID: "mlx-community/parakeet-tdt-0.6b-v3",
      displayName: "Parakeet TDT 0.6B v3",
      sizeLabel: "2.5 GB",
      note: "NVIDIA Parakeet, 25 EU languages"),
  ]
}

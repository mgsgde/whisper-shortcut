import Foundation

/// Fires a throwaway HTTPS request to the cloud provider's host the moment recording
/// starts, so TCP + TLS setup happens while the user is still speaking instead of adding
/// 100–400 ms to the real request after an idle period. Uses `LLMHTTPSession.shared` —
/// the same connection pool every cloud transcription/prompt request goes through.
enum ConnectionPrewarmer {

  /// Pre-warms the connection for the selected transcription model. No-op for offline
  /// Whisper and self-hosted models (empty `apiEndpoint`).
  static func prewarm(for model: TranscriptionModel) {
    prewarm(endpoint: model.apiEndpoint)
  }

  /// Pre-warms the connection for the selected Dictate Prompt model's provider.
  static func prewarm(for model: PromptModel) {
    switch model.provider {
    case .gemini:
      prewarm(endpoint: "https://generativelanguage.googleapis.com/")
    case .openai:
      prewarm(endpoint: "https://api.openai.com/")
    case .grok:
      prewarm(endpoint: "https://api.x.ai/")
    case .anthropic:
      prewarm(endpoint: "https://api.anthropic.com/")
    case .local:
      warmLocalModel()
    default:
      break  // custom endpoints: unknown hosts, nothing worth warming
    }
  }

  /// Loads the local model into RAM while the user is still speaking.
  ///
  /// Over loopback there is no TCP/TLS handshake worth saving — the cold start that hurts is the
  /// *model load*. Ollama evicts a model after five idle minutes and LM Studio loads on demand, so
  /// the first Dictate Prompt of a session otherwise waits out several seconds of weight loading,
  /// and it waits for it *after* transcription, at the very end of the critical path. A one-token
  /// request issued at record start moves that load in parallel with speaking and Whisper.
  ///
  /// Fire-and-forget: the reply is discarded, and a failure here says nothing the real request
  /// won't say better a moment later (with a message pointing at the settings), so it is logged
  /// rather than surfaced.
  private static func warmLocalModel() {
    let endpoint = LocalLLMPreferences.chatCompletionsURL
    let model = LocalLLMPreferences.modelID
    guard let url = URL(string: endpoint) else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // Generous: loading a large model from a cold page cache can take tens of seconds, and giving
    // up early would abandon exactly the wait this is meant to absorb.
    request.timeoutInterval = 120
    let body: [String: Any] = [
      "model": model,
      "messages": [["role": "user", "content": "hi"]],
      "max_tokens": 1,
      "stream": false,
    ]
    guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
    request.httpBody = httpBody

    Task.detached(priority: .utility) {
      let startTime = CFAbsoluteTimeGetCurrent()
      do {
        _ = try await LLMHTTPSession.shared.data(for: request)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        DebugLogger.log("PREWARM: local model \(model) ready in \(String(format: "%.0f", elapsedMs))ms")
      } catch {
        DebugLogger.logWarning("PREWARM: local model \(model) warm-up failed: \(error.localizedDescription)")
      }
    }
  }

  private static func prewarm(endpoint: String) {
    guard let url = URL(string: endpoint), let host = url.host,
      let hostURL = URL(string: "https://\(host)/")
    else { return }

    var request = URLRequest(url: hostURL)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 10

    Task.detached(priority: .utility) {
      let startTime = CFAbsoluteTimeGetCurrent()
      // The response status is irrelevant (hosts typically answer 404 on "/") — reaching
      // the server at all leaves an established connection behind in the shared pool.
      _ = try? await LLMHTTPSession.shared.data(for: request)
      let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
      DebugLogger.log("PREWARM: \(host) connection ready in \(String(format: "%.0f", elapsedMs))ms")
    }
  }
}

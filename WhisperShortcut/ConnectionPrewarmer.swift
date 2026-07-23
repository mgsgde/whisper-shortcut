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
    default:
      break  // custom/local endpoints: unknown or loopback hosts, nothing worth warming
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

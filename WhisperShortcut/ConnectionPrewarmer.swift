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
      // The local path is transcribe-first: the spoken instruction goes through the selected
      // *transcription* model before the local LLM sees anything, so that request is step one of
      // the critical path, not a parallel extra like it is on the cloud paths. Warming only the
      // prompt model would leave the step the user actually waits on first cold. No-ops for
      // offline Whisper (empty endpoint — it is preloaded at launch and on selection instead).
      prewarm(for: TranscriptionModel.loadSelected())
      warmLocalModel()
    case .localMLX:
      prewarm(for: TranscriptionModel.loadSelected())
      warmMLXModel(for: model)
    default:
      break  // custom endpoints: unknown hosts, nothing worth warming
    }
  }

  /// Loads the local model into RAM *and* primes its prompt cache while the user is still speaking.
  ///
  /// Two costs sit in front of the first token of a local reply, and both can be paid during the
  /// recording instead of after it:
  ///
  /// 1. **The weights.** Over loopback there is no TCP/TLS handshake worth saving — the cold start
  ///    that hurts is the model load. Ollama evicts a model after five idle minutes and LM Studio
  ///    loads on demand, so the first Dictate Prompt of a session otherwise waits it out, at the
  ///    very end of the critical path.
  /// 2. **The prefill.** The Dictate Prompt system prompt is well over a thousand tokens, and every
  ///    request pays to process it before emitting anything. llama.cpp and Ollama cache the KV
  ///    state of a shared prefix between requests, so sending the *real* system prompt here — not a
  ///    throwaway "hi" — means the cache the actual request hits is already the right one, from the
  ///    first request of the session rather than the second.
  ///
  /// Conversation history and the user turn are deliberately left out: they change per request, so
  /// they would only extend the primed prefix past its useful common part.
  ///
  /// Fire-and-forget: the reply is discarded, and a failure here says nothing the real request
  /// won't say better a moment later (with a message pointing at the settings), so it is logged
  /// rather than surfaced.
  private static func warmLocalModel() {
    let endpoint = LocalLLMPreferences.chatCompletionsURL
    let model = LocalLLMPreferences.modelID
    guard let url = URL(string: endpoint) else { return }

    // `false` because this warms the *local* model, and a local text model always takes its
    // selection from the clipboard. Priming with the screenshot prompt would prime a prefix the
    // real request never sends.
    let systemPrompt = SpeechService.buildDictatePromptSystemPrompt(
      logPrefix: "PREWARM", usesScreenshotSelection: false)

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // Generous: loading a large model from a cold page cache can take tens of seconds, and giving
    // up early would abandon exactly the wait this is meant to absorb.
    request.timeoutInterval = 120
    // Built by the provider, not here: priming a prompt cache only works if the server renders the
    // same prefix for the warm-up as for the real request, and two hand-written bodies drift.
    let body = LocalLLMChatProvider.requestBody(
      model: model,
      messages: [
        ["role": "system", "content": systemPrompt],
        ["role": "user", "content": "hi"],
      ],
      stream: false,
      maxTokens: 1)
    guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
    request.httpBody = httpBody

    Task.detached(priority: .utility) {
      let startTime = CFAbsoluteTimeGetCurrent()
      do {
        _ = try await LLMHTTPSession.shared.data(for: request)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        DebugLogger.log(
          "PREWARM: local model \(model) ready in \(String(format: "%.0f", elapsedMs))ms (primed \(systemPrompt.count)-char system prompt)")
      } catch {
        DebugLogger.logWarning("PREWARM: local model \(model) warm-up failed: \(error.localizedDescription)")
      }
    }
  }

  /// Loads the selected MLX model into RAM while the user is still speaking.
  private static func warmMLXModel(for model: PromptModel) {
    guard let mlxType = model.localMLXModelType else { return }
    Task.detached(priority: .utility) {
      let startTime = CFAbsoluteTimeGetCurrent()
      do {
        try await LocalLLMModelManager.shared.ensureReady(mlxType)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        DebugLogger.log(
          "PREWARM: MLX model \(mlxType.huggingFaceID) ready in \(String(format: "%.0f", elapsedMs))ms")
      } catch is CancellationError {
        DebugLogger.log("PREWARM: MLX model \(mlxType.huggingFaceID) warm-up cancelled")
      } catch {
        DebugLogger.logWarning(
          "PREWARM: MLX model \(mlxType.huggingFaceID) warm-up failed: \(error.localizedDescription)")
      }
    }
  }

  private static func prewarm(endpoint: String) {
    guard let url = URL(string: endpoint), let host = url.host,
      let hostURL = URL(string: "https://\(host)/")
    else { return }
    // In Offline Mode the request would be refused by the guard anyway; not sending it means the
    // app makes no connection to a provider at all, which is the claim the mode has to be able
    // to make when someone watches the traffic.
    guard !OfflineMode.isEnabled || OfflineMode.allows(hostURL) else { return }

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

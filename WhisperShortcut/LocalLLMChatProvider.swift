import Foundation

/// Local implementation of `LLMChatProvider` for an OpenAI-compatible server running on the
/// user's machine (Ollama, LM Studio, or any `/v1/chat/completions`-compatible backend).
///
/// Mirrors `GrokChatProvider.sendViaChatCompletions` (xAI is OpenAI-compatible too), but:
///   - the endpoint is read from `LocalLLMPreferences` instead of being hardcoded,
///   - no API key / auth header is sent (local servers don't require one), and
///   - a refused connection is mapped to an actionable "is the server running?" message.
///
/// Phase 1 wires this provider for Dictate Prompt (text-only, no tools). Tool calling is parsed
/// here as well so the chat path can be enabled later without changes to the provider.
final class LocalLLMChatProvider: LLMChatProvider {
  static let shared = LocalLLMChatProvider()

  private var session: URLSession { LLMHTTPSession.shared }

  private init() {}

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    // None apply: local servers have no web search, no standard reasoning knob, no built-in
    // tools, and no server-side prompt-cache hint.
    options: ChatRequestOptions
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    let endpoint = LocalLLMPreferences.chatCompletionsURL

    // Build OpenAI-format messages from Gemini-format contents (shared translator).
    let messages = OpenAIChatCompletionsConverter.messages(
      from: contents, systemInstruction: systemInstruction)

    var body: [String: Any] = [
      "model": model,
      "messages": messages,
      "stream": true,
    ]
    if !tools.isEmpty {
      body["tools"] = tools.map(\.chatCompletionsDeclaration)
    }

    DebugLogger.logNetwork("LOCAL-CHAT-STREAM: POST \(endpoint) model=\(model) tools=\(tools.count)")
    // No auth header: local servers don't require one. A refused connection and a 404 both get
    // an actionable message instead of the opaque default.
    let config = OpenAICompatibleStream.Config(
      endpoint: endpoint,
      headers: [:],
      logTag: "LOCAL-CHAT-STREAM",
      mapHTTPError: { status, body in
        if status == 404 {
          return TranscriptionError.networkError(
            "Local server returned 404 for model \"\(model)\". Pull/select the model first (e.g. `ollama pull \(model)`) or fix the model id in Dictate Prompt settings.")
        }
        return TranscriptionError.networkError("Local LLM server error HTTP \(status): \(body.prefix(500))")
      },
      mapTransportError: { Self.mapConnectionError($0, endpoint: endpoint) })
    return OpenAICompatibleStream.chatCompletions(config, body: body)
  }

  func generateStructured(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    schema: [String: Any],
    schemaName: String,
    thinkingLevel: ThinkingLevel
  ) async throws -> [String: Any] {
    // Not used by the local Dictate Prompt path. Smart Improvement / structured features stay on
    // cloud models for now; implement via OpenAICompatibleStructured if local structured output is
    // needed later.
    throw TranscriptionError.networkError("Structured output is not supported for local models yet.")
  }

  /// Turns a connection-refused / host-unreachable URLError into an actionable message instead of
  /// the opaque default ("Could not connect to the server").
  private static func mapConnectionError(_ error: Error, endpoint: String) -> Error {
    if let urlError = error as? URLError,
       urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost
        || urlError.code == .networkConnectionLost || urlError.code == .timedOut {
      return TranscriptionError.networkError(
        "Can't reach the local LLM server at \(endpoint). Start it (e.g. run `ollama serve` / open LM Studio) or fix the endpoint in Dictate Prompt settings.")
    }
    return error
  }
}

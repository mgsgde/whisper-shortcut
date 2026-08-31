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
      // Dictate Prompt is a one-shot text rewrite — reasoning buys nothing and costs seconds of
      // first-token latency on hybrid models (qwen3, deepseek-r1, …). llama.cpp, LM Studio and
      // vLLM read this; servers that don't know the field ignore it (unknown JSON keys are
      // dropped), so the `<think>` stripper below stays the backstop rather than the only defense.
      "chat_template_kwargs": ["enable_thinking": false],
      // Bounds a model that repeats itself forever instead of finishing. Set high enough that real
      // rewrites never reach it; the caller warns when a reply stops here.
      "max_tokens": AppConstants.localPromptMaxOutputTokens,
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

  /// Removes `<think>…</think>` reasoning blocks that hybrid models emit inline in `content`.
  ///
  /// Cloud providers deliver reasoning in a separate field, so no other provider needs this. Local
  /// servers differ by version: some map thinking to `reasoning_content` (already ignored — the
  /// stream parser only reads `delta.content`), older ones leave the raw tags in the text, where
  /// they would be pasted into the user's document verbatim.
  ///
  /// An unterminated opener (stream cancelled mid-thought) drops everything after it: a truncated
  /// thought is never the answer.
  static func strippingReasoningBlocks(_ text: String) -> String {
    var result = ""
    var rest = Substring(text)
    let openers = ["<think>", "<thinking>"]

    while let opener = openers.compactMap({ tag in rest.range(of: tag).map { (tag, $0) } })
      .min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
      result += rest[rest.startIndex..<opener.1.lowerBound]
      let afterOpen = rest[opener.1.upperBound...]
      let closer = opener.0.replacingOccurrences(of: "<", with: "</")
      guard let closeRange = afterOpen.range(of: closer) else { return trimmed(result) }
      rest = afterOpen[closeRange.upperBound...]
    }
    result += rest
    return trimmed(result)
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
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

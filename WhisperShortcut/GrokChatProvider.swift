import Foundation

/// Grok/xAI implementation of `LLMChatProvider`.
/// Uses the Responses API (`/v1/responses`) with web+X search when grounding is
/// enabled, and falls back to Chat Completions (`/v1/chat/completions`) otherwise.
final class GrokChatProvider: LLMChatProvider {
  static let shared = GrokChatProvider()

  private var session: URLSession { LLMHTTPSession.shared }

  private init() {}

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    useGrounding: Bool,
    thinkingLevel: ThinkingLevel,
    disableBuiltInTools: Bool,  // Grok doesn't auto-enable built-in tools here; ignored.
    cacheKey: String?
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    if let attachmentError = Self.validateAttachments(in: contents) {
      return AsyncThrowingStream { $0.finish(throwing: attachmentError) }
    }
    if useGrounding {
      return sendViaResponsesAPI(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools, thinkingLevel: thinkingLevel, cacheKey: cacheKey)
    } else {
      return sendViaChatCompletions(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools, thinkingLevel: thinkingLevel, cacheKey: cacheKey)
    }
  }

  /// xAI's Grok API only accepts image attachments. Reject PDFs and other
  /// non-image MIME types up front with a clear message — otherwise xAI tries
  /// to base64-decode them as images and returns "Invalid base64-encoded image."
  private static func validateAttachments(in contents: [[String: Any]]) -> Error? {
    var unsupported: Set<String> = []
    for content in contents {
      guard let parts = content["parts"] as? [[String: Any]] else { continue }
      for part in parts {
        guard let inlineData = part["inline_data"] as? [String: Any],
              let mimeType = inlineData["mime_type"] as? String,
              !mimeType.hasPrefix("image/") else { continue }
        unsupported.insert(mimeType)
      }
    }
    guard !unsupported.isEmpty else { return nil }
    let types = unsupported.sorted().joined(separator: ", ")
    return TranscriptionError.fileError(
      "Grok only supports image attachments — \(types) isn't supported. Switch to a Gemini model to chat about PDFs and documents."
    )
  }

  // MARK: - Responses API (with web_search + X search)

  /// Uses xAI's Responses API which supports built-in web and X.com search.
  /// SSE events follow the OpenAI Responses API format.
  private func sendViaResponsesAPI(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    thinkingLevel: ThinkingLevel,
    cacheKey: String?
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    do {
      let endpoint = "https://api.x.ai/v1/responses"

      var body: [String: Any] = [
        "model": model,
        "input": OpenAIResponsesAPIConverter.input(from: contents),
        "stream": true,
        "temperature": 0.7,
        "top_p": 0.95,
        "max_output_tokens": 8192,
      ]
      if let instructions = GeminiSystemInstruction.text(from: systemInstruction) {
        body["instructions"] = instructions
      }

      // Tools: web_search + x_search + custom function tools.
      // web_search searches the open web; x_search searches X.com posts.
      // x_search was dropped once for latency, then brought back on purpose: its
      // bias toward opinion over fact is exactly the point — reading what people
      // on X say about a topic is the main reason to pick Grok over Gemini/GPT.
      // xAI runs both server-side and picks per question, so the extra tool only
      // costs a round trip when the model actually decides X is worth searching.
      body["tools"] =
        [["type": "web_search"] as [String: Any], ["type": "x_search"] as [String: Any]]
        + tools.map(\.responsesDeclaration)

      // Per-session `/think` override → Responses API nested `reasoning.effort`.
      if let effort = thinkingLevel.grokReasoningEffort {
        body["reasoning"] = ["effort": effort]
      }

      DebugLogger.logNetwork("GROK-RESPONSES: POST \(endpoint) model=\(model) tools=web_search+x_search+\(tools.count)func effort=\(thinkingLevel.grokReasoningEffort ?? "default")")
      return OpenAICompatibleStream.responses(
        try Self.streamConfig(endpoint: endpoint, logTag: "GROK-RESPONSES", cacheKey: cacheKey),
        body: body,
        collectCitations: true)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
  }

  // MARK: - Chat Completions API (without search)

  /// Uses the standard OpenAI-compatible Chat Completions endpoint.
  private func sendViaChatCompletions(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    thinkingLevel: ThinkingLevel,
    cacheKey: String?
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    do {
      let endpoint = "https://api.x.ai/v1/chat/completions"

      // xAI's API is OpenAI-Chat-Completions-compatible, so this is the same translator
      // OpenAIChatProvider uses.
      let messages = OpenAIChatCompletionsConverter.messages(
        from: contents, systemInstruction: systemInstruction)

      var body: [String: Any] = [
        "model": model,
        "messages": messages,
        "stream": true,
        "temperature": 0.7,
        "top_p": 0.95,
        "max_tokens": 8192,
      ]

      if !tools.isEmpty {
        body["tools"] = tools.map(\.chatCompletionsDeclaration)
      }

      // Per-session `/think` override → Chat Completions top-level `reasoning_effort`.
      if let effort = thinkingLevel.grokReasoningEffort {
        body["reasoning_effort"] = effort
      }

      DebugLogger.logNetwork("GROK-CHAT-STREAM: POST \(endpoint) model=\(model) effort=\(thinkingLevel.grokReasoningEffort ?? "default")")
      return OpenAICompatibleStream.chatCompletions(
        try Self.streamConfig(endpoint: endpoint, logTag: "GROK-CHAT-STREAM", cacheKey: cacheKey),
        body: body)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
  }

  // MARK: - Shared request configuration

  /// Auth, cache hint, and xAI's error mapping — identical for both endpoints.
  private static func streamConfig(
    endpoint: String, logTag: String, cacheKey: String?
  ) throws -> OpenAICompatibleStream.Config {
    let apiKey = try ProviderCredentials.require(.xAI)
    var headers = ["Authorization": "Bearer \(apiKey)"]
    // Per-conversation hint xAI uses to maximize prompt-cache hit rate (docs:
    // "Use x-grok-conv-id to maximize cache hit rates"). Caching itself is automatic.
    if let cacheKey = cacheKey {
      headers["x-grok-conv-id"] = cacheKey
    }
    return OpenAICompatibleStream.Config(
      endpoint: endpoint,
      headers: headers,
      logTag: logTag,
      mapHTTPError: { status, body in
        if status == 401 {
          return TranscriptionError.networkError(ProviderCredentials.invalidKeyMessage(.xAI))
        }
        if status == 429 {
          return classifyXAI429(body: body)
        }
        return TranscriptionError.networkError("xAI API error HTTP \(status): \(body.prefix(500))")
      })
  }

  // MARK: - Structured Output

  func generateStructured(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    schema: [String: Any],
    schemaName: String,
    thinkingLevel: ThinkingLevel
  ) async throws -> [String: Any] {
    let apiKey = try ProviderCredentials.require(.xAI)
    return try await OpenAICompatibleStructured.generate(
      endpoint: "https://api.x.ai/v1/chat/completions",
      apiKey: apiKey,
      model: model,
      contents: contents,
      systemInstruction: systemInstruction,
      schema: schema,
      schemaName: schemaName,
      reasoningEffort: thinkingLevel.grokReasoningEffort,
      session: session,
      logTag: "GROK")
  }

  /// Maps an xAI HTTP 429 body to a specific error. xAI returns 429 both for transient
  /// rate limits and for permanent "credits exhausted / monthly spending limit" — the
  /// second is not solved by waiting, so it gets its own actionable message instead of
  /// the generic `.rateLimited` (which would tell the user to "wait and try again").
  private static func classifyXAI429(body: String) -> TranscriptionError {
    let lower = body.lowercased()
    // Substring matches mirror xAI error wording observed in 2026-05; xAI may change
    // these phrases without notice, in which case we silently fall back to the generic
    // rate-limit message (the worst case is the current behaviour, not a new bug).
    let exhausted = lower.contains("some resource has been exhausted")
      || lower.contains("monthly spending limit")
      || lower.contains("available credits")
    if exhausted {
      return TranscriptionError.networkError(
        "xAI account is out of credits or has reached its monthly spending limit. Top up or raise the limit at https://console.x.ai/ to continue.")
    }
    return TranscriptionError.rateLimited(retryAfter: nil)
  }
}

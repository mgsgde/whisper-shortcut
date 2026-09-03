import Foundation

/// OpenAI implementation of `LLMChatProvider`.
/// - When grounding is enabled, uses the Responses API (`/v1/responses`) with the hosted
///   `web_search` tool. This mirrors the Grok provider's two-endpoint strategy.
/// - Otherwise uses Chat Completions (`/v1/chat/completions`) with streaming SSE.
/// References:
///   - https://platform.openai.com/docs/api-reference/responses
///   - https://platform.openai.com/docs/api-reference/chat
final class OpenAIChatProvider: LLMChatProvider {
  static let shared = OpenAIChatProvider()

  private var session: URLSession { LLMHTTPSession.shared }

  private init() {}

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    options: ChatRequestOptions  // `disableBuiltInTools` / `xHandles` don't apply here; ignored.
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    let useCustom = OpenAIChatPreferences.isCustomEndpointModel(model)
    if let attachmentError = ChatAttachmentGuard.rejectUnsupported(
      in: contents,
      provider: useCustom ? "This endpoint" : "OpenAI",
      allowedPrefixes: ["image/", "audio/"]
    ) {
      return AsyncThrowingStream { $0.finish(throwing: attachmentError) }
    }
    if options.useGrounding && !useCustom {
      return sendViaResponsesAPI(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools, thinkingLevel: options.thinkingLevel, cacheKey: options.cacheKey)
    }
    return sendViaChatCompletions(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools, thinkingLevel: options.thinkingLevel, cacheKey: options.cacheKey)
  }

  // MARK: - Request credentials

  private static func requireAPIKey(useCustomEndpoint: Bool) throws -> String {
    if useCustomEndpoint {
      guard OpenAIChatPreferences.customEndpointBaseURL != nil else {
        throw TranscriptionError.networkError(
          "Custom endpoint URL is missing. Set it in Settings → Chat, then select Custom endpoint as the chat model.")
      }
      guard let apiKey = OpenAIChatPreferences.resolvedAPIKey else {
        throw TranscriptionError.networkError(
          "No API key for the custom endpoint. Add a proxy key in Settings → Chat or an OpenAI key in Settings → General.")
      }
      return apiKey
    }
    return try ProviderCredentials.require(.openAI)
  }

  private static func invalidKeyMessage(useCustomEndpoint: Bool) -> String {
    if useCustomEndpoint {
      return "API key is invalid for the custom endpoint. Check Settings → Chat or General."
    }
    return ProviderCredentials.invalidKeyMessage(.openAI)
  }

  private static func chatCompletionsURL(useCustomEndpoint: Bool) -> String {
    if useCustomEndpoint {
      return OpenAIChatPreferences.chatCompletionsURL
    }
    return "https://api.openai.com/v1/chat/completions"
  }

  /// api.openai.com is always bearer. A custom endpoint may not be: an Azure tenant authenticates
  /// its API key with `api-key` and rejects a bearer header. See `CustomEndpointAuth`.
  private static func authHeaders(apiKey: String, useCustomEndpoint: Bool) -> [String: String] {
    if useCustomEndpoint {
      return OpenAIChatPreferences.authHeaders(apiKey: apiKey)
    }
    return ["Authorization": "Bearer \(apiKey)"]
  }

  // MARK: - Responses API (with web_search)

  /// Uses OpenAI's Responses API which supports the hosted `web_search` tool. SSE event format
  /// matches xAI's (xAI's Responses API mirrors OpenAI's), so the parser here is structurally
  /// identical to `GrokChatProvider.sendViaResponsesAPI`.
  private func sendViaResponsesAPI(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    thinkingLevel: ThinkingLevel,
    cacheKey: String?
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    do {
      let endpoint = "https://api.openai.com/v1/responses"

      var body: [String: Any] = [
        "model": model,
        "input": OpenAIResponsesAPIConverter.input(from: contents),
        "stream": true,
        // Cost fuse — see AppConstants.llmMaxOutputTokens. Reasoning tokens count against this,
        // which is the point: they bill at the output rate and are invisible in the reply.
        "max_output_tokens": AppConstants.llmMaxOutputTokens,
      ]
      if let instructions = GeminiSystemInstruction.text(from: systemInstruction) {
        body["instructions"] = instructions
      }
      // Stable per-conversation routing hint → higher prompt-cache hit rate. Caching is
      // automatic regardless; this just keeps same-prefix turns landing on the same backend.
      if let cacheKey = cacheKey {
        body["prompt_cache_key"] = cacheKey
      }

      body["tools"] = [["type": "web_search"] as [String: Any]] + tools.map(\.responsesDeclaration)

      // Per-session `/think` override → Responses API nested `reasoning.effort`.
      if let effort = thinkingLevel.openAIReasoningEffort {
        body["reasoning"] = ["effort": effort]
      }

      DebugLogger.logNetwork("OPENAI-RESPONSES: POST \(endpoint) model=\(model) tools=web_search+\(tools.count)func effort=\(thinkingLevel.openAIReasoningEffort ?? "default")")
      return OpenAICompatibleStream.responses(
        try Self.streamConfig(endpoint: endpoint, logTag: "OPENAI-RESPONSES", useCustomEndpoint: false),
        body: body,
        // Grounded OpenAI replies do not carry inline [N] markers today, so no citation footer is
        // rendered for them. Left off deliberately: enabling it is a UI change, not a refactor.
        collectCitations: false)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
  }

  // MARK: - Chat Completions

  private func sendViaChatCompletions(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    thinkingLevel: ThinkingLevel,
    cacheKey: String?
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    do {
      let useCustom = OpenAIChatPreferences.isCustomEndpointModel(model)
      let requestModel = OpenAIChatPreferences.resolvedRequestModelID(for: model)
      let endpoint = Self.chatCompletionsURL(useCustomEndpoint: useCustom)

      // gpt-4o-audio-preview is audio-only and rejects image_url parts (HTTP 400),
      // so we drop images for that model.
      let stripImages = (model == PromptModel.openaiGPT4oAudio.rawValue)
      let messages = OpenAIChatCompletionsConverter.messages(
        from: contents, systemInstruction: systemInstruction, stripImages: stripImages)

      // Cost fuse — see AppConstants.llmMaxOutputTokens. The key differs by endpoint and both
      // choices are load-bearing: OpenAI *rejects* `max_tokens` on its reasoning models ("Use
      // 'max_completion_tokens' instead", HTTP 400), while OpenRouter, self-hosted llama.cpp and
      // the other OpenAI-compatible servers behind `useCustom` only reliably understand the
      // original `max_tokens`. Sending the wrong one is a hard 400, so it is picked per endpoint
      // rather than sent as a pair. Azure is the exception inside `useCustom`: it *is* OpenAI, so
      // its reasoning deployments reject `max_tokens` exactly the way api.openai.com does.
      let maxTokensKey =
        useCustom
        ? CustomEndpointAuth.maxTokensKey(forBaseURL: OpenAIChatPreferences.customEndpointBaseURL ?? "")
        : "max_completion_tokens"
      var body: [String: Any] = [
        "model": requestModel,
        "messages": messages,
        "stream": true,
        maxTokensKey: AppConstants.llmMaxOutputTokens,
      ]

      // Stable per-conversation routing hint → higher prompt-cache hit rate. Caching is
      // automatic regardless; this just keeps same-prefix turns landing on the same backend.
      if let cacheKey = cacheKey {
        body["prompt_cache_key"] = cacheKey
      }

      // gpt-4o-audio-preview requires both text and audio modalities to be declared
      // when audio content is present in the input. We always declare ["text"] for chat
      // output and let the request itself contain audio parts when applicable; the
      // audio-preview model handles this fine.
      if model == PromptModel.openaiGPT4oAudio.rawValue {
        body["modalities"] = ["text"]
      }

      if !tools.isEmpty {
        body["tools"] = tools.map(\.chatCompletionsDeclaration)
      }

      // Per-session `/think` override → Chat Completions top-level `reasoning_effort`.
      if let effort = thinkingLevel.openAIReasoningEffort {
        body["reasoning_effort"] = effort
      }

      DebugLogger.logNetwork("OPENAI-CHAT-STREAM: POST \(endpoint) model=\(requestModel) messages=\(messages.count) tools=\(tools.count) effort=\(thinkingLevel.openAIReasoningEffort ?? "default")")
      return OpenAICompatibleStream.chatCompletions(
        try Self.streamConfig(endpoint: endpoint, logTag: "OPENAI-CHAT-STREAM", useCustomEndpoint: useCustom),
        body: body)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
  }

  // MARK: - Shared request configuration

  /// Auth and OpenAI's error mapping — identical for both endpoints. `useCustomEndpoint` only
  /// changes which key is resolved and how an auth failure is worded.
  private static func streamConfig(
    endpoint: String, logTag: String, useCustomEndpoint: Bool
  ) throws -> OpenAICompatibleStream.Config {
    let apiKey = try requireAPIKey(useCustomEndpoint: useCustomEndpoint)
    return OpenAICompatibleStream.Config(
      endpoint: endpoint,
      headers: Self.authHeaders(apiKey: apiKey, useCustomEndpoint: useCustomEndpoint),
      logTag: logTag,
      mapHTTPError: { status, body in
        ChatProviderHTTPError.map(
          provider: useCustomEndpoint ? "Custom endpoint" : "OpenAI",
          status: status,
          body: body,
          invalidKey: TranscriptionError.networkError(invalidKeyMessage(useCustomEndpoint: useCustomEndpoint)))
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
    let useCustom = OpenAIChatPreferences.isCustomEndpointModel(model)
    let apiKey = try Self.requireAPIKey(useCustomEndpoint: useCustom)
    let requestModel = OpenAIChatPreferences.resolvedRequestModelID(for: model)
    return try await OpenAICompatibleStructured.generate(
      endpoint: Self.chatCompletionsURL(useCustomEndpoint: useCustom),
      authHeaders: Self.authHeaders(apiKey: apiKey, useCustomEndpoint: useCustom),
      model: requestModel,
      contents: contents,
      systemInstruction: systemInstruction,
      schema: schema,
      schemaName: schemaName,
      reasoningEffort: thinkingLevel.openAIReasoningEffort,
      session: session,
      logTag: "OPENAI")
  }

  // MARK: - Audio Format Helpers

  /// Maps an audio file extension to OpenAI's `input_audio.format` value. Shared between
  /// the chat path (this provider) and the Dictate Prompt path (`SpeechService`).
  static func openAIAudioFormat(forExtension ext: String) -> String {
    switch ext.lowercased() {
    case "mp3", "mpga": return "mp3"
    case "wav": return "wav"
    default: return "wav"
    }
  }

  /// Maps an audio MIME type to OpenAI's `input_audio.format` value. Used when converting
  /// Gemini-style `inline_data` parts (which carry a MIME type, not an extension) into
  /// OpenAI Chat Completions content parts.
  static func openAIAudioFormat(forMimeType mime: String) -> String {
    let lower = mime.lowercased()
    if lower.contains("wav") { return "wav" }
    if lower.contains("mp3") || lower.contains("mpeg") { return "mp3" }
    return "wav"
  }

}

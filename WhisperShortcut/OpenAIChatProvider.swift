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

  /// Which backend a model string talks to. Computed from the model string so the sentinel
  /// models route to their own endpoint, key and error wording.
  private enum Route {
    case openAI, customEndpoint, openRouter

    init(model: String) {
      if OpenRouterChatPreferences.isOpenRouterModel(model) {
        self = .openRouter
      } else if OpenAIChatPreferences.isCustomEndpointModel(model) {
        self = .customEndpoint
      } else {
        self = .openAI
      }
    }

    var providerLabel: String {
      switch self {
      case .openAI: return "OpenAI"
      case .customEndpoint: return String(localized: "Own server")
      case .openRouter: return "OpenRouter"
      }
    }

    /// Anything that is not api.openai.com: no Responses API, no implicit reasoning effort.
    var isThirdParty: Bool { self != .openAI }
  }

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    options: ChatRequestOptions  // `disableBuiltInTools` / `xHandles` don't apply here; ignored.
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    let route = Route(model: model)
    if let attachmentError = ChatAttachmentGuard.rejectUnsupported(
      in: contents,
      provider: route == .customEndpoint ? String(localized: "This endpoint") : route.providerLabel,
      allowedPrefixes: ["image/", "audio/"]
    ) {
      return AsyncThrowingStream { $0.finish(throwing: attachmentError) }
    }
    if options.useGrounding && route == .openAI {
      return sendViaResponsesAPI(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools, thinkingLevel: options.thinkingLevel, cacheKey: options.cacheKey)
    }
    return sendViaChatCompletions(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools, thinkingLevel: options.thinkingLevel, cacheKey: options.cacheKey)
  }

  // MARK: - Reasoning effort

  /// `/think` level → OpenAI effort. `.default` sends `low` to OpenAI's own reasoning models
  /// (gpt-5*, gpt-6*) instead of leaving it to OpenAI, matching Grok: the model default spends
  /// tens of seconds reasoning before the first word on everyday questions. Custom endpoints and
  /// non-reasoning models (gpt-4o-audio) keep omitting the field, because they reject it with 400.
  private static func reasoningEffort(_ level: ThinkingLevel, model: String, route: Route) -> String? {
    reasoningEffort(level, model: model, useCustomEndpoint: route.isThirdParty)
  }

  static func reasoningEffort(_ level: ThinkingLevel, model: String, useCustomEndpoint: Bool) -> String? {
    if let explicit = level.openAIReasoningEffort { return explicit }
    guard !useCustomEndpoint, model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6") else { return nil }
    return "low"
  }

  // MARK: - Request credentials

  private static func requireAPIKey(route: Route) throws -> String {
    switch route {
    case .customEndpoint:
      guard OpenAIChatPreferences.customEndpointBaseURL != nil else {
        throw TranscriptionError.networkError(
          String(localized: "Your own server's base URL is missing. Set it in Settings → Chat, then pick Own server as the chat model."))
      }
      guard let apiKey = OpenAIChatPreferences.resolvedAPIKey else {
        throw TranscriptionError.networkError(
          String(localized: "No API key for your custom endpoint. Enter the server's key in Settings → Chat, or add an OpenAI key in Settings → Accounts if the server forwards to OpenAI."))
      }
      return apiKey
    case .openRouter:
      guard let apiKey = OpenRouterChatPreferences.apiKey else {
        throw TranscriptionError.networkError(
          String(localized: "Connect your OpenRouter account in Settings → Accounts to use OpenRouter in Chat."))
      }
      return apiKey
    case .openAI:
      return try ProviderCredentials.require(.openAI)
    }
  }

  private static func invalidKeyMessage(route: Route) -> String {
    switch route {
    case .customEndpoint:
      return String(localized: "API key is invalid for the custom endpoint. Check Settings → Chat or Accounts.")
    case .openRouter:
      return String(localized: "OpenRouter rejected the key. Reconnect your account in Settings → Accounts.")
    case .openAI:
      return ProviderCredentials.invalidKeyMessage(.openAI)
    }
  }

  private static func chatCompletionsURL(route: Route) -> String {
    switch route {
    case .customEndpoint: return OpenAIChatPreferences.chatCompletionsURL
    case .openRouter: return OpenRouterChatPreferences.chatCompletionsURL
    case .openAI: return "https://api.openai.com/v1/chat/completions"
    }
  }

  /// api.openai.com is always bearer. A custom endpoint may not be: an Azure tenant authenticates
  /// its API key with `api-key` and rejects a bearer header. See `CustomEndpointAuth`. OpenRouter
  /// is bearer plus the optional attribution headers `SpeechService.transcribeWithOpenRouter` sends.
  private static func authHeaders(apiKey: String, route: Route) -> [String: String] {
    switch route {
    case .customEndpoint:
      // Shared extra headers (the ones Dictate already stored) ride along. The auth header
      // wins when a name clashes, including a difference only in case.
      let auth = OpenAIChatPreferences.authHeaders(apiKey: apiKey)
      let authNames = Set(auth.keys.map { $0.lowercased() })
      var merged: [String: String] = [:]
      for (name, value) in CustomEndpointPreferences.extraHeaders where !authNames.contains(name.lowercased()) {
        merged[name] = value
      }
      for (name, value) in auth { merged[name] = value }
      return merged
    case .openRouter:
      return [
        "Authorization": "Bearer \(apiKey)",
        "HTTP-Referer": "https://github.com/mgsgde/whisper-shortcut",
        "X-Title": "WhisperShortcut",
      ]
    case .openAI:
      return ["Authorization": "Bearer \(apiKey)"]
    }
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
      let effort = Self.reasoningEffort(thinkingLevel, model: model, route: .openAI)
      if let effort {
        body["reasoning"] = ["effort": effort]
      }

      DebugLogger.logNetwork("OPENAI-RESPONSES: POST \(endpoint) model=\(model) tools=web_search+\(tools.count)func effort=\(effort ?? "default")")
      return OpenAICompatibleStream.responses(
        try Self.streamConfig(endpoint: endpoint, logTag: "OPENAI-RESPONSES", route: .openAI),
        body: body,
        // The url_citation annotations fill the collapsed "Sources" list; the per-paragraph chips
        // come from the `([domain](url))` links GPT writes inline (`InlineCitationExtractor`).
        collectCitations: true)
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
      let route = Route(model: model)
      let requestModel = route == .openRouter
        ? OpenRouterChatPreferences.modelID
        : OpenAIChatPreferences.resolvedRequestModelID(for: model)
      let endpoint = Self.chatCompletionsURL(route: route)

      // gpt-4o-audio-preview is audio-only and rejects image_url parts (HTTP 400),
      // so we drop images for that model.
      let stripImages = (model == PromptModel.openaiGPT4oAudio.rawValue)
      let messages = OpenAIChatCompletionsConverter.messages(
        from: contents, systemInstruction: systemInstruction, stripImages: stripImages)

      let maxTokensKey = Self.maxTokensKey(route: route)
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
      let effort = Self.reasoningEffort(thinkingLevel, model: requestModel, route: route)
      if let effort {
        body["reasoning_effort"] = effort
      }

      DebugLogger.logNetwork("OPENAI-CHAT-STREAM: POST \(endpoint) model=\(requestModel) messages=\(messages.count) tools=\(tools.count) effort=\(effort ?? "default")")
      return OpenAICompatibleStream.chatCompletions(
        try Self.streamConfig(endpoint: endpoint, logTag: "OPENAI-CHAT-STREAM", route: route),
        body: body)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
  }

  // MARK: - Shared request configuration

  /// Cost fuse — see AppConstants.llmMaxOutputTokens. The key differs by endpoint and both
  /// choices are load-bearing: OpenAI *rejects* `max_tokens` on its reasoning models ("Use
  /// 'max_completion_tokens' instead", HTTP 400), while OpenRouter, self-hosted llama.cpp and
  /// the other OpenAI-compatible servers behind `.customEndpoint` only reliably understand the
  /// original `max_tokens`. Sending the wrong one is a hard 400, so it is picked per endpoint
  /// rather than sent as a pair. Azure is the exception inside `.customEndpoint`: it *is* OpenAI, so
  /// its reasoning deployments reject `max_tokens` exactly the way api.openai.com does.
  private static func maxTokensKey(route: Route) -> String {
    switch route {
    case .customEndpoint:
      return CustomEndpointAuth.maxTokensKey(forBaseURL: OpenAIChatPreferences.customEndpointBaseURL ?? "")
    case .openRouter:
      return "max_tokens"
    case .openAI:
      return "max_completion_tokens"
    }
  }

  /// Auth and OpenAI's error mapping — identical for every route. `route` only changes which key
  /// is resolved and how an auth failure is worded.
  private static func streamConfig(
    endpoint: String, logTag: String, route: Route
  ) throws -> OpenAICompatibleStream.Config {
    let apiKey = try requireAPIKey(route: route)
    return OpenAICompatibleStream.Config(
      endpoint: endpoint,
      headers: Self.authHeaders(apiKey: apiKey, route: route),
      logTag: logTag,
      mapHTTPError: { status, body in
        ChatProviderHTTPError.map(
          provider: route.providerLabel,
          status: status,
          body: body,
          invalidKey: TranscriptionError.networkError(invalidKeyMessage(route: route)))
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
    let route = Route(model: model)
    let apiKey = try Self.requireAPIKey(route: route)
    let requestModel = route == .openRouter
      ? OpenRouterChatPreferences.modelID
      : OpenAIChatPreferences.resolvedRequestModelID(for: model)
    return try await OpenAICompatibleStructured.generate(
      endpoint: Self.chatCompletionsURL(route: route),
      authHeaders: Self.authHeaders(apiKey: apiKey, route: route),
      model: requestModel,
      contents: contents,
      systemInstruction: systemInstruction,
      schema: schema,
      schemaName: schemaName,
      reasoningEffort: Self.reasoningEffort(thinkingLevel, model: requestModel, route: route),
      maxTokensKey: Self.maxTokensKey(route: route),
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

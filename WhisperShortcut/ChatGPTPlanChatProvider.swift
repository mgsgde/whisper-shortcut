import Foundation

/// Chat on the user's ChatGPT plan: the Responses API (`POST /v1/responses`) with the OAuth access
/// token as bearer, per OpenAI's "Sign in with ChatGPT" preview contract.
///
/// The request differs from `OpenAIChatProvider`'s API-key route on purpose:
///   - `store: false`, `stream: true`, the full history in `input`, the system prompt in
///     `instructions` (an explicit `role: system` item is rejected);
///   - none of the fields the preview refuses (`max_output_tokens`, `temperature`, `metadata`,
///     `user`, `truncation`, `prompt_cache_key`, `previous_response_id`, …) is ever sent;
///   - no audio, and no tools: the docs only say function tools must be grouped in namespaces or
///     sent as `additional_tools` input items, without a concrete wire format, so this version
///     sends neither function tools nor `web_search` rather than guess a shape the server rejects.
///
/// Success is only a stream that ends with `response.completed`; `response.failed` (usage-limit
/// errors arrive this way), `response.incomplete` and a stream that just stops are errors.
final class ChatGPTPlanChatProvider: LLMChatProvider {
  static let shared = ChatGPTPlanChatProvider()

  private init() {}

  /// Fields the preview rejects. Kept as data so tests can assert none of them is ever sent.
  static let forbiddenRequestFields: [String] = [
    "background", "conversation", "max_output_tokens", "max_tool_calls", "metadata", "moderation",
    "multi_agent", "prompt", "prompt_cache_key", "prompt_cache_retention", "previous_response_id",
    "safety_identifier", "temperature", "top_logprobs", "top_p", "truncation", "user",
  ]

  // MARK: - Request

  /// The JSON body for one request. `structured` adds `text.format = json_schema` (strict).
  static func requestBody(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    thinkingLevel: ThinkingLevel,
    structured: (name: String, schema: [String: Any])? = nil
  ) -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "input": OpenAIResponsesAPIConverter.input(from: contents),
      "store": false,
      "stream": true,
    ]
    if let instructions = GeminiSystemInstruction.text(from: systemInstruction) {
      body["instructions"] = instructions
    }
    // Same policy as OpenAI's own reasoning models: `/think` wins, otherwise `low` for gpt-5/gpt-6
    // slugs instead of the slow model default.
    if let effort = OpenAIChatProvider.reasoningEffort(thinkingLevel, model: model, useCustomEndpoint: false) {
      body["reasoning"] = ["effort": effort]
    }
    if let structured {
      body["text"] = [
        "format": [
          "type": "json_schema",
          "name": structured.name,
          "strict": true,
          "schema": StructuredOutputSchema.strictified(structured.schema),
        ] as [String: Any]
      ]
    }
    return body
  }

  // MARK: - Streaming

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],  // Not sent in this version — see the type comment.
    options: ChatRequestOptions  // Grounding is not available on this route; only thinking level is read.
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    // Audio is not supported by this flow; the converter would drop non-image attachments silently,
    // so reject them with the same wording as the other providers.
    if let attachmentError = ChatAttachmentGuard.rejectUnsupported(
      in: contents, provider: "ChatGPT plan", allowedPrefixes: ["image/"])
    {
      return AsyncThrowingStream { $0.finish(throwing: attachmentError) }
    }
    let body = Self.requestBody(
      model: Self.requestModel(for: model), contents: contents,
      systemInstruction: systemInstruction, thinkingLevel: options.thinkingLevel)
    return Self.stream(body: body)
  }

  /// The sentinel `chatgpt-plan-chat` stands for whichever slug the user picked.
  private static func requestModel(for model: String) -> String {
    ChatGPTPlanPreferences.isChatGPTPlanModel(model) ? ChatGPTPlanPreferences.modelID : model
  }

  private static func stream(body: [String: Any]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          // A 401 is not by itself a reason to sign the user out (OpenAI: check account/scopes).
          // Refresh once, ignoring expiry, and retry the request; if that fails too, surface the
          // error and keep the refresh token. Only a terminal refresh error clears the tokens
          // (inside the OAuth service).
          var forceRefresh = false
          while true {
            let token = try await ChatGPTPlanOAuthService.shared.validAccessToken(forceRefresh: forceRefresh)
            let config = OpenAICompatibleStream.Config(
              endpoint: ChatGPTPlanOAuthConfig.responsesEndpoint,
              headers: ["Authorization": "Bearer \(token)"],
              logTag: "CHATGPT-PLAN-RESPONSES",
              mapHTTPError: { status, text in ChatGPTPlanError.fromHTTP(status: status, body: text) },
              terminalFailure: { type, payload in
                ChatGPTPlanError.fromStreamFailure(type: type, payload: payload)
              })
            DebugLogger.logNetwork("CHATGPT-PLAN-RESPONSES: POST responses model=\(body["model"] as? String ?? "?")")
            var yielded = false
            do {
              for try await event in OpenAICompatibleStream.responses(config, body: body, collectCitations: false) {
                yielded = true
                continuation.yield(event)
              }
              break
            } catch let error as ChatGPTPlanError where error == .signInRequired && !forceRefresh && !yielded {
              DebugLogger.log("CHATGPT-PLAN: Request rejected (401); refreshing the token once and retrying")
              forceRefresh = true
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  // MARK: - Structured output

  /// Streams the Responses call and accumulates the text, constrained by `text.format = json_schema`.
  /// The route is stream-only (`stream: true` is mandatory), so there is no non-streaming variant.
  func generateStructured(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    schema: [String: Any],
    schemaName: String,
    thinkingLevel: ThinkingLevel
  ) async throws -> [String: Any] {
    if let attachmentError = ChatAttachmentGuard.rejectUnsupported(
      in: contents, provider: "ChatGPT plan", allowedPrefixes: ["image/"])
    {
      throw attachmentError
    }
    let body = Self.requestBody(
      model: Self.requestModel(for: model), contents: contents, systemInstruction: systemInstruction,
      thinkingLevel: thinkingLevel, structured: (schemaName, schema))
    var text = ""
    for try await event in Self.stream(body: body) {
      if case .textDelta(let delta) = event { text += delta }
    }
    guard let data = text.data(using: .utf8),
      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw TranscriptionError.networkError(String(localized: "ChatGPT plan structured response was not valid JSON"))
    }
    return parsed
  }
}

// MARK: - App Store build

/// Stands in for `ChatGPTPlanChatProvider` in the App Store build, which must not offer the plan
/// route at all (OpenAI requires approval for paid apps). Nothing selects it there; this exists so
/// the provider factory stays total.
struct ChatGPTPlanUnavailableProvider: LLMChatProvider {
  private var error: Error {
    TranscriptionError.networkError(String(localized: "Using your ChatGPT plan isn't available in this version of WhisperShortcut."))
  }

  func sendChatStream(
    model: String, contents: [[String: Any]], systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration], options: ChatRequestOptions
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    let error = self.error
    return AsyncThrowingStream { $0.finish(throwing: error) }
  }

  func generateStructured(
    model: String, contents: [[String: Any]], systemInstruction: [String: Any]?,
    schema: [String: Any], schemaName: String, thinkingLevel: ThinkingLevel
  ) async throws -> [String: Any] {
    throw error
  }
}

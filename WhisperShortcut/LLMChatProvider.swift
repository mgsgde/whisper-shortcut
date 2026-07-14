import Foundation

// MARK: - Shared URLSession

/// Single URLSession reused by every LLM provider and the OpenAI-compatible transcription
/// paths. URLSession is thread-safe and pools connections per host, so one instance is
/// strictly better than each call site spinning up its own with identical config.
enum LLMHTTPSession {
  static let shared: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 300
    return URLSession(configuration: config)
  }()
}

// MARK: - Chat Stream Event (provider-agnostic)

/// Events emitted while streaming a chat reply from any LLM provider.
enum ChatStreamEvent {
  /// Incremental text appended to the model's reply.
  case textDelta(String)
  /// Model requested a local tool call. The caller should execute the tool,
  /// append the response, and re-invoke the stream.
  /// `thoughtSignature` is Gemini-specific (required by Gemini 3); nil for other providers.
  case functionCall(name: String, args: [String: Any], thoughtSignature: String?)
  /// Final event with optional grounding metadata and finish reason.
  /// Grounding sources/supports are Gemini-specific; empty for other providers.
  case finished(sources: [GroundingSource], supports: [GroundingSupport], finishReason: String?)
}

// MARK: - Thinking Level (provider-agnostic)

/// User-facing reasoning/thinking intensity, settable per chat session via the `/think` command
/// and persisted on `ChatSession`. Each provider maps it to its native knob:
///   - Gemini 3.x → `generationConfig.thinkingConfig.thinkingLevel`
///   - Gemini 2.5 → `generationConfig.thinkingConfig.thinkingBudget` (coarse: minimal→0, else dynamic)
///   - OpenAI / Grok → `reasoning_effort` (Chat Completions) or `reasoning.effort` (Responses API)
///
/// `.default` means "don't override — use the model's built-in per-model config". All field names
/// and accepted values below were verified live against each provider's API (see
/// reference_provider_endpoints_verified memory).
enum ThinkingLevel: String, Codable, CaseIterable {
  case `default`
  case minimal
  case low
  case medium
  case high

  /// OpenAI `reasoning_effort` / Responses `reasoning.effort`, or nil to omit (model default).
  /// gpt-5.5 rejects `minimal` (allowed: none/low/medium/high), so map minimal → `none` (the floor).
  var openAIReasoningEffort: String? {
    switch self {
    case .default: return nil
    case .minimal: return "none"
    case .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    }
  }

  /// Grok `reasoning_effort` / Responses `reasoning.effort`, or nil to omit. Grok accepts all four
  /// levels natively (verified: minimal/low/medium/high/none all 200).
  var grokReasoningEffort: String? {
    switch self {
    case .default: return nil
    default: return rawValue
    }
  }

  /// Gemini 3.x `thinkingLevel` value (minimal/low/medium/high), or nil to use the model default.
  var geminiThinkingLevel: String? {
    self == .default ? nil : rawValue
  }
}

// MARK: - Tool Declaration (provider-agnostic)

/// A tool/function declaration that can be sent to any LLM provider.
/// Each provider translates this into its native format.
struct LLMToolDeclaration {
  let name: String
  let description: String
  /// JSON Schema for parameters, e.g. ["type": "object", "properties": [...], "required": [...]]
  let parameters: [String: Any]
}

// MARK: - LLM Chat Provider Protocol

/// Abstraction over different LLM chat APIs (Gemini, Grok/xAI, etc.).
/// Each provider translates the unified interface into its native API format.
protocol LLMChatProvider {
  /// Streams a chat reply. Returns an async stream of `ChatStreamEvent`.
  ///
  /// - Parameters:
  ///   - model: The model ID string (e.g. "gemini-3.5-flash", "grok-4.3").
  ///   - contents: Conversation history in Gemini's `contents` format (array of role/parts dicts).
  ///     Each provider translates this into its native message format.
  ///   - systemInstruction: System instruction dict in Gemini format, or nil.
  ///   - tools: Tool declarations for function calling.
  ///   - useGrounding: Whether to enable web search grounding (Gemini-only; ignored by others).
  ///   - thinkingLevel: Per-session reasoning intensity (set via `/think`). `.default` uses the
  ///     model's built-in config; each provider maps the other levels to its native knob.
  ///   - disableBuiltInTools: When true, the provider sends no built-in tools (e.g. Gemini's
  ///     `code_execution`). Pure text transforms (Read Aloud rewrite, Smart Improvement) set
  ///     this so the model returns only prose, never code/tool output. Ignored by providers
  ///     that don't auto-enable built-in tools (OpenAI, Grok).
  ///   - cacheKey: Stable per-conversation identifier used to improve provider prompt-cache
  ///     hit rates — OpenAI maps it to the `prompt_cache_key` body field, Grok to the
  ///     `x-grok-conv-id` HTTP header. Pass `nil` for one-shot transforms with no conversation
  ///     continuity. Gemini caches implicitly and ignores it.
  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    useGrounding: Bool,
    thinkingLevel: ThinkingLevel,
    disableBuiltInTools: Bool,
    cacheKey: String?
  ) -> AsyncThrowingStream<ChatStreamEvent, Error>

  /// Generates a single, non-streaming JSON object constrained to `schema` (a JSON Schema dict).
  /// For internal "machine-read" tasks (chat titles, log analysis) where free-text + regex parsing
  /// is fragile — the model cannot return anything that violates the schema. Each provider maps it
  /// to its native structured-output mechanism:
  ///   - Gemini: `generationConfig.responseMimeType="application/json"` + `responseSchema`
  ///   - OpenAI / Grok: `response_format={type:"json_schema", json_schema:{name, strict, schema}}`
  ///
  /// `schema` is the *canonical* schema (`type`/`properties`/`required`/`enum`/`description`); the
  /// OpenAI/Grok paths adapt it for strict mode via `StructuredOutputSchema.strictified`. `schemaName`
  /// labels the schema for the OpenAI/Grok APIs (Gemini ignores it). Returns the parsed top-level
  /// object; throws on network error or if the model's output is not valid JSON.
  func generateStructured(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    schema: [String: Any],
    schemaName: String,
    thinkingLevel: ThinkingLevel
  ) async throws -> [String: Any]
}

extension LLMChatProvider {
  /// Provider-agnostic single-shot text generation. Routes through `generateStructured` with a
  /// one-field `{ text }` schema, so features like meeting summaries / speaker consolidation work
  /// uniformly on Gemini, OpenAI, and Grok without a per-provider endpoint. Returns the generated
  /// text (empty string if the model omits the field).
  func generateText(
    model: String,
    prompt: String,
    systemInstruction: String? = nil,
    thinkingLevel: ThinkingLevel = .default
  ) async throws -> String {
    let schema: [String: Any] = [
      "type": "object",
      "properties": ["text": ["type": "string"] as [String: Any]],
      "required": ["text"],
    ]
    let contents: [[String: Any]] = [["role": "user", "parts": [["text": prompt]]]]
    let sys: [String: Any]? = systemInstruction.map { ["parts": [["text": $0]]] }
    let obj = try await generateStructured(
      model: model,
      contents: contents,
      systemInstruction: sys,
      schema: schema,
      schemaName: "text_output",
      thinkingLevel: thinkingLevel)
    return (obj["text"] as? String) ?? ""
  }
}

// MARK: - Structured Output Schema Adapter

enum StructuredOutputSchema {
  /// Adapts a canonical JSON Schema to OpenAI/xAI **strict** `json_schema` rules: every object node
  /// gets `additionalProperties: false` and a `required` array listing all of its property keys
  /// (strict mode demands both). Recurses into nested `properties` and array `items`. Gemini uses the
  /// canonical schema unchanged — it rejects `additionalProperties`, so this adapter is applied only
  /// on the OpenAI/Grok paths.
  static func strictified(_ schema: [String: Any]) -> [String: Any] {
    var node = schema
    if (node["type"] as? String) == "object", let props = node["properties"] as? [String: Any] {
      var newProps: [String: Any] = [:]
      for (key, value) in props {
        newProps[key] = (value as? [String: Any]).map(strictified) ?? value
      }
      node["properties"] = newProps
      node["required"] = props.keys.sorted()
      node["additionalProperties"] = false
    }
    if (node["type"] as? String) == "array", let items = node["items"] as? [String: Any] {
      node["items"] = strictified(items)
    }
    return node
  }
}

// MARK: - OpenAI-Compatible Structured Output (shared by OpenAI + Grok)

/// Non-streaming Chat Completions call constrained to a JSON Schema via strict `json_schema`
/// `response_format`. Shared by `OpenAIChatProvider` and `GrokChatProvider` — both post to
/// OpenAI-Chat-Completions-compatible endpoints, so the request/response shape is identical; only
/// the endpoint, key, and reasoning-effort knob differ.
enum OpenAICompatibleStructured {
  static func generate(
    endpoint: String,
    apiKey: String,
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    schema: [String: Any],
    schemaName: String,
    reasoningEffort: String?,
    session: URLSession,
    logTag: String
  ) async throws -> [String: Any] {
    guard let url = URL(string: endpoint) else {
      throw TranscriptionError.networkError("Invalid \(logTag) endpoint URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 120

    var messages = OpenAIChatCompletionsConverter.messages(from: contents)
    if let sys = systemInstruction,
       let parts = sys["parts"] as? [[String: Any]],
       let text = parts.first?["text"] as? String, !text.isEmpty {
      messages.insert(["role": "system", "content": text], at: 0)
    }

    var body: [String: Any] = [
      "model": model,
      "messages": messages,
      "stream": false,
      "response_format": [
        "type": "json_schema",
        "json_schema": [
          "name": schemaName,
          "strict": true,
          "schema": StructuredOutputSchema.strictified(schema),
        ] as [String: Any],
      ] as [String: Any],
    ]
    if let reasoningEffort = reasoningEffort {
      body["reasoning_effort"] = reasoningEffort
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    DebugLogger.logNetwork("\(logTag)-STRUCTURED: POST \(endpoint) model=\(model) schema=\(schemaName)")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response from \(logTag) API")
    }
    if http.statusCode < 200 || http.statusCode >= 300 {
      let text = String(data: data, encoding: .utf8) ?? ""
      DebugLogger.logError("\(logTag)-STRUCTURED: HTTP \(http.statusCode) body=\(text.prefix(500))")
      if http.statusCode == 401 {
        throw TranscriptionError.networkError("\(logTag) API key is invalid. Check the key in Settings.")
      }
      if http.statusCode == 429 {
        throw TranscriptionError.rateLimited(retryAfter: nil)
      }
      throw TranscriptionError.networkError("\(logTag) API error HTTP \(http.statusCode): \(text.prefix(500))")
    }

    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = obj["choices"] as? [[String: Any]],
          let message = choices.first?["message"] as? [String: Any],
          let content = message["content"] as? String,
          let contentData = content.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
      throw TranscriptionError.networkError("\(logTag) structured response was not valid JSON")
    }
    return parsed
  }
}

// MARK: - Provider Factory

enum LLMProviderFactory {
  /// Returns the appropriate chat provider for the given model.
  static func provider(for model: PromptModel) -> LLMChatProvider {
    switch model.provider {
    case .gemini:
      return GeminiChatProvider.shared
    case .grok:
      return GrokChatProvider.shared
    case .openai:
      return OpenAIChatProvider.shared
    case .customOpenAI:
      return OpenAIChatProvider.shared
    case .local:
      return LocalLLMChatProvider.shared
    }
  }
}

// MARK: - OpenAI Chat Completions Converter (shared by OpenAI + Grok)

/// Converts Gemini-format `contents` (role/parts dicts) to OpenAI Chat Completions
/// `messages`. Both `OpenAIChatProvider` and `GrokChatProvider` post to OpenAI-compatible
/// `/v1/chat/completions` endpoints, so they share this translator.
///
/// Handles:
///   - Plain text turns
///   - Image content (Gemini `inline_data` with `image/*` mime) → `image_url` part
///   - Audio content (Gemini `inline_data` with `audio/*` mime) → `input_audio` part
///   - Function calls (`functionCall` part on a model turn) → `assistant.tool_calls`
///   - Function responses (`functionResponse` part on a user turn) → `role=tool` message
///
/// `stripImages: true` drops image parts silently — required for audio-only models like
/// `gpt-4o-audio-preview` that reject `image_url` with HTTP 400.
///
/// Tool-call IDs round-trip via `thoughtSignature` on the functionCall part when present;
/// otherwise fall back to positional `call_<index>` (the format Grok's code path produces).
/// Tool-result turns pair `tool_call_id` positionally against the preceding assistant
/// turn's `toolCallIds`.
enum OpenAIChatCompletionsConverter {
  static func messages(
    from contents: [[String: Any]],
    stripImages: Bool = false
  ) -> [[String: Any]] {
    var messages: [[String: Any]] = []
    var lastToolCallIds: [String] = []

    for content in contents {
      guard let role = content["role"] as? String,
            let parts = content["parts"] as? [[String: Any]] else { continue }

      let openAIRole: String
      switch role {
      case "model": openAIRole = "assistant"
      case "user": openAIRole = "user"
      default: openAIRole = role
      }

      // Assistant turn that emitted function calls.
      let functionCallParts = parts.filter { $0["functionCall"] != nil }
      if !functionCallParts.isEmpty {
        var toolCalls: [[String: Any]] = []
        var toolCallIds: [String] = []
        for (idx, part) in functionCallParts.enumerated() {
          guard let fc = part["functionCall"] as? [String: Any],
                let name = fc["name"] as? String else { continue }
          let args = fc["args"] as? [String: Any] ?? [:]
          let argsJSON = (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
          let callId = part["thoughtSignature"] as? String ?? "call_\(idx)"
          toolCalls.append([
            "id": callId,
            "type": "function",
            "function": [
              "name": name,
              "arguments": argsJSON,
            ] as [String: Any],
          ])
          toolCallIds.append(callId)
        }
        let textParts = parts.compactMap { $0["text"] as? String }.joined()
        var msg: [String: Any] = ["role": "assistant", "tool_calls": toolCalls]
        if !textParts.isEmpty { msg["content"] = textParts }
        messages.append(msg)
        lastToolCallIds = toolCallIds
        continue
      }

      // Tool-result turn.
      let functionResponseParts = parts.filter { $0["functionResponse"] != nil }
      if !functionResponseParts.isEmpty {
        for (idx, part) in functionResponseParts.enumerated() {
          guard let fr = part["functionResponse"] as? [String: Any],
                let resp = fr["response"] as? [String: Any] else { continue }
          let respJSON = (try? JSONSerialization.data(withJSONObject: resp))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
          let toolCallId = idx < lastToolCallIds.count ? lastToolCallIds[idx] : "call_\(idx)"
          messages.append([
            "role": "tool",
            "tool_call_id": toolCallId,
            "content": respJSON,
          ])
        }
        continue
      }

      // Regular text / image / audio parts.
      let hasMedia = parts.contains { part in
        if let inline = part["inline_data"] as? [String: Any],
           let mime = inline["mime_type"] as? String {
          if mime.hasPrefix("image/") { return !stripImages }
          if mime.hasPrefix("audio/") { return true }
        }
        return false
      }

      if hasMedia {
        var contentArray: [[String: Any]] = []
        for part in parts {
          if let text = part["text"] as? String, !text.isEmpty {
            contentArray.append(["type": "text", "text": text])
          } else if let inlineData = part["inline_data"] as? [String: Any],
                    let mimeType = inlineData["mime_type"] as? String,
                    let data = inlineData["data"] as? String {
            if mimeType.hasPrefix("image/") {
              if stripImages { continue }
              contentArray.append([
                "type": "image_url",
                "image_url": ["url": "data:\(mimeType);base64,\(data)"],
              ])
            } else if mimeType.hasPrefix("audio/") {
              contentArray.append([
                "type": "input_audio",
                "input_audio": [
                  "data": data,
                  "format": OpenAIChatProvider.openAIAudioFormat(forMimeType: mimeType),
                ] as [String: Any],
              ])
            }
          }
        }
        messages.append(["role": openAIRole, "content": contentArray])
      } else {
        let textParts = parts.compactMap { $0["text"] as? String }
        let joined = textParts.joined()
        if !joined.isEmpty {
          messages.append(["role": openAIRole, "content": joined])
        }
      }
    }
    return messages
  }
}

// MARK: - OpenAI/xAI Responses API Converter (shared by OpenAI + Grok)

/// Converts Gemini-format `contents` to the Responses API `input` array used by both
/// OpenAI's `/v1/responses` and xAI's `/v1/responses`. The shape differs from Chat
/// Completions:
///   - Text content uses `{"type": "input_text"/"output_text", "text": "..."}`.
///   - Images use `{"type": "input_image", "image_url": "data:..."}`.
///   - Function calls become top-level `function_call` items.
///   - Function responses become top-level `function_call_output` items, matched by
///     `call_id` positionally against the preceding model turn's `function_call` items.
///
/// Tool-call IDs round-trip via `thoughtSignature` on the functionCall part when present;
/// otherwise we fall back to a positional `call_<index>` to avoid name collisions when
/// the same function is invoked twice in one turn.
enum OpenAIResponsesAPIConverter {
  static func input(from contents: [[String: Any]]) -> [[String: Any]] {
    var input: [[String: Any]] = []
    for content in contents {
      guard let role = content["role"] as? String,
            let parts = content["parts"] as? [[String: Any]] else { continue }

      let functionCallParts = parts.filter { $0["functionCall"] != nil }
      if !functionCallParts.isEmpty {
        // Narration the model emitted alongside the calls (mixed Gemini-style model turn):
        // echo it as an assistant message item before the function_call items, mirroring how
        // the Responses API itself interleaves message and function_call output items.
        let narration = parts.compactMap { $0["text"] as? String }.joined()
        if !narration.isEmpty {
          input.append([
            "role": "assistant",
            "content": [["type": "output_text", "text": narration]],
          ])
        }
        for (idx, part) in functionCallParts.enumerated() {
          guard let fc = part["functionCall"] as? [String: Any],
                let name = fc["name"] as? String else { continue }
          let args = fc["args"] as? [String: Any] ?? [:]
          let argsJSON = (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
          let callId = part["thoughtSignature"] as? String ?? "call_\(idx)"
          input.append([
            "type": "function_call",
            "id": callId,
            "call_id": callId,
            "name": name,
            "arguments": argsJSON,
          ])
        }
        continue
      }

      let functionResponseParts = parts.filter { $0["functionResponse"] != nil }
      if !functionResponseParts.isEmpty {
        var callIds: [String] = []
        for item in input.reversed() {
          if let type = item["type"] as? String, type == "function_call",
             let cid = item["call_id"] as? String {
            callIds.insert(cid, at: 0)
          } else if !callIds.isEmpty {
            break
          }
        }
        for (idx, part) in functionResponseParts.enumerated() {
          guard let fr = part["functionResponse"] as? [String: Any],
                let resp = fr["response"] as? [String: Any] else { continue }
          let respJSON = (try? JSONSerialization.data(withJSONObject: resp))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
          let callId = idx < callIds.count ? callIds[idx] : "call_\(idx)"
          input.append([
            "type": "function_call_output",
            "call_id": callId,
            "output": respJSON,
          ])
        }
        continue
      }

      let apiRole: String
      switch role {
      case "model": apiRole = "assistant"
      case "user": apiRole = "user"
      default: apiRole = role
      }

      var contentParts: [[String: Any]] = []
      for part in parts {
        if let text = part["text"] as? String, !text.isEmpty {
          let textType = apiRole == "assistant" ? "output_text" : "input_text"
          contentParts.append(["type": textType, "text": text])
        } else if let inlineData = part["inline_data"] as? [String: Any],
                  let mimeType = inlineData["mime_type"] as? String,
                  let data = inlineData["data"] as? String,
                  mimeType.hasPrefix("image/") {
          contentParts.append([
            "type": "input_image",
            "image_url": "data:\(mimeType);base64,\(data)",
          ])
        }
      }

      if !contentParts.isEmpty {
        input.append([
          "role": apiRole,
          "content": contentParts,
        ])
      }
    }
    return input
  }
}

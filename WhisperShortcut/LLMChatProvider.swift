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
    OfflineModeURLProtocol.install(on: config)
    return URLSession(configuration: config)
  }()

  /// Session for the non-LLM integrations (Google, Trello, the OpenRouter catalog and OAuth
  /// exchanges, API-key validation). They used `URLSession.shared`, which cannot carry the
  /// Offline Mode guard — a session the app configures itself can. Default timeouts are kept:
  /// these are short REST calls, not the long-running model requests `shared` is tuned for.
  static let integrations: URLSession = {
    let config = URLSessionConfiguration.default
    OfflineModeURLProtocol.install(on: config)
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

extension LLMToolDeclaration {
  /// Chat Completions wants the declaration nested under `function`; the Responses API wants the
  /// same fields flat on the tool object. Both shapes were previously written out by hand in every
  /// OpenAI-compatible provider, so a field added to one endpoint's shape silently skipped the other.
  var chatCompletionsDeclaration: [String: Any] {
    [
      "type": "function",
      "function": [
        "name": name,
        "description": description,
        "parameters": parameters,
      ] as [String: Any],
    ]
  }

  var responsesDeclaration: [String: Any] {
    [
      "type": "function",
      "name": name,
      "description": description,
      "parameters": parameters,
    ]
  }
}

// MARK: - System Instruction Extraction

/// Pulls the plain text out of the Gemini-format `systemInstruction` dict that every provider
/// receives. Providers consume it differently — OpenAI/Grok/local prepend a `system` message,
/// Anthropic sets a top-level `system` field, the Responses API uses `instructions` — but they all
/// need the same string out of the same nested shape, which used to be re-derived in five places.
enum GeminiSystemInstruction {
  static func text(from systemInstruction: [String: Any]?) -> String? {
    guard let sys = systemInstruction,
          let parts = sys["parts"] as? [[String: Any]],
          let text = parts.first?["text"] as? String, !text.isEmpty else { return nil }
    return text
  }
}

// MARK: - Per-Request Options

/// The knobs that ride along with a chat turn without being part of the conversation itself.
///
/// Bundled into one value because all five providers take the identical set: every new knob used
/// to mean five signature edits plus every call site, and each provider had to re-declare the
/// parameters it ignores just to satisfy the protocol. Defaults describe a plain, ungrounded turn,
/// so call sites name only what they actually want.
struct ChatRequestOptions {
  /// Web-search grounding: Gemini's `google_search` + `url_context`, or the hosted `web_search`
  /// tool on the Grok/OpenAI Responses API. Anthropic and local models ignore it.
  var useGrounding: Bool = false

  /// Per-session reasoning intensity (set via `/think`). `.default` keeps the model's built-in
  /// config; each provider maps the other levels to its native knob.
  var thinkingLevel: ThinkingLevel = .default

  /// When true the provider sends no built-in tools (e.g. Gemini's `code_execution`). Pure text
  /// transforms (Read Aloud rewrite, Smart Improvement) set this so the model returns only prose,
  /// never code or tool output. Ignored by providers that don't auto-enable built-ins.
  var disableBuiltInTools: Bool = false

  /// Stable per-conversation identifier that improves provider prompt-cache hit rates — OpenAI
  /// maps it to `prompt_cache_key`, Grok to the `x-grok-conv-id` header. `nil` for one-shot
  /// transforms with no conversation continuity. Gemini caches implicitly and ignores it.
  var cacheKey: String? = nil

  /// X accounts to restrict Grok's `x_search` to (`/x` in chat, default in Settings → Chat).
  /// Empty = search all of X. Grok-only; every other provider ignores it. See `XSearchHandles` —
  /// this is a hard filter on xAI's side, not a ranking preference.
  var xHandles: [String] = []

  /// Whether this request's system prompt is stable enough that a provider may keep the prefill
  /// of it across requests.
  ///
  /// Only the in-process MLX provider acts on it, and only because priming a prefix is expensive:
  /// seconds of generation, and tens of megabytes held per distinct prompt. That pays when the
  /// same prompt really does come back — Dictate Prompt and the Read Aloud rewrite send a fixed
  /// one — and is a straight loss otherwise.
  ///
  /// Chat must leave this false. `ChatView.buildSystemInstruction` folds in today's date, the
  /// live meeting transcript, persistent memory and the workspace map, so the prompt differs on
  /// nearly every message; caching it would prime a prefix per message and never reuse one.
  var reusablePromptPrefix: Bool = false

  /// A one-shot text transform: no grounding, no built-in tools, no cache key, model-default
  /// thinking, and a system prompt that repeats. Used by Read Aloud's rewrite pass and the
  /// Dictate Prompt paths.
  static let textTransform = ChatRequestOptions(
    disableBuiltInTools: true, reusablePromptPrefix: true)
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
  ///   - options: Per-request knobs (grounding, reasoning depth, cache key, X handles). Providers
  ///     read the ones their API supports and ignore the rest — see `ChatRequestOptions`.
  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    options: ChatRequestOptions
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

    let messages = OpenAIChatCompletionsConverter.messages(
      from: contents, systemInstruction: systemInstruction)

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

// MARK: - OpenAI-Compatible Streaming (shared by OpenAI + Grok + Local)

/// The SSE plumbing behind every OpenAI-compatible streaming provider: issue the POST, map the
/// HTTP failure, then parse the event stream into `ChatStreamEvent`s.
///
/// Three providers post to `/v1/chat/completions` (OpenAI, xAI, and any local Ollama/LM Studio
/// server) and two post to `/v1/responses` (OpenAI, xAI). Each used to carry its own verbatim copy
/// of the parser — including the tool-call accumulator, the single most delicate part of the chat
/// path, where a fix had to be applied identically in three files or the providers silently drifted.
///
/// What genuinely differs per provider stays with the provider: the endpoint, the auth headers, the
/// body knobs (`temperature`, `max_tokens`, `modalities`, …) and the error mapping all arrive
/// through `Config`.
enum OpenAICompatibleStream {

  struct Config {
    let endpoint: String
    /// Auth and provider-specific headers (`Authorization`, `x-grok-conv-id`, …). `Content-Type`
    /// and `Accept` are always set.
    let headers: [String: String]
    /// Prefix for this provider's `DebugLogger` lines, e.g. `OPENAI-CHAT-STREAM`.
    let logTag: String
    /// Maps a non-2xx status + body to the error the user should see. Providers differ sharply
    /// here — xAI folds "out of credits" into 429, a local server's 404 means "model not pulled".
    let mapHTTPError: (Int, String) -> Error
    /// Maps a transport failure (connection refused, host unreachable) before any HTTP status
    /// exists. Only the local provider needs this; the default rethrows unchanged.
    var mapTransportError: (Error) -> Error = { $0 }
    var session: URLSession = LLMHTTPSession.shared
  }

  /// POSTs `body` and returns the byte stream, or throws the provider-mapped error.
  private static func openStream(
    _ config: Config, body: [String: Any]
  ) async throws -> URLSession.AsyncBytes {
    guard let url = URL(string: config.endpoint) else {
      throw TranscriptionError.networkError("Invalid \(config.logTag) endpoint URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (field, value) in config.headers {
      request.setValue(value, forHTTPHeaderField: field)
    }
    request.timeoutInterval = 300
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await config.session.bytes(for: request)
    } catch {
      throw config.mapTransportError(error)
    }

    guard let http = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response from \(config.logTag) API")
    }
    if http.statusCode < 200 || http.statusCode >= 300 {
      var errData = Data()
      for try await b in bytes { errData.append(b) }
      let text = String(data: errData, encoding: .utf8) ?? ""
      DebugLogger.logError("\(config.logTag): HTTP \(http.statusCode) body=\(text.prefix(500))")
      throw config.mapHTTPError(http.statusCode, text)
    }
    return bytes
  }

  // MARK: Chat Completions

  /// Streams `/v1/chat/completions` SSE. Tool calls arrive in fragments across many deltas, so they
  /// are accumulated and emitted once the stream ends.
  static func chatCompletions(
    _ config: Config, body: [String: Any]
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let bytes = try await openStream(config, body: body)

          // Keyed by the delta's `index` (Int, not String) so emission order survives double-digit
          // parallel tool calls — a string-keyed dict sorts "10" before "2".
          var pendingToolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
          var finishReason: String?

          for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let choice = choices.first else { continue }

            if let reason = choice["finish_reason"] as? String {
              finishReason = reason
            }
            guard let delta = choice["delta"] as? [String: Any] else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
              continuation.yield(.textDelta(content))
            }

            // Merge name/args without clobbering an in-flight accumulator if `name` arrives
            // mid-stream.
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
              for tc in toolCalls {
                let index = tc["index"] as? Int ?? 0
                let toolID = tc["id"] as? String
                if let function = tc["function"] as? [String: Any] {
                  let existing = pendingToolCalls[index]
                  let updatedName = (function["name"] as? String) ?? existing?.name ?? ""
                  let updatedId = toolID ?? existing?.id ?? "call_\(index)"
                  var updatedArgs = existing?.arguments ?? ""
                  if let argChunk = function["arguments"] as? String {
                    updatedArgs += argChunk
                  }
                  pendingToolCalls[index] = (id: updatedId, name: updatedName, arguments: updatedArgs)
                } else if let toolID = toolID, pendingToolCalls[index] == nil {
                  pendingToolCalls[index] = (id: toolID, name: "", arguments: "")
                }
              }
            }
          }

          // Round-trip `tool_call.id` via `thoughtSignature` so the message loop's tool-response
          // turn preserves the link.
          for key in pendingToolCalls.keys.sorted() {
            guard let tc = pendingToolCalls[key], !tc.name.isEmpty else { continue }
            let args = parseArguments(tc.arguments)
            DebugLogger.logNetwork("\(config.logTag): functionCall name=\(tc.name) id=\(tc.id)")
            continuation.yield(.functionCall(name: tc.name, args: args, thoughtSignature: tc.id))
          }

          DebugLogger.logNetwork("\(config.logTag): stream end, finishReason=\(finishReason ?? "nil")")
          continuation.yield(.finished(sources: [], supports: [], finishReason: finishReason))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  // MARK: Responses API

  /// Streams `/v1/responses` SSE (`event: <type>` + `data: <json>` pairs).
  ///
  /// `collectCitations` gathers `url_citation` annotations into the `finished` event's sources.
  /// Only providers that do *not* already write inline `[N]` markers into the reply text should
  /// enable it, otherwise the reply renders two competing sets of citation markers.
  static func responses(
    _ config: Config, body: [String: Any], collectCitations: Bool
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let bytes = try await openStream(config, body: body)

          var pendingFunctionCalls: [(name: String, args: [String: Any], callId: String)] = []
          var functionCallNames: [String: String] = [:]  // item_id → function name
          var currentEventType: String?
          var finishReason: String?
          // Unique URLs in first-seen order, so footer numbering ([1], [2], …) matches the
          // inline markers the model appends in citation order.
          var citationURLs: [String] = []
          var seenCitationURLs: Set<String> = []

          for try await line in bytes.lines {
            try Task.checkCancellation()

            if line.hasPrefix("event: ") {
              currentEventType = String(line.dropFirst(7))
              continue
            }

            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let eventType = currentEventType ?? obj["type"] as? String ?? ""
            currentEventType = nil

            switch eventType {
            case "response.output_text.delta":
              if let delta = obj["delta"] as? String, !delta.isEmpty {
                continuation.yield(.textDelta(delta))
              }

            case "response.function_call_arguments.done":
              // The name arrived earlier on `output_item.added`, keyed by item_id.
              let argsString = obj["arguments"] as? String ?? "{}"
              let itemId = obj["item_id"] as? String ?? ""
              if let existing = functionCallNames[itemId] {
                pendingFunctionCalls.append(
                  (name: existing, args: parseArguments(argsString), callId: itemId))
              }

            case "response.output_item.added":
              if let item = obj["item"] as? [String: Any],
                 let type = item["type"] as? String, type == "function_call",
                 let name = item["name"] as? String,
                 let itemId = item["id"] as? String {
                functionCallNames[itemId] = name
                DebugLogger.logNetwork("\(config.logTag): function_call added name=\(name) id=\(itemId)")
              }

            case "response.output_text.annotation.added":
              guard collectCitations else { break }
              if let ann = obj["annotation"] as? [String: Any],
                 (ann["type"] as? String) == "url_citation",
                 let url = (ann["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                 !url.isEmpty, seenCitationURLs.insert(url).inserted {
                citationURLs.append(url)
              }

            case "response.completed":
              if let resp = obj["response"] as? [String: Any],
                 let status = resp["status"] as? String {
                finishReason = status == "completed" ? "stop" : status
              }

            default:
              break
            }
          }

          // Pass callId via thoughtSignature for round-trip.
          for call in pendingFunctionCalls {
            DebugLogger.logNetwork("\(config.logTag): functionCall name=\(call.name) callId=\(call.callId)")
            continuation.yield(.functionCall(name: call.name, args: call.args, thoughtSignature: call.callId))
          }

          let sources = citationURLs.map {
            GroundingSource(uri: $0, title: citationDisplayTitle(for: $0))
          }
          DebugLogger.logNetwork("\(config.logTag): stream end, finishReason=\(finishReason ?? "nil") sources=\(sources.count)")
          // No `supports`: these providers write inline [N] markers into the reply text themselves,
          // so emitting grounding supports would render a second, duplicate set of markers.
          continuation.yield(.finished(sources: sources, supports: [], finishReason: finishReason))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  // MARK: Helpers

  /// Tool-call arguments arrive as a JSON *string*; a malformed one yields no arguments rather
  /// than failing the whole stream.
  private static func parseArguments(_ json: String) -> [String: Any] {
    guard let data = json.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return parsed
  }

  /// Display label for a citation footer entry. The providers' annotation `title` is often just the
  /// citation number, so the URL host (minus a leading "www.") reads better and matches how the
  /// source list renders for Gemini-grounded replies.
  private static func citationDisplayTitle(for urlString: String) -> String {
    guard let host = URL(string: urlString)?.host, !host.isEmpty else { return urlString }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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
    case .anthropic:
      return AnthropicChatProvider.shared
    case .customOpenAI:
      return OpenAIChatProvider.shared
    case .local:
      return LocalLLMChatProvider.shared
    case .localMLX:
      return MLXChatProvider.shared
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
  /// Converts `contents` and prepends the system instruction as the leading `system` message —
  /// the exact pair of steps every Chat Completions caller performs. Callers that need the
  /// instruction somewhere other than a message (Anthropic's `system` field, the Responses API's
  /// `instructions`) use `GeminiSystemInstruction.text(from:)` directly instead.
  static func messages(
    from contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    stripImages: Bool = false
  ) -> [[String: Any]] {
    var messages = self.messages(from: contents, stripImages: stripImages)
    if let text = GeminiSystemInstruction.text(from: systemInstruction) {
      messages.insert(["role": "system", "content": text], at: 0)
    }
    return messages
  }

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

import Foundation

/// Anthropic Claude implementation of `LLMChatProvider` via the Messages API.
/// Chat-only: no Dictate Prompt / TTS path. Docs:
/// https://platform.claude.com/docs/en/api/messages
final class AnthropicChatProvider: LLMChatProvider {
  static let shared = AnthropicChatProvider()

  private static let apiVersion = "2023-06-01"
  private static let messagesURL = "https://api.anthropic.com/v1/messages"
  private static let modelsURL = "https://api.anthropic.com/v1/models"

  private var session: URLSession { LLMHTTPSession.shared }

  private init() {}

  /// Anthropic's server-side web search, on for grounded chats like Gemini/GPT/Grok search. The basic
  /// variant, deliberately: the dynamic-filtering versions run the search from inside code
  /// execution, which adds block types this text-only history cannot replay. `max_uses` caps
  /// the per-request bill ($10 per 1,000 searches on the user's key) and keeps the server loop
  /// clear of `pause_turn`.
  static let webSearchTool: [String: Any] = [
    "type": "web_search_20250305",
    "name": "web_search",
    "max_uses": 5,
  ]

  /// Set once an org's admin turned web search off in the Anthropic Console: the API then rejects
  /// every request that carries the tool with a 400. Remembered for the app run so each later chat
  /// goes straight out without it instead of paying a failed round trip first.
  private let searchStateLock = NSLock()
  private var webSearchRejected = false

  private var isWebSearchRejected: Bool {
    searchStateLock.lock()
    defer { searchStateLock.unlock() }
    return webSearchRejected
  }

  private func markWebSearchRejected() {
    searchStateLock.lock()
    webSearchRejected = true
    searchStateLock.unlock()
  }

  /// A 400 that names web search — the tool, not the chat, is what the API refused.
  static func isWebSearchRejection(status: Int, body: String) -> Bool {
    guard status == 400 else { return false }
    let lower = body.lowercased()
    return lower.contains("web search") || lower.contains("web_search")
  }

  private struct WebSearchRejected: Error {}

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    // `useGrounding` / `disableBuiltInTools` gate web search (see `webSearchTool`) and
    // `thinkingLevel` maps to effort; Anthropic caches via explicit cache_control breakpoints.
    options: ChatRequestOptions
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    if let attachmentError = Self.validateAttachments(in: contents) {
      return AsyncThrowingStream { $0.finish(throwing: attachmentError) }
    }
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let apiKey = try Self.requireAPIKey()
          guard let url = URL(string: Self.messagesURL) else {
            throw TranscriptionError.networkError("Invalid Anthropic endpoint URL")
          }

          var request = URLRequest(url: url)
          request.httpMethod = "POST"
          Self.applyCommonHeaders(to: &request, apiKey: apiKey)
          request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
          request.timeoutInterval = 300

          let messages = AnthropicMessagesConverter.messages(from: contents)
          let systemText = GeminiSystemInstruction.text(from: systemInstruction)

          var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 16384,
            "stream": true,
          ]
          if let systemText, !systemText.isEmpty {
            body["system"] = systemText
          }
          let clientTools = tools.map { tool in
            [
              "name": tool.name,
              "description": tool.description,
              "input_schema": tool.parameters,
            ] as [String: Any]
          }
          var includesSearch =
            options.useGrounding && !options.disableBuiltInTools && !self.isWebSearchRejected
          let allTools = (includesSearch ? [Self.webSearchTool] : []) + clientTools
          if !allTools.isEmpty {
            body["tools"] = allTools
          }
          if let effort = options.thinkingLevel.anthropicEffort,
             Self.supportsEffort(model: model) {
            body["output_config"] = ["effort": effort]
          }

          request.httpBody = try JSONSerialization.data(withJSONObject: body)
          DebugLogger.logNetwork(
            "ANTHROPIC-CHAT-STREAM: POST \(Self.messagesURL) model=\(model) messages=\(messages.count) tools=\(tools.count) webSearch=\(includesSearch) effort=\(options.thinkingLevel.anthropicEffort ?? "default")"
          )

          func openStream() async throws -> URLSession.AsyncBytes {
            try await RetryBackoff.withPreFirstTokenRetry(logTag: "ANTHROPIC-CHAT-STREAM") {
              let (bytes, response) = try await self.session.bytes(for: request)
              guard let http = response as? HTTPURLResponse else {
                throw TranscriptionError.networkError("Invalid response from Anthropic API")
              }
              if http.statusCode < 200 || http.statusCode >= 300 {
                var errData = Data()
                for try await b in bytes { errData.append(b) }
                let text = String(data: errData, encoding: .utf8) ?? ""
                DebugLogger.logError("ANTHROPIC-CHAT-STREAM: HTTP \(http.statusCode) body=\(text.prefix(500))")
                if includesSearch, Self.isWebSearchRejection(status: http.statusCode, body: text) {
                  throw WebSearchRejected()
                }
                throw Self.mapHTTPError(status: http.statusCode, body: text)
              }
              return bytes
            }
          }

          let bytes: URLSession.AsyncBytes
          do {
            bytes = try await openStream()
          } catch is WebSearchRejected {
            // Search is off for this org; the chat itself should still work.
            DebugLogger.logWarning("ANTHROPIC-CHAT-STREAM: web search rejected by the API — retrying without it")
            self.markWebSearchRejected()
            includesSearch = false
            if clientTools.isEmpty {
              body.removeValue(forKey: "tools")
            } else {
              body["tools"] = clientTools
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            bytes = try await openStream()
          }

          var pendingToolUses: [(id: String, name: String, inputJSON: String)] = []
          var currentToolUseIndex: Int?
          var finishReason: String?
          var citations = AnthropicCitationCollector()
          // Characters yielded so far — the offsets citation supports are measured in, so they
          // must count every separator we insert too.
          var yieldedChars = 0
          var currentBlockIsText = false
          // Text after a search (or any non-text block) is a new thought: without a break the
          // "I'll search for that." preamble runs straight into the answer.
          var needsSeparator = false
          var hasYieldedText = false
          func yieldText(_ text: String) {
            continuation.yield(.textDelta(text))
            yieldedChars += text.count
            hasYieldedText = true
          }

          for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "content_block_start":
              let block = obj["content_block"] as? [String: Any]
              let blockType = block?["type"] as? String
              currentBlockIsText = blockType == "text"
              if currentBlockIsText {
                if needsSeparator {
                  yieldText("\n\n")
                  needsSeparator = false
                }
                citations.textBlockStarted(at: yieldedChars)
                if let initial = block?["text"] as? String, !initial.isEmpty { yieldText(initial) }
              } else if hasYieldedText {
                needsSeparator = true
              }
              if blockType == "server_tool_use" {
                continuation.yield(.activity(.searchingWeb))
                DebugLogger.logNetwork("ANTHROPIC-CHAT-STREAM: server_tool_use name=\(block?["name"] as? String ?? "?")")
              }
              if blockType == "tool_use",
                 let id = block?["id"] as? String,
                 let name = block?["name"] as? String {
                pendingToolUses.append((id: id, name: name, inputJSON: ""))
                currentToolUseIndex = pendingToolUses.count - 1
                DebugLogger.logNetwork("ANTHROPIC-CHAT-STREAM: tool_use start name=\(name) id=\(id)")
              } else {
                currentToolUseIndex = nil
              }

            case "content_block_delta":
              if let delta = obj["delta"] as? [String: Any] {
                if let text = delta["text"] as? String, !text.isEmpty {
                  yieldText(text)
                } else if let citation = delta["citation"] as? [String: Any] {
                  citations.add(citation)
                } else if let partial = delta["partial_json"] as? String,
                          let idx = currentToolUseIndex,
                          pendingToolUses.indices.contains(idx) {
                  pendingToolUses[idx].inputJSON += partial
                }
              }

            case "content_block_stop":
              if currentBlockIsText { citations.textBlockEnded(at: yieldedChars) }
              currentBlockIsText = false
              currentToolUseIndex = nil

            case "message_delta":
              if let delta = obj["delta"] as? [String: Any],
                 let stop = delta["stop_reason"] as? String {
                finishReason = stop
              }

            default:
              break
            }
          }

          for tool in pendingToolUses {
            let args: [String: Any]
            if let d = tool.inputJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
              args = parsed
            } else {
              args = [:]
            }
            DebugLogger.logNetwork("ANTHROPIC-CHAT-STREAM: functionCall name=\(tool.name) id=\(tool.id)")
            continuation.yield(.functionCall(name: tool.name, args: args, thoughtSignature: tool.id))
          }

          // `pause_turn` means the server-side search loop hit its iteration cap. Resuming needs the
          // paused content blocks sent back verbatim, which this text-only history doesn't keep, so
          // the reply ends with what streamed so far. `max_uses` keeps this rare.
          if finishReason == "pause_turn" {
            DebugLogger.logWarning("ANTHROPIC-CHAT-STREAM: pause_turn — reply ends at the paused search loop")
          }
          DebugLogger.logNetwork("ANTHROPIC-CHAT-STREAM: stream end, finishReason=\(finishReason ?? "nil") sources=\(citations.sources.count) supports=\(citations.supports.count)")
          continuation.yield(.finished(
            sources: citations.sources, supports: citations.supports, finishReason: finishReason))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  func generateStructured(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    schema: [String: Any],
    schemaName: String,
    thinkingLevel: ThinkingLevel
  ) async throws -> [String: Any] {
    let apiKey = try Self.requireAPIKey()
    guard let url = URL(string: Self.messagesURL) else {
      throw TranscriptionError.networkError("Invalid Anthropic endpoint URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    Self.applyCommonHeaders(to: &request, apiKey: apiKey)
    request.timeoutInterval = 120

    // Force a single tool call whose input must match `schema` — reliable structured output
    // without relying on free-text JSON parsing.
    let toolName = schemaName.isEmpty ? "structured_output" : schemaName
    var body: [String: Any] = [
      "model": model,
      "messages": AnthropicMessagesConverter.messages(from: contents),
      "max_tokens": 4096,
      "stream": false,
      "tools": [
        [
          "name": toolName,
          "description": "Return the result as structured data matching the schema.",
          "input_schema": schema,
        ] as [String: Any]
      ],
      "tool_choice": ["type": "tool", "name": toolName],
    ]
    if let systemText = GeminiSystemInstruction.text(from: systemInstruction), !systemText.isEmpty {
      body["system"] = systemText
    }
    if let effort = thinkingLevel.anthropicEffort,
       Self.supportsEffort(model: model) {
      body["output_config"] = ["effort": effort]
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    DebugLogger.logNetwork("ANTHROPIC-STRUCTURED: POST \(Self.messagesURL) model=\(model) schema=\(schemaName)")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response from Anthropic API")
    }
    if http.statusCode < 200 || http.statusCode >= 300 {
      let text = String(data: data, encoding: .utf8) ?? ""
      DebugLogger.logError("ANTHROPIC-STRUCTURED: HTTP \(http.statusCode) body=\(text.prefix(500))")
      throw Self.mapHTTPError(status: http.statusCode, body: text)
    }

    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = obj["content"] as? [[String: Any]] else {
      throw TranscriptionError.networkError("Anthropic structured response was not valid JSON")
    }
    for block in content {
      guard (block["type"] as? String) == "tool_use",
            let input = block["input"] as? [String: Any] else { continue }
      return input
    }
    throw TranscriptionError.networkError("Anthropic structured response did not include a tool_use block")
  }

  // MARK: - Helpers

  private static func requireAPIKey() throws -> String {
    try ProviderCredentials.require(.anthropic)
  }

  private static func applyCommonHeaders(to request: inout URLRequest, apiKey: String) {
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
  }

  private static func mapHTTPError(status: Int, body: String) -> Error {
    ChatProviderHTTPError.map(
      provider: "Claude",
      status: status,
      body: body,
      invalidKey: TranscriptionError.networkError(
        "Anthropic API key is invalid. Check the key in Settings → General."))
  }

  /// Effort / adaptive thinking is supported on Sonnet 5 and Opus 4.8 family models, not Haiku 4.5.
  private static func supportsEffort(model: String) -> Bool {
    model.contains("sonnet") || model.contains("opus") || model.contains("fable")
  }

  /// Claude Messages accepts images; reject non-image binary attachments up front.
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
      "Claude only supports image attachments — \(types) isn't supported. Switch to a Gemini model to chat about PDFs and documents."
    )
  }
}

extension ThinkingLevel {
  /// Anthropic `output_config.effort` for Sonnet 5 / Opus 4.8 adaptive thinking, or nil to omit.
  var anthropicEffort: String? {
    switch self {
    case .default: return nil
    case .minimal, .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    }
  }
}

// MARK: - Gemini contents → Anthropic Messages

enum AnthropicMessagesConverter {
  /// Converts Gemini-format `contents` (role/parts) to Anthropic Messages `messages`.
  /// Tool-call IDs round-trip via `thoughtSignature` on functionCall parts; tool results are
  /// paired positionally against the preceding assistant turn's tool_use ids (same as OpenAI).
  static func messages(from contents: [[String: Any]]) -> [[String: Any]] {
    var result: [[String: Any]] = []
    var lastToolUseIds: [String] = []

    for content in contents {
      let role = (content["role"] as? String) ?? "user"
      let parts = (content["parts"] as? [[String: Any]]) ?? []

      let functionCallParts = parts.filter { $0["functionCall"] != nil }
      if !functionCallParts.isEmpty {
        var blocks: [[String: Any]] = []
        var toolUseIds: [String] = []
        let textParts = parts.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
        for text in textParts {
          blocks.append(["type": "text", "text": text])
        }
        for (idx, part) in functionCallParts.enumerated() {
          guard let call = part["functionCall"] as? [String: Any],
                let name = call["name"] as? String else { continue }
          let args = (call["args"] as? [String: Any]) ?? [:]
          let id = (part["thoughtSignature"] as? String) ?? "toolu_\(idx)"
          blocks.append([
            "type": "tool_use",
            "id": id,
            "name": name,
            "input": args,
          ])
          toolUseIds.append(id)
        }
        if !blocks.isEmpty {
          result.append(["role": "assistant", "content": blocks])
        }
        lastToolUseIds = toolUseIds
        continue
      }

      let functionResponseParts = parts.filter { $0["functionResponse"] != nil }
      if !functionResponseParts.isEmpty {
        var toolResults: [[String: Any]] = []
        for (idx, part) in functionResponseParts.enumerated() {
          guard let fr = part["functionResponse"] as? [String: Any],
                let response = fr["response"] as? [String: Any] else { continue }
          let contentString: String
          if let json = try? JSONSerialization.data(withJSONObject: response),
             let s = String(data: json, encoding: .utf8) {
            contentString = s
          } else {
            contentString = "\(response)"
          }
          let toolUseId = idx < lastToolUseIds.count ? lastToolUseIds[idx] : "toolu_\(idx)"
          toolResults.append([
            "type": "tool_result",
            "tool_use_id": toolUseId,
            "content": contentString,
          ])
        }
        if !toolResults.isEmpty {
          result.append(["role": "user", "content": toolResults])
        }
        continue
      }

      // Regular user text / image turn.
      var userBlocks: [[String: Any]] = []
      for part in parts {
        if let text = part["text"] as? String, !text.isEmpty {
          userBlocks.append(["type": "text", "text": text])
        } else if let inlineData = part["inline_data"] as? [String: Any],
                  let mimeType = inlineData["mime_type"] as? String,
                  mimeType.hasPrefix("image/"),
                  let data = inlineData["data"] as? String {
          userBlocks.append([
            "type": "image",
            "source": [
              "type": "base64",
              "media_type": mimeType,
              "data": data,
            ] as [String: Any],
          ])
        }
      }
      if !userBlocks.isEmpty {
        let anthropicRole = (role == "model" || role == "assistant") ? "assistant" : "user"
        result.append(["role": anthropicRole, "content": userBlocks])
      }
    }
    return result
  }
}

// MARK: - Web search citations

/// Turns the web-search citations Claude streams into the sources + paragraph supports the reply
/// renderer already uses for Gemini grounding.
///
/// Claude splits its answer into text blocks and attaches `citations_delta` events to the block
/// that makes the claim, so a block's character range in the streamed reply is exactly the span a
/// source supports. Nothing is written into the reply text itself.
struct AnthropicCitationCollector {
  private(set) var sources: [GroundingSource] = []
  private(set) var supports: [GroundingSupport] = []
  private var blockStart = 0
  private var blockSourceIndices: [Int] = []

  mutating func textBlockStarted(at offset: Int) {
    blockStart = offset
    blockSourceIndices = []
  }

  /// One `citations_delta` citation. Only web results carry a URL; other kinds are ignored.
  mutating func add(_ citation: [String: Any]) {
    guard let url = (citation["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !url.isEmpty else { return }
    let index: Int
    if let existing = sources.firstIndex(where: { $0.uri == url }) {
      index = existing
    } else {
      sources.append(GroundingSource(uri: url, title: GroundingSource.displayTitle(for: url)))
      index = sources.count - 1
    }
    if !blockSourceIndices.contains(index) { blockSourceIndices.append(index) }
  }

  mutating func textBlockEnded(at offset: Int) {
    if !blockSourceIndices.isEmpty, offset > blockStart {
      supports.append(GroundingSupport(
        startIndex: blockStart, endIndex: offset, groundingChunkIndices: blockSourceIndices))
    }
    blockSourceIndices = []
  }
}

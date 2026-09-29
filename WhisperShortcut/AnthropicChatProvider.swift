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

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    // Only `thinkingLevel` applies: Claude web search isn't wired in this app and there are no
    // auto-enabled built-ins. `cacheKey` is unused — Anthropic caches by prefix via the
    // `cache_control` breakpoints set below.
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
          if !tools.isEmpty {
            var toolDefs: [[String: Any]] = tools.map { tool in
              [
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.parameters,
              ] as [String: Any]
            }
            // Explicit breakpoint on the last tool: tools render first and change only when an
            // integration is connected, so this prefix is re-read across turns and tool rounds
            // even when the system prompt's volatile tail (memory, meeting transcript) changes.
            toolDefs[toolDefs.count - 1]["cache_control"] = ["type": "ephemeral"]
            body["tools"] = toolDefs
          }
          // Automatic caching for the growing tail: the API places this breakpoint on the last
          // cacheable block and moves it forward each turn, so every tool round and follow-up
          // re-reads the whole conversation instead of paying full input price again.
          body["cache_control"] = ["type": "ephemeral"]
          if let effort = options.thinkingLevel.anthropicEffort,
             Self.supportsEffort(model: model) {
            body["output_config"] = ["effort": effort]
          }

          request.httpBody = try JSONSerialization.data(withJSONObject: body)
          DebugLogger.logNetwork(
            "ANTHROPIC-CHAT-STREAM: POST \(Self.messagesURL) model=\(model) messages=\(messages.count) tools=\(tools.count) effort=\(options.thinkingLevel.anthropicEffort ?? "default")"
          )

          let bytes = try await RetryBackoff.withPreFirstTokenRetry(logTag: "ANTHROPIC-CHAT-STREAM") {
            let (bytes, response) = try await self.session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
              throw TranscriptionError.networkError("Invalid response from Anthropic API")
            }
            if http.statusCode < 200 || http.statusCode >= 300 {
              var errData = Data()
              for try await b in bytes { errData.append(b) }
              let text = String(data: errData, encoding: .utf8) ?? ""
              DebugLogger.logError("ANTHROPIC-CHAT-STREAM: HTTP \(http.statusCode) body=\(text.prefix(500))")
              throw Self.mapHTTPError(status: http.statusCode, body: text)
            }
            return bytes
          }

          var pendingToolUses: [(id: String, name: String, inputJSON: String)] = []
          var currentToolUseIndex: Int?
          // Thinking / redacted_thinking blocks, in stream order. Opus 5.5 and later think on every
          // request and reject a tool-use loop whose assistant turn comes back without them, so
          // they ride along with the first tool call (see `AnthropicToolCallEnvelope`).
          var thinkingBlocks: [[String: Any]] = []
          var currentThinkingIndex: Int?
          // Stream order of thinking / text / tool_use blocks, so the converter can rebuild the
          // turn exactly: interleaved thinking moved ahead of an earlier tool_use is a 400.
          var layout: [String] = []
          var finishReason: String?

          for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "message_start":
              // Cache verification: reads staying at 0 across turns means something in the
              // prefix changes per request (see buildSystemInstruction's ordering note).
              if let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any] {
                DebugLogger.logNetwork(
                  "ANTHROPIC-CHAT-STREAM: usage input=\(usage["input_tokens"] ?? 0) "
                  + "cacheRead=\(usage["cache_read_input_tokens"] ?? 0) "
                  + "cacheWrite=\(usage["cache_creation_input_tokens"] ?? 0)")
              }

            case "content_block_start":
              if let block = obj["content_block"] as? [String: Any],
                 (block["type"] as? String) == "tool_use",
                 let id = block["id"] as? String,
                 let name = block["name"] as? String {
                pendingToolUses.append((id: id, name: name, inputJSON: ""))
                currentToolUseIndex = pendingToolUses.count - 1
                currentThinkingIndex = nil
                layout.append(AnthropicToolCallEnvelope.toolUseSlot(id))
                DebugLogger.logNetwork("ANTHROPIC-CHAT-STREAM: tool_use start name=\(name) id=\(id)")
              } else if let block = obj["content_block"] as? [String: Any],
                        let blockType = block["type"] as? String,
                        blockType == "thinking" || blockType == "redacted_thinking" {
                thinkingBlocks.append(block)
                currentThinkingIndex = thinkingBlocks.count - 1
                currentToolUseIndex = nil
                layout.append(AnthropicToolCallEnvelope.thinkingSlot(thinkingBlocks.count - 1))
              } else {
                if let block = obj["content_block"] as? [String: Any],
                   (block["type"] as? String) == "text",
                   !layout.contains(AnthropicToolCallEnvelope.textSlot) {
                  layout.append(AnthropicToolCallEnvelope.textSlot)
                }
                currentToolUseIndex = nil
                currentThinkingIndex = nil
              }

            case "content_block_delta":
              if let delta = obj["delta"] as? [String: Any] {
                if let text = delta["text"] as? String, !text.isEmpty {
                  continuation.yield(.textDelta(text))
                } else if let partial = delta["partial_json"] as? String,
                          let idx = currentToolUseIndex,
                          pendingToolUses.indices.contains(idx) {
                  pendingToolUses[idx].inputJSON += partial
                } else if let idx = currentThinkingIndex, thinkingBlocks.indices.contains(idx) {
                  // Accumulate verbatim — the API rejects an edited thinking block.
                  if let thinking = delta["thinking"] as? String {
                    thinkingBlocks[idx]["thinking"] = ((thinkingBlocks[idx]["thinking"] as? String) ?? "") + thinking
                  } else if let signature = delta["signature"] as? String {
                    thinkingBlocks[idx]["signature"] = ((thinkingBlocks[idx]["signature"] as? String) ?? "") + signature
                  }
                }
              }

            case "content_block_stop":
              currentToolUseIndex = nil
              currentThinkingIndex = nil

            case "message_delta":
              if let delta = obj["delta"] as? [String: Any],
                 let stop = delta["stop_reason"] as? String {
                finishReason = stop
              }

            default:
              break
            }
          }

          for (index, tool) in pendingToolUses.enumerated() {
            let args: [String: Any]
            if let d = tool.inputJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
              args = parsed
            } else {
              args = [:]
            }
            DebugLogger.logNetwork("ANTHROPIC-CHAT-STREAM: functionCall name=\(tool.name) id=\(tool.id)")
            let signature = index == 0
              ? AnthropicToolCallEnvelope.encode(toolUseId: tool.id, thinking: thinkingBlocks, layout: layout)
              : tool.id
            continuation.yield(.functionCall(name: tool.name, args: args, thoughtSignature: signature))
          }

          DebugLogger.logNetwork("ANTHROPIC-CHAT-STREAM: stream end, finishReason=\(finishReason ?? "nil")")
          continuation.yield(.finished(sources: [], supports: [], finishReason: finishReason))
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
    // Non-streaming, so the idle timeout caps the whole call — and always-on thinking (Opus 5.5+)
    // runs before the first byte. Same budget as the chat stream.
    request.timeoutInterval = 300

    // Structured outputs (`output_config.format`), not a forced tool call: Opus 5.5 and later
    // reject `tool_choice` `tool`/`any` with a 400. Supported on every current Claude model incl.
    // Haiku 4.5; objects need `additionalProperties: false`, which `strictified` adds.
    // https://platform.claude.com/docs/en/build-with-claude/structured-outputs
    var outputConfig: [String: Any] = [
      "format": [
        "type": "json_schema",
        "schema": StructuredOutputSchema.strictified(schema),
      ] as [String: Any]
    ]
    if let effort = thinkingLevel.anthropicEffort,
       Self.supportsEffort(model: model) {
      outputConfig["effort"] = effort
    }
    var body: [String: Any] = [
      "model": model,
      "messages": AnthropicMessagesConverter.messages(from: contents),
      // Covers thinking plus the JSON on always-thinking models (Opus 5.5+).
      "max_tokens": 16384,
      "stream": false,
      "output_config": outputConfig,
    ]
    if let systemText = GeminiSystemInstruction.text(from: systemInstruction), !systemText.isEmpty {
      body["system"] = systemText
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
    // Select by block type: thinking blocks come first on always-thinking models.
    let text = content
      .filter { ($0["type"] as? String) == "text" }
      .compactMap { $0["text"] as? String }
      .joined()
    guard let json = text.data(using: .utf8),
          let result = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
      switch obj["stop_reason"] as? String {
      case "refusal":
        throw TranscriptionError.networkError("Claude declined this request.")
      case "max_tokens":
        throw TranscriptionError.networkError("Claude's structured reply was cut off at the token limit.")
      default:
        break
      }
      throw TranscriptionError.networkError("Anthropic structured response did not include valid JSON")
    }
    return result
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

  /// Effort / adaptive thinking is supported on Sonnet, Opus and Fable models, not Haiku 4.5.
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
  ///
  /// Thinking blocks are re-sent only for tool-call turns after the last plain user message —
  /// the open tool loop, which is where the API requires them. Older turns drop them: the API
  /// ignores earlier thinking anyway, and a signature from another model (after `/model`) must not
  /// reach this one.
  static func messages(from contents: [[String: Any]]) -> [[String: Any]] {
    var result: [[String: Any]] = []
    var lastToolUseIds: [String] = []
    let lastUserTextIndex = contents.lastIndex { content in
      let role = (content["role"] as? String) ?? "user"
      let parts = (content["parts"] as? [[String: Any]]) ?? []
      return role == "user" && !parts.contains { $0["functionResponse"] != nil }
    }

    for (contentIndex, content) in contents.enumerated() {
      let role = (content["role"] as? String) ?? "user"
      let parts = (content["parts"] as? [[String: Any]]) ?? []

      let functionCallParts = parts.filter { $0["functionCall"] != nil }
      if !functionCallParts.isEmpty {
        var blocks: [[String: Any]] = []
        var toolUseIds: [String] = []
        let inOpenToolLoop = contentIndex > (lastUserTextIndex ?? -1)
        let textBlocks: [[String: Any]] = parts.compactMap { $0["text"] as? String }
          .filter { !$0.isEmpty }
          .map { ["type": "text", "text": $0] }
        var toolUseBlocks: [[String: Any]] = []
        var thinking: [[String: Any]] = []
        var layout: [String] = []
        for (idx, part) in functionCallParts.enumerated() {
          guard let call = part["functionCall"] as? [String: Any],
                let name = call["name"] as? String else { continue }
          let args = (call["args"] as? [String: Any]) ?? [:]
          let envelope = AnthropicToolCallEnvelope.decode(part["thoughtSignature"] as? String)
          let id = envelope.toolUseId ?? "toolu_\(idx)"
          if inOpenToolLoop && !envelope.thinking.isEmpty {
            thinking = envelope.thinking
            layout = envelope.layout
          }
          toolUseBlocks.append([
            "type": "tool_use",
            "id": id,
            "name": name,
            "input": args,
          ])
          toolUseIds.append(id)
        }
        blocks = AnthropicToolCallEnvelope.assemble(
          thinking: thinking, text: textBlocks, toolUses: toolUseBlocks, layout: layout)
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

// MARK: - Tool-call envelope

/// Packs a tool call's `tool_use` id — plus, on the first call of a turn, that turn's thinking
/// blocks — into the opaque `thoughtSignature` string that the chat loop already round-trips
/// untouched (`ChatView.executeToolCalls`). Keeps the Anthropic-only requirement "echo thinking
/// blocks unmodified in tool loops" inside this file instead of widening `ChatStreamEvent`.
/// A bare id (no prefix) is the pre-envelope format and still decodes.
enum AnthropicToolCallEnvelope {
  private static let prefix = "anthropic-v1:"

  static let textSlot = "text"
  static func thinkingSlot(_ index: Int) -> String { "thinking:\(index)" }
  static func toolUseSlot(_ id: String) -> String { "tool_use:\(id)" }

  static func encode(toolUseId: String, thinking: [[String: Any]], layout: [String] = []) -> String {
    guard !thinking.isEmpty,
          let data = try? JSONSerialization.data(
            withJSONObject: ["id": toolUseId, "thinking": thinking, "layout": layout])
    else { return toolUseId }
    return prefix + data.base64EncodedString()
  }

  static func decode(_ signature: String?)
    -> (toolUseId: String?, thinking: [[String: Any]], layout: [String])
  {
    guard let signature else { return (nil, [], []) }
    guard signature.hasPrefix(prefix),
          let data = Data(base64Encoded: String(signature.dropFirst(prefix.count))),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (signature, [], []) }
    return (obj["id"] as? String, (obj["thinking"] as? [[String: Any]]) ?? [],
            (obj["layout"] as? [String]) ?? [])
  }

  /// Rebuilds an assistant turn in the order the stream produced it. Without a layout (no
  /// thinking, or a closed loop) it is text then tool_use; blocks the layout doesn't name are
  /// appended so nothing is ever dropped.
  static func assemble(
    thinking: [[String: Any]], text: [[String: Any]], toolUses: [[String: Any]], layout: [String]
  ) -> [[String: Any]] {
    guard !thinking.isEmpty else { return text + toolUses }
    var result: [[String: Any]] = []
    var usedThinking = Set<Int>()
    var usedToolIds = Set<String>()
    var textPlaced = false
    for slot in layout {
      if slot == textSlot {
        if !textPlaced { result += text; textPlaced = true }
      } else if slot.hasPrefix("thinking:"), let i = Int(slot.dropFirst("thinking:".count)),
                thinking.indices.contains(i), !usedThinking.contains(i) {
        result.append(thinking[i]); usedThinking.insert(i)
      } else if slot.hasPrefix("tool_use:") {
        let id = String(slot.dropFirst("tool_use:".count))
        if let block = toolUses.first(where: { ($0["id"] as? String) == id }), !usedToolIds.contains(id) {
          result.append(block); usedToolIds.insert(id)
        }
      }
    }
    // Leftovers: unplaced thinking still leads (API requirement), then text, then tool_use.
    let leftoverThinking = thinking.indices.filter { !usedThinking.contains($0) }.map { thinking[$0] }
    result.insert(contentsOf: leftoverThinking, at: 0)
    if !textPlaced { result += text }
    result += toolUses.filter { !usedToolIds.contains(($0["id"] as? String) ?? "") }
    return result
  }
}

import Foundation

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
  ///   - model: The model ID string (e.g. "gemini-3-flash-preview", "grok-3").
  ///   - contents: Conversation history in Gemini's `contents` format (array of role/parts dicts).
  ///     Each provider translates this into its native message format.
  ///   - systemInstruction: System instruction dict in Gemini format, or nil.
  ///   - tools: Tool declarations for function calling.
  ///   - useGrounding: Whether to enable web search grounding (Gemini-only; ignored by others).
  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    useGrounding: Bool
  ) -> AsyncThrowingStream<ChatStreamEvent, Error>
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

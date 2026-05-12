import Foundation

/// OpenAI implementation of `LLMChatProvider`.
/// Uses OpenAI's Chat Completions API (`/v1/chat/completions`) with streaming SSE.
/// Reference: https://platform.openai.com/docs/api-reference/chat
final class OpenAIChatProvider: LLMChatProvider {
  static let shared = OpenAIChatProvider()

  private let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 300
    return URLSession(configuration: config)
  }()

  private init() {}

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    useGrounding: Bool
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    if useGrounding {
      DebugLogger.log("OPENAI-CHAT-STREAM: grounding requested but not supported on Chat Completions; ignoring flag")
    }
    return sendViaChatCompletions(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools)
  }

  // MARK: - Chat Completions

  private func sendViaChatCompletions(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration]
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard let apiKey = KeychainManager.shared.getOpenAIAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
                !apiKey.isEmpty else {
            throw TranscriptionError.networkError("No OpenAI API key configured. Add your OpenAI API key in Settings to use OpenAI models.")
          }

          let endpoint = "https://api.openai.com/v1/chat/completions"
          guard let url = URL(string: endpoint) else {
            throw TranscriptionError.networkError("Invalid OpenAI endpoint URL")
          }

          var request = URLRequest(url: url)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
          request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
          request.timeoutInterval = 300

          // Build OpenAI-format messages from Gemini-format contents.
          // Reuses the same translator that GrokChatProvider uses, since both speak
          // OpenAI Chat Completions.
          var messages = Self.convertContentsToMessages(contents)

          // Prepend system message if provided.
          if let sys = systemInstruction,
             let parts = sys["parts"] as? [[String: Any]],
             let text = parts.first?["text"] as? String, !text.isEmpty {
            messages.insert(["role": "system", "content": text], at: 0)
          }

          var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
          ]

          // gpt-4o-audio-preview requires both text and audio modalities to be declared
          // when audio content is present in the input. We always declare ["text"] for chat
          // output and let the request itself contain audio parts when applicable; the
          // audio-preview model handles this fine.
          if model == PromptModel.openaiGPT4oAudio.rawValue {
            body["modalities"] = ["text"]
          }

          if !tools.isEmpty {
            let openAITools: [[String: Any]] = tools.map { tool in
              [
                "type": "function",
                "function": [
                  "name": tool.name,
                  "description": tool.description,
                  "parameters": tool.parameters,
                ] as [String: Any],
              ]
            }
            body["tools"] = openAITools
          }

          request.httpBody = try JSONSerialization.data(withJSONObject: body)

          DebugLogger.logNetwork("OPENAI-CHAT-STREAM: POST \(endpoint) model=\(model) messages=\(messages.count) tools=\(tools.count)")
          let (bytes, response) = try await self.session.bytes(for: request)
          guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.networkError("Invalid response from OpenAI API")
          }
          if http.statusCode < 200 || http.statusCode >= 300 {
            var errData = Data()
            for try await b in bytes { errData.append(b) }
            let text = String(data: errData, encoding: .utf8) ?? ""
            DebugLogger.logError("OPENAI-CHAT-STREAM: HTTP \(http.statusCode) body=\(text.prefix(500))")
            if http.statusCode == 401 {
              throw TranscriptionError.networkError("OpenAI API key is invalid. Check the key in Settings → General.")
            }
            throw TranscriptionError.networkError("OpenAI API error HTTP \(http.statusCode): \(text)")
          }

          // Parse SSE stream in Chat Completions format.
          var pendingToolCalls: [String: (id: String, name: String, arguments: String)] = [:]
          var finishReason: String?

          for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" {
              break
            }
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

            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
              for tc in toolCalls {
                let index = tc["index"] as? Int ?? 0
                let key = "\(index)"
                let toolID = tc["id"] as? String
                if let function = tc["function"] as? [String: Any] {
                  if let name = function["name"] as? String {
                    pendingToolCalls[key] = (id: toolID ?? pendingToolCalls[key]?.id ?? "call_\(key)", name: name, arguments: "")
                  }
                  if let argChunk = function["arguments"] as? String {
                    if var existing = pendingToolCalls[key] {
                      existing.arguments += argChunk
                      pendingToolCalls[key] = existing
                    } else {
                      pendingToolCalls[key] = (id: toolID ?? "call_\(key)", name: "", arguments: argChunk)
                    }
                  }
                } else if let toolID = toolID, pendingToolCalls[key] == nil {
                  pendingToolCalls[key] = (id: toolID, name: "", arguments: "")
                }
              }
            }
          }

          for key in pendingToolCalls.keys.sorted() {
            guard let tc = pendingToolCalls[key], !tc.name.isEmpty else { continue }
            let args: [String: Any]
            if let data = tc.arguments.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
              args = parsed
            } else {
              args = [:]
            }
            DebugLogger.logNetwork("OPENAI-CHAT-STREAM: functionCall name=\(tc.name) id=\(tc.id)")
            // Round-trip the OpenAI tool_call.id via `thoughtSignature` so the message-loop's
            // subsequent assistant-with-tool-calls + tool-response turn can preserve the link.
            continuation.yield(.functionCall(name: tc.name, args: args, thoughtSignature: tc.id))
          }

          DebugLogger.logNetwork("OPENAI-CHAT-STREAM: stream end, finishReason=\(finishReason ?? "nil")")
          continuation.yield(.finished(sources: [], supports: [], finishReason: finishReason))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  // MARK: - Format Conversion

  /// Converts Gemini-format `contents` to OpenAI Chat Completions `messages`.
  /// Handles text, image_url (via Gemini's `inline_data` with image/* mime types), and
  /// input_audio (via Gemini's `inline_data` with audio/* mime types) content parts.
  /// Function call / function response turns are mapped to `assistant.tool_calls` and
  /// `role=tool` messages, with the `tool_call_id` carried via `thoughtSignature` when
  /// it was previously round-tripped through the stream.
  static func convertContentsToMessages(_ contents: [[String: Any]]) -> [[String: Any]] {
    var messages: [[String: Any]] = []
    // Track the most recent assistant turn's tool_call ids so the following tool-result turn
    // can match them positionally.
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
          return mime.hasPrefix("image/") || mime.hasPrefix("audio/")
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
              contentArray.append([
                "type": "image_url",
                "image_url": ["url": "data:\(mimeType);base64,\(data)"],
              ])
            } else if mimeType.hasPrefix("audio/") {
              // Map MIME type → OpenAI audio format string.
              let format: String
              if mimeType.contains("wav") {
                format = "wav"
              } else if mimeType.contains("mp3") || mimeType.contains("mpeg") {
                format = "mp3"
              } else {
                format = "wav"
              }
              contentArray.append([
                "type": "input_audio",
                "input_audio": [
                  "data": data,
                  "format": format,
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

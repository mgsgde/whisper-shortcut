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
    useGrounding: Bool
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    if useGrounding {
      return sendViaResponsesAPI(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools)
    }
    return sendViaChatCompletions(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools)
  }

  // MARK: - Responses API (with web_search)

  /// Uses OpenAI's Responses API which supports the hosted `web_search` tool. SSE event format
  /// matches xAI's (xAI's Responses API mirrors OpenAI's), so the parser here is structurally
  /// identical to `GrokChatProvider.sendViaResponsesAPI`.
  private func sendViaResponsesAPI(
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

          let endpoint = "https://api.openai.com/v1/responses"
          guard let url = URL(string: endpoint) else {
            throw TranscriptionError.networkError("Invalid OpenAI endpoint URL")
          }

          var request = URLRequest(url: url)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
          request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
          request.timeoutInterval = 300

          let input = OpenAIResponsesAPIConverter.input(from: contents)

          let instructions: String? = {
            guard let sys = systemInstruction,
                  let parts = sys["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String, !text.isEmpty else { return nil }
            return text
          }()

          var body: [String: Any] = [
            "model": model,
            "input": input,
            "stream": true,
          ]
          if let instructions = instructions {
            body["instructions"] = instructions
          }

          var responsesTools: [[String: Any]] = [
            ["type": "web_search"],
          ]
          for tool in tools {
            responsesTools.append([
              "type": "function",
              "name": tool.name,
              "description": tool.description,
              "parameters": tool.parameters,
            ])
          }
          body["tools"] = responsesTools

          request.httpBody = try JSONSerialization.data(withJSONObject: body)

          DebugLogger.logNetwork("OPENAI-RESPONSES: POST \(endpoint) model=\(model) tools=web_search+\(tools.count)func")
          let (bytes, response) = try await self.session.bytes(for: request)
          guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.networkError("Invalid response from OpenAI API")
          }
          if http.statusCode < 200 || http.statusCode >= 300 {
            var errData = Data()
            for try await b in bytes { errData.append(b) }
            let text = String(data: errData, encoding: .utf8) ?? ""
            DebugLogger.logError("OPENAI-RESPONSES: HTTP \(http.statusCode) body=\(text.prefix(500))")
            if http.statusCode == 401 {
              throw TranscriptionError.networkError("OpenAI API key is invalid. Check the key in Settings → General.")
            }
            if http.statusCode == 429 {
              throw TranscriptionError.rateLimited(retryAfter: nil)
            }
            throw TranscriptionError.networkError("OpenAI API error HTTP \(http.statusCode): \(text.prefix(500))")
          }

          // Parse Responses API SSE stream. Event format: "event: <type>\ndata: <json>\n\n".
          var pendingFunctionCalls: [(name: String, args: [String: Any], callId: String)] = []
          var functionCallNames: [String: String] = [:]  // item_id → function name
          var currentEventType: String?
          var finishReason: String?

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
              let argsString = obj["arguments"] as? String ?? "{}"
              let itemId = obj["item_id"] as? String ?? ""
              if let existing = functionCallNames[itemId] {
                let args: [String: Any]
                if let d = argsString.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                  args = parsed
                } else {
                  args = [:]
                }
                pendingFunctionCalls.append((name: existing, args: args, callId: itemId))
              }

            case "response.output_item.added":
              if let item = obj["item"] as? [String: Any],
                 let type = item["type"] as? String, type == "function_call",
                 let name = item["name"] as? String,
                 let itemId = item["id"] as? String {
                functionCallNames[itemId] = name
                DebugLogger.logNetwork("OPENAI-RESPONSES: function_call added name=\(name) id=\(itemId)")
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

          for call in pendingFunctionCalls {
            DebugLogger.logNetwork("OPENAI-RESPONSES: functionCall name=\(call.name) callId=\(call.callId)")
            continuation.yield(.functionCall(name: call.name, args: call.args, thoughtSignature: call.callId))
          }

          DebugLogger.logNetwork("OPENAI-RESPONSES: stream end, finishReason=\(finishReason ?? "nil")")
          continuation.yield(.finished(sources: [], supports: [], finishReason: finishReason))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
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
          // gpt-4o-audio-preview is audio-only and rejects image_url parts (HTTP 400),
          // so we drop images for that model.
          let stripImages = (model == PromptModel.openaiGPT4oAudio.rawValue)
          var messages = OpenAIChatCompletionsConverter.messages(from: contents, stripImages: stripImages)

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
            if http.statusCode == 429 {
              throw TranscriptionError.rateLimited(retryAfter: nil)
            }
            throw TranscriptionError.networkError("OpenAI API error HTTP \(http.statusCode): \(text.prefix(500))")
          }

          // Parse SSE stream in Chat Completions format.
          // Keyed by the delta's `index` so we preserve emission order regardless of how many
          // parallel tool calls the model returns (a string-keyed dict with lexicographic sort
          // would put "10" before "2").
          var pendingToolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
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
                let key = index
                let toolID = tc["id"] as? String
                if let function = tc["function"] as? [String: Any] {
                  let existing = pendingToolCalls[key]
                  let updatedName = (function["name"] as? String) ?? existing?.name ?? ""
                  let updatedId = toolID ?? existing?.id ?? "call_\(key)"
                  var updatedArgs = existing?.arguments ?? ""
                  if let argChunk = function["arguments"] as? String {
                    updatedArgs += argChunk
                  }
                  pendingToolCalls[key] = (id: updatedId, name: updatedName, arguments: updatedArgs)
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

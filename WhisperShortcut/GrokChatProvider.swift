import Foundation

/// Grok/xAI implementation of `LLMChatProvider`.
/// Uses the Responses API (`/v1/responses`) with web+X search when grounding is
/// enabled, and falls back to Chat Completions (`/v1/chat/completions`) otherwise.
final class GrokChatProvider: LLMChatProvider {
  static let shared = GrokChatProvider()

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
      return sendViaResponsesAPI(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools)
    } else {
      return sendViaChatCompletions(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools)
    }
  }

  // MARK: - Responses API (with web_search + X search)

  /// Uses xAI's Responses API which supports built-in web and X.com search.
  /// SSE events follow the OpenAI Responses API format.
  private func sendViaResponsesAPI(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration]
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard let apiKey = KeychainManager.shared.getXAIAPIKey(), !apiKey.isEmpty else {
            throw TranscriptionError.networkError("No xAI API key configured. Add your xAI API key in Settings to use Grok models.")
          }

          let endpoint = "https://api.x.ai/v1/responses"
          guard let url = URL(string: endpoint) else {
            throw TranscriptionError.networkError("Invalid xAI endpoint URL")
          }

          var request = URLRequest(url: url)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
          request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
          request.timeoutInterval = 300

          // Build Responses API input from Gemini-format contents
          let input = Self.convertContentsToResponsesInput(contents, systemInstruction: systemInstruction)

          // System instruction
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
            "temperature": 0.7,
            "top_p": 0.95,
            "max_output_tokens": 8192,
          ]
          if let instructions = instructions {
            body["instructions"] = instructions
          }

          // Tools: web_search + x_search + custom function tools.
          // web_search searches the open web; x_search searches X.com posts.
          // Responses API uses a flat tool format (name/description at top level),
          // unlike Chat Completions which nests them under "function".
          var responsesTools: [[String: Any]] = [
            ["type": "web_search"],
            ["type": "x_search"],
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

          DebugLogger.logNetwork("GROK-RESPONSES: POST \(endpoint) model=\(model) tools=web_search+x_search+\(tools.count)func")
          let (bytes, response) = try await self.session.bytes(for: request)
          guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.networkError("Invalid response from xAI API")
          }
          if http.statusCode < 200 || http.statusCode >= 300 {
            var errData = Data()
            for try await b in bytes { errData.append(b) }
            let text = String(data: errData, encoding: .utf8) ?? ""
            DebugLogger.logError("GROK-RESPONSES: HTTP \(http.statusCode) body=\(text.prefix(500))")
            throw TranscriptionError.networkError("xAI API error HTTP \(http.statusCode): \(text)")
          }

          // Parse Responses API SSE stream.
          // Event format: "event: <type>\ndata: <json>\n\n"
          var pendingFunctionCalls: [(name: String, args: [String: Any])] = []
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
              // Complete function call — collect for emission after stream
              if let itemId = obj["item_id"] as? String {
                DebugLogger.logNetwork("GROK-RESPONSES: function_call done itemId=\(itemId)")
              }
              let argsString = obj["arguments"] as? String ?? "{}"
              // We need the function name — it was in the output_item.added event.
              // Store it via the pending map keyed by item_id.
              let itemId = obj["item_id"] as? String ?? ""
              if let existing = functionCallNames[itemId] {
                let args: [String: Any]
                if let d = argsString.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                  args = parsed
                } else {
                  args = [:]
                }
                pendingFunctionCalls.append((name: existing, args: args))
              }

            case "response.output_item.added":
              // Track function call names by item ID
              if let item = obj["item"] as? [String: Any],
                 let type = item["type"] as? String, type == "function_call",
                 let name = item["name"] as? String,
                 let itemId = item["id"] as? String {
                functionCallNames[itemId] = name
                DebugLogger.logNetwork("GROK-RESPONSES: function_call added name=\(name) id=\(itemId)")
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

          // Emit collected function calls
          for call in pendingFunctionCalls {
            DebugLogger.logNetwork("GROK-RESPONSES: functionCall name=\(call.name)")
            continuation.yield(.functionCall(name: call.name, args: call.args, thoughtSignature: nil))
          }

          DebugLogger.logNetwork("GROK-RESPONSES: stream end, finishReason=\(finishReason ?? "nil")")
          continuation.yield(.finished(sources: [], supports: [], finishReason: finishReason))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  // MARK: - Chat Completions API (without search)

  /// Uses the standard OpenAI-compatible Chat Completions endpoint.
  private func sendViaChatCompletions(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration]
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard let apiKey = KeychainManager.shared.getXAIAPIKey(), !apiKey.isEmpty else {
            throw TranscriptionError.networkError("No xAI API key configured. Add your xAI API key in Settings to use Grok models.")
          }

          let endpoint = "https://api.x.ai/v1/chat/completions"
          guard let url = URL(string: endpoint) else {
            throw TranscriptionError.networkError("Invalid xAI endpoint URL")
          }

          var request = URLRequest(url: url)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
          request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
          request.timeoutInterval = 300

          // Build OpenAI-format messages from Gemini-format contents
          var messages = Self.convertContentsToMessages(contents)

          // Prepend system message if provided
          if let sys = systemInstruction,
             let parts = sys["parts"] as? [[String: Any]],
             let text = parts.first?["text"] as? String, !text.isEmpty {
            messages.insert(["role": "system", "content": text], at: 0)
          }

          var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "temperature": 0.7,
            "top_p": 0.95,
            "max_tokens": 8192,
          ]

          // Add tools in OpenAI format if provided
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

          DebugLogger.logNetwork("GROK-CHAT-STREAM: POST \(endpoint) model=\(model)")
          let (bytes, response) = try await self.session.bytes(for: request)
          guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.networkError("Invalid response from xAI API")
          }
          if http.statusCode < 200 || http.statusCode >= 300 {
            var errData = Data()
            for try await b in bytes { errData.append(b) }
            let text = String(data: errData, encoding: .utf8) ?? ""
            DebugLogger.logError("GROK-CHAT-STREAM: HTTP \(http.statusCode) body=\(text.prefix(500))")
            throw TranscriptionError.networkError("xAI API error HTTP \(http.statusCode): \(text)")
          }

          // Parse SSE stream in OpenAI Chat Completions format.
          var pendingToolCalls: [String: (name: String, arguments: String)] = [:]
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

            // Text content
            if let content = delta["content"] as? String, !content.isEmpty {
              continuation.yield(.textDelta(content))
            }

            // Tool calls (streamed incrementally)
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
              for tc in toolCalls {
                let index = tc["index"] as? Int ?? 0
                let key = "\(index)"
                if let function = tc["function"] as? [String: Any] {
                  if let name = function["name"] as? String {
                    pendingToolCalls[key] = (name: name, arguments: "")
                  }
                  if let argChunk = function["arguments"] as? String {
                    if var existing = pendingToolCalls[key] {
                      existing.arguments += argChunk
                      pendingToolCalls[key] = existing
                    }
                  }
                }
              }
            }
          }

          // Emit collected tool calls
          for key in pendingToolCalls.keys.sorted() {
            guard let tc = pendingToolCalls[key] else { continue }
            let args: [String: Any]
            if let data = tc.arguments.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
              args = parsed
            } else {
              args = [:]
            }
            DebugLogger.logNetwork("GROK-CHAT-STREAM: functionCall name=\(tc.name)")
            continuation.yield(.functionCall(name: tc.name, args: args, thoughtSignature: nil))
          }

          DebugLogger.logNetwork("GROK-CHAT-STREAM: stream end, finishReason=\(finishReason ?? "nil")")
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

  /// Converts Gemini-format `contents` to Responses API `input` array.
  /// The Responses API uses the same message format as Chat Completions.
  static func convertContentsToResponsesInput(_ contents: [[String: Any]], systemInstruction: [String: Any]?) -> [[String: Any]] {
    // Responses API input is the same format as Chat Completions messages
    return convertContentsToMessages(contents)
  }

  /// Converts Gemini-format `contents` (role/parts dicts) to OpenAI-format `messages`.
  static func convertContentsToMessages(_ contents: [[String: Any]]) -> [[String: Any]] {
    var messages: [[String: Any]] = []
    for content in contents {
      guard let role = content["role"] as? String,
            let parts = content["parts"] as? [[String: Any]] else { continue }

      let openAIRole: String
      switch role {
      case "model": openAIRole = "assistant"
      case "user": openAIRole = "user"
      default: openAIRole = role
      }

      // Check for function call parts (model turn with tool calls)
      let functionCallParts = parts.filter { $0["functionCall"] != nil }
      if !functionCallParts.isEmpty {
        var toolCalls: [[String: Any]] = []
        for (idx, part) in functionCallParts.enumerated() {
          guard let fc = part["functionCall"] as? [String: Any],
                let name = fc["name"] as? String else { continue }
          let args = fc["args"] as? [String: Any] ?? [:]
          let argsJSON = (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
          toolCalls.append([
            "id": "call_\(idx)",
            "type": "function",
            "function": [
              "name": name,
              "arguments": argsJSON,
            ] as [String: Any],
          ])
        }
        // Also include any text in the same turn
        let textParts = parts.compactMap { $0["text"] as? String }.joined()
        var msg: [String: Any] = ["role": "assistant", "tool_calls": toolCalls]
        if !textParts.isEmpty { msg["content"] = textParts }
        messages.append(msg)
        continue
      }

      // Check for function response parts (user turn with tool results)
      let functionResponseParts = parts.filter { $0["functionResponse"] != nil }
      if !functionResponseParts.isEmpty {
        for (idx, part) in functionResponseParts.enumerated() {
          guard let fr = part["functionResponse"] as? [String: Any],
                let resp = fr["response"] as? [String: Any] else { continue }
          let respJSON = (try? JSONSerialization.data(withJSONObject: resp))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
          messages.append([
            "role": "tool",
            "tool_call_id": "call_\(idx)",
            "content": respJSON,
          ])
        }
        continue
      }

      // Regular text + image parts
      let textParts = parts.compactMap { $0["text"] as? String }
      let imageParts = parts.filter { $0["inline_data"] != nil }

      if !imageParts.isEmpty {
        // Multi-modal: use content array format
        var contentArray: [[String: Any]] = []
        for part in parts {
          if let text = part["text"] as? String {
            contentArray.append(["type": "text", "text": text])
          } else if let inlineData = part["inline_data"] as? [String: Any],
                    let mimeType = inlineData["mime_type"] as? String,
                    let data = inlineData["data"] as? String {
            contentArray.append([
              "type": "image_url",
              "image_url": ["url": "data:\(mimeType);base64,\(data)"],
            ])
          }
        }
        messages.append(["role": openAIRole, "content": contentArray])
      } else {
        let joined = textParts.joined()
        if !joined.isEmpty {
          messages.append(["role": openAIRole, "content": joined])
        }
      }
    }
    return messages
  }
}

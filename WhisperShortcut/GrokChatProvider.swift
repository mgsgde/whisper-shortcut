import Foundation

/// Grok/xAI implementation of `LLMChatProvider`.
/// Uses the Responses API (`/v1/responses`) with web+X search when grounding is
/// enabled, and falls back to Chat Completions (`/v1/chat/completions`) otherwise.
final class GrokChatProvider: LLMChatProvider {
  static let shared = GrokChatProvider()

  private var session: URLSession { LLMHTTPSession.shared }

  private init() {}

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    useGrounding: Bool,
    thinkingLevel: ThinkingLevel,
    disableBuiltInTools: Bool  // Grok doesn't auto-enable built-in tools here; ignored.
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    if let attachmentError = Self.validateAttachments(in: contents) {
      return AsyncThrowingStream { $0.finish(throwing: attachmentError) }
    }
    if useGrounding {
      return sendViaResponsesAPI(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools, thinkingLevel: thinkingLevel)
    } else {
      return sendViaChatCompletions(model: model, contents: contents, systemInstruction: systemInstruction, tools: tools, thinkingLevel: thinkingLevel)
    }
  }

  /// xAI's Grok API only accepts image attachments. Reject PDFs and other
  /// non-image MIME types up front with a clear message — otherwise xAI tries
  /// to base64-decode them as images and returns "Invalid base64-encoded image."
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
      "Grok only supports image attachments — \(types) isn't supported. Switch to a Gemini model to chat about PDFs and documents."
    )
  }

  // MARK: - Responses API (with web_search + X search)

  /// Uses xAI's Responses API which supports built-in web and X.com search.
  /// SSE events follow the OpenAI Responses API format.
  private func sendViaResponsesAPI(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    thinkingLevel: ThinkingLevel
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

          // Build Responses API input from Gemini-format contents (shared with OpenAI).
          let input = OpenAIResponsesAPIConverter.input(from: contents)

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

          // Tools: web_search + custom function tools.
          // Only web_search is enabled — x_search (X.com posts) was dropped because
          // it added latency without improving factual grounding for typical chat
          // questions and tended to surface opinion over fact.
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

          // Per-session `/think` override → Responses API nested `reasoning.effort`.
          if let effort = thinkingLevel.grokReasoningEffort {
            body["reasoning"] = ["effort": effort]
          }

          request.httpBody = try JSONSerialization.data(withJSONObject: body)

          DebugLogger.logNetwork("GROK-RESPONSES: POST \(endpoint) model=\(model) tools=web_search+\(tools.count)func effort=\(thinkingLevel.grokReasoningEffort ?? "default")")
          let (bytes, response) = try await self.session.bytes(for: request)
          guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.networkError("Invalid response from xAI API")
          }
          if http.statusCode < 200 || http.statusCode >= 300 {
            var errData = Data()
            for try await b in bytes { errData.append(b) }
            let text = String(data: errData, encoding: .utf8) ?? ""
            DebugLogger.logError("GROK-RESPONSES: HTTP \(http.statusCode) body=\(text.prefix(500))")
            if http.statusCode == 401 {
              throw TranscriptionError.networkError("xAI API key is invalid. Check the key in Settings → Chat.")
            }
            if http.statusCode == 429 {
              throw Self.classifyXAI429(body: text)
            }
            throw TranscriptionError.networkError("xAI API error HTTP \(http.statusCode): \(text.prefix(500))")
          }

          // Parse Responses API SSE stream.
          // Event format: "event: <type>\ndata: <json>\n\n"
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
                pendingFunctionCalls.append((name: existing, args: args, callId: itemId))
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

          // Emit collected function calls (pass callId via thoughtSignature for round-trip)
          for call in pendingFunctionCalls {
            DebugLogger.logNetwork("GROK-RESPONSES: functionCall name=\(call.name) callId=\(call.callId)")
            continuation.yield(.functionCall(name: call.name, args: call.args, thoughtSignature: call.callId))
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
    tools: [LLMToolDeclaration],
    thinkingLevel: ThinkingLevel
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

          // Build OpenAI-format messages from Gemini-format contents.
          // xAI's API is OpenAI-Chat-Completions-compatible, so this is the same
          // translator OpenAIChatProvider uses.
          var messages = OpenAIChatCompletionsConverter.messages(from: contents)

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

          // Per-session `/think` override → Chat Completions top-level `reasoning_effort`.
          if let effort = thinkingLevel.grokReasoningEffort {
            body["reasoning_effort"] = effort
          }

          request.httpBody = try JSONSerialization.data(withJSONObject: body)

          DebugLogger.logNetwork("GROK-CHAT-STREAM: POST \(endpoint) model=\(model) effort=\(thinkingLevel.grokReasoningEffort ?? "default")")
          let (bytes, response) = try await self.session.bytes(for: request)
          guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.networkError("Invalid response from xAI API")
          }
          if http.statusCode < 200 || http.statusCode >= 300 {
            var errData = Data()
            for try await b in bytes { errData.append(b) }
            let text = String(data: errData, encoding: .utf8) ?? ""
            DebugLogger.logError("GROK-CHAT-STREAM: HTTP \(http.statusCode) body=\(text.prefix(500))")
            if http.statusCode == 401 {
              throw TranscriptionError.networkError("xAI API key is invalid. Check the key in Settings → Chat.")
            }
            if http.statusCode == 429 {
              throw Self.classifyXAI429(body: text)
            }
            throw TranscriptionError.networkError("xAI API error HTTP \(http.statusCode): \(text.prefix(500))")
          }

          // Parse SSE stream in OpenAI Chat Completions format.
          // Keyed by the delta's `index` (Int, not String) so emission order survives
          // double-digit parallel tool calls — a string-keyed dict with lexicographic
          // sort would put "10" before "2".
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

            // Text content
            if let content = delta["content"] as? String, !content.isEmpty {
              continuation.yield(.textDelta(content))
            }

            // Tool calls (streamed incrementally). Merge name/args without clobbering
            // any in-flight accumulator if `name` arrives mid-stream.
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

          // Emit collected tool calls. Round-trip `tool_call.id` via `thoughtSignature`
          // so the message-loop's tool-response turn preserves the link.
          for key in pendingToolCalls.keys.sorted() {
            guard let tc = pendingToolCalls[key], !tc.name.isEmpty else { continue }
            let args: [String: Any]
            if let data = tc.arguments.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
              args = parsed
            } else {
              args = [:]
            }
            DebugLogger.logNetwork("GROK-CHAT-STREAM: functionCall name=\(tc.name) id=\(tc.id)")
            continuation.yield(.functionCall(name: tc.name, args: args, thoughtSignature: tc.id))
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

  /// Maps an xAI HTTP 429 body to a specific error. xAI returns 429 both for transient
  /// rate limits and for permanent "credits exhausted / monthly spending limit" — the
  /// second is not solved by waiting, so it gets its own actionable message instead of
  /// the generic `.rateLimited` (which would tell the user to "wait and try again").
  private static func classifyXAI429(body: String) -> TranscriptionError {
    let lower = body.lowercased()
    // Substring matches mirror xAI error wording observed in 2026-05; xAI may change
    // these phrases without notice, in which case we silently fall back to the generic
    // rate-limit message (the worst case is the current behaviour, not a new bug).
    let exhausted = lower.contains("some resource has been exhausted")
      || lower.contains("monthly spending limit")
      || lower.contains("available credits")
    if exhausted {
      return TranscriptionError.networkError(
        "xAI account is out of credits or has reached its monthly spending limit. Top up or raise the limit at https://console.x.ai/ to continue.")
    }
    return TranscriptionError.rateLimited(retryAfter: nil)
  }
}

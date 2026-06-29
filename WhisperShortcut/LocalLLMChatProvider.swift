import Foundation

/// Local implementation of `LLMChatProvider` for an OpenAI-compatible server running on the
/// user's machine (Ollama, LM Studio, or any `/v1/chat/completions`-compatible backend).
///
/// Mirrors `GrokChatProvider.sendViaChatCompletions` (xAI is OpenAI-compatible too), but:
///   - the endpoint is read from `LocalLLMPreferences` instead of being hardcoded,
///   - no API key / auth header is sent (local servers don't require one), and
///   - a refused connection is mapped to an actionable "is the server running?" message.
///
/// Phase 1 wires this provider for Dictate Prompt (text-only, no tools). Tool calling is parsed
/// here as well so the chat path can be enabled later without changes to the provider.
final class LocalLLMChatProvider: LLMChatProvider {
  static let shared = LocalLLMChatProvider()

  private var session: URLSession { LLMHTTPSession.shared }

  private init() {}

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    useGrounding: Bool,  // No web-search path for local models; ignored.
    thinkingLevel: ThinkingLevel,  // Local servers don't expose a standard reasoning knob; ignored.
    disableBuiltInTools: Bool,  // No built-in tools on local servers; ignored.
    cacheKey: String?  // No server-side prompt cache hint; ignored.
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let endpoint = LocalLLMPreferences.chatCompletionsURL
          guard let url = URL(string: endpoint) else {
            throw TranscriptionError.networkError(
              "Invalid local endpoint URL: \(endpoint). Set a valid base URL (e.g. http://localhost:11434/v1) in Dictate Prompt settings.")
          }

          var request = URLRequest(url: url)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
          request.timeoutInterval = 300

          // Build OpenAI-format messages from Gemini-format contents (shared translator).
          var messages = OpenAIChatCompletionsConverter.messages(from: contents)
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
          if !tools.isEmpty {
            body["tools"] = tools.map { tool in
              [
                "type": "function",
                "function": [
                  "name": tool.name,
                  "description": tool.description,
                  "parameters": tool.parameters,
                ] as [String: Any],
              ]
            }
          }

          request.httpBody = try JSONSerialization.data(withJSONObject: body)

          DebugLogger.logNetwork("LOCAL-CHAT-STREAM: POST \(endpoint) model=\(model) tools=\(tools.count)")
          let (bytes, response): (URLSession.AsyncBytes, URLResponse)
          do {
            (bytes, response) = try await self.session.bytes(for: request)
          } catch {
            throw Self.mapConnectionError(error, endpoint: endpoint)
          }
          guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.networkError("Invalid response from local LLM server")
          }
          if http.statusCode < 200 || http.statusCode >= 300 {
            var errData = Data()
            for try await b in bytes { errData.append(b) }
            let text = String(data: errData, encoding: .utf8) ?? ""
            DebugLogger.logError("LOCAL-CHAT-STREAM: HTTP \(http.statusCode) body=\(text.prefix(500))")
            if http.statusCode == 404 {
              throw TranscriptionError.networkError(
                "Local server returned 404 for model \"\(model)\". Pull/select the model first (e.g. `ollama pull \(model)`) or fix the model id in Dictate Prompt settings.")
            }
            throw TranscriptionError.networkError("Local LLM server error HTTP \(http.statusCode): \(text.prefix(500))")
          }

          // Parse SSE stream in OpenAI Chat Completions format. Keyed by `index` so emission
          // order survives double-digit parallel tool calls (mirrors GrokChatProvider).
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

          for key in pendingToolCalls.keys.sorted() {
            guard let tc = pendingToolCalls[key], !tc.name.isEmpty else { continue }
            let args: [String: Any]
            if let data = tc.arguments.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
              args = parsed
            } else {
              args = [:]
            }
            DebugLogger.logNetwork("LOCAL-CHAT-STREAM: functionCall name=\(tc.name) id=\(tc.id)")
            continuation.yield(.functionCall(name: tc.name, args: args, thoughtSignature: tc.id))
          }

          DebugLogger.logNetwork("LOCAL-CHAT-STREAM: stream end, finishReason=\(finishReason ?? "nil")")
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
    // Not used by the local Dictate Prompt path. Smart Improvement / structured features stay on
    // cloud models for now; implement via OpenAICompatibleStructured if local structured output is
    // needed later.
    throw TranscriptionError.networkError("Structured output is not supported for local models yet.")
  }

  /// Turns a connection-refused / host-unreachable URLError into an actionable message instead of
  /// the opaque default ("Could not connect to the server").
  private static func mapConnectionError(_ error: Error, endpoint: String) -> Error {
    if let urlError = error as? URLError,
       urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost
        || urlError.code == .networkConnectionLost || urlError.code == .timedOut {
      return TranscriptionError.networkError(
        "Can't reach the local LLM server at \(endpoint). Start it (e.g. run `ollama serve` / open LM Studio) or fix the endpoint in Dictate Prompt settings.")
    }
    return error
  }
}

import Foundation
import MLXLLM
import MLXLMCommon

/// In-process local LLM via MLX. Same `LLMChatProvider` seam as Ollama/LM Studio, but no HTTP.
final class MLXChatProvider: LLMChatProvider {
  static let shared = MLXChatProvider()

  /// Sessions (by `ChatRequestOptions.cacheKey`) already shown the no-tools notice.
  private let noticeLock = NSLock()
  private var sessionsToldNoTools = Set<String>()

  /// Shown once per chat session, in the reply, so the user is not left guessing why
  /// `/folder` or Gmail tools do nothing.
  static let noToolsNotice =
    "On-device MLX chat cannot use tools in this session (Gmail, Calendar, Trello, workspace files, and similar). Ask in plain language instead.\n\n"

  private init() {}

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    options: ChatRequestOptions
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    // Tools are not declared for `.localMLX` (`ChatToolRegistry`); if any slip through, drop
    // them rather than pretending a function call will run.
    if !tools.isEmpty {
      DebugLogger.logWarning(
        "MLX-CHAT-STREAM: ignoring \(tools.count) tool(s) — in-process MLX has no tool-calling path")
    }

    let systemText = Self.plainText(from: systemInstruction)
    let messages = Self.chatMessages(from: contents)
    // One key space: `model` is always a `PromptModel` rawValue, the same string every other
    // provider receives. Accepting a Hugging Face id here as well meant two callers could pass
    // two different spellings of the same model and only one of them would ever be wrong.
    guard let mlxType = PromptModel(rawValue: model)?.localMLXModelType else {
      return AsyncThrowingStream { continuation in
        continuation.finish(
          throwing: TranscriptionError.networkError(
            "Unknown MLX model \"\(model)\". Pick an offline MLX model in Settings."))
      }
    }

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          if shouldAnnounceNoTools(sessionKey: options.cacheKey) {
            continuation.yield(.textDelta(Self.noToolsNotice))
          }
          // Readiness lives here, not in the callers: every path that reaches this provider needs
          // the weights on disk and in RAM, and the title stays neutral because both Chat and
          // Dictate Prompt come through. A 2.3 GB first download must not look like a hang.
          try await LocalLLMModelManager.shared.ensureReadyWithUI(mlxType, title: "Offline Model")
          let container = try await LocalLLMModelManager.shared.container(for: mlxType)
          var parameters = GenerateParameters()
          parameters.maxTokens = AppConstants.localPromptMaxOutputTokens
          // Through the in-memory prefix cache: the Dictate Prompt system prompt runs past a
          // thousand tokens, and re-prefilling it per request was the entire measured gap to the
          // local HTTP server. `MLXPromptCache` prefills it once and hands each request fresh
          // cache objects around the same arrays. Falls back to a plain session on any failure.
          let session = await MLXPromptCache.shared.session(
            container: container,
            modelID: mlxType.huggingFaceID,
            systemPrompt: systemText,
            parameters: parameters,
            additionalContext: ["enable_thinking": false])
          DebugLogger.logNetwork(
            "MLX-CHAT-STREAM: model=\(mlxType.huggingFaceID) turns=\(messages.count)")
          for try await chunk in session.streamResponse(to: messages) {
            try Task.checkCancellation()
            if !chunk.isEmpty {
              continuation.yield(.textDelta(chunk))
            }
          }
          continuation.yield(.finished(sources: [], supports: [], finishReason: "stop"))
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func shouldAnnounceNoTools(sessionKey: String?) -> Bool {
    guard let sessionKey, !sessionKey.isEmpty else { return false }
    noticeLock.lock()
    defer { noticeLock.unlock() }
    return sessionsToldNoTools.insert(sessionKey).inserted
  }

  func generateStructured(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    schema: [String: Any],
    schemaName: String,
    thinkingLevel: ThinkingLevel
  ) async throws -> [String: Any] {
    throw TranscriptionError.networkError(
      "Structured output is not supported for the in-process MLX model yet.")
  }

  /// Gemini-format `parts` → a single string. Image/audio parts are ignored (text-only).
  private static func plainText(from block: [String: Any]?) -> String? {
    guard let parts = block?["parts"] as? [[String: Any]] else { return nil }
    let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func chatMessages(from contents: [[String: Any]]) -> [MLXLMCommon.Chat.Message] {
    contents.compactMap { turn in
      let text = plainText(from: turn) ?? ""
      guard !text.isEmpty else { return nil }
      let role = (turn["role"] as? String) ?? "user"
      switch role {
      case "model", "assistant":
        return .assistant(text)
      case "system":
        return .system(text)
      default:
        return .user(text)
      }
    }
  }
}

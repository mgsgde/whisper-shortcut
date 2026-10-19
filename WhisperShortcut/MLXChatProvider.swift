import Foundation
import MLXLLM
import MLXLMCommon

/// In-process local LLM via MLX. Same `LLMChatProvider` seam as Ollama/LM Studio, but no HTTP.
final class MLXChatProvider: LLMChatProvider {
  static let shared = MLXChatProvider()

  /// Milliseconds the most recent request spent loading or preparing the model container.
  /// 0 when it was already in memory. Dictate Prompt reads this after `sendChatStream` returns.
  private let loadMsLock = NSLock()
  private var recordedLoadMs = 0
  var lastLoadMs: Int {
    loadMsLock.lock()
    defer { loadMsLock.unlock() }
    return recordedLoadMs
  }

  private init() {}

  /// Chat-template variables for every MLX request. Part of the prompt-cache key, so a change
  /// here cannot reuse a prefix rendered under the old context.
  static let templateContext: [String: any Sendable] = ["enable_thinking": false]

  /// The one recipe for an MLX request. The prewarmer primes the prompt cache with it and the real
  /// request reuses that cache, so the two must build the same template context — a primed prefix
  /// rendered under a different context would be silently wrong output.
  static func promptSession(
    container: ModelContainer, type: LocalLLMModelType, systemPrompt: String?,
    reusePrefix: Bool, temperature: Double?
  ) async -> MLXLMCommon.ChatSession {
    var parameters = GenerateParameters()
    parameters.maxTokens = AppConstants.localPromptMaxOutputTokens
    // MLX samples at 0.6 by default; 0 selects the argmax sampler (no RNG at all).
    if let temperature {
      parameters.temperature = Float(temperature)
    }
    return await MLXPromptCache.shared.session(
      container: container,
      modelID: type.huggingFaceID,
      systemPrompt: systemPrompt,
      reusePrefix: reusePrefix,
      parameters: parameters,
      additionalContext: templateContext)
  }

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    options: ChatRequestOptions
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    // Of these only `reusablePromptPrefix` and `temperature` apply: an in-process model has no web search, no
    // server-side prompt cache, and no reasoning knob of its own — thinking is switched off
    // through the chat template below.
    let mayReusePrefix = options.reusablePromptPrefix
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
          // Readiness lives here, not in the callers: every path that reaches this provider needs
          // the weights on disk and in RAM, and the title stays neutral because both Chat and
          // Dictate Prompt come through. A 2.3 GB first download must not look like a hang.
          // `lastLoadMs` is this request's prepare time (download + weight load). A container
          // that is already resident reports 0 — the follow-up `container(for:)` would otherwise
          // look like a fresh load of a few milliseconds.
          let resident = await LocalLLMModelManager.shared.isContainerLoaded(mlxType)
          let loadStarted = ContinuousClock.now
          if options.showsModelReadinessPopup {
            try await LocalLLMModelManager.shared.ensureReadyWithUI(mlxType, title: "Offline Model")
          } else {
            try await LocalLLMModelManager.shared.ensureReady(mlxType)
          }
          let container = try await LocalLLMModelManager.shared.container(for: mlxType)
          let loadMs = resident ? 0 : Self.milliseconds(since: loadStarted)
          recordLoadMs(loadMs)
          // Through the in-memory prefix cache: the Dictate Prompt system prompt runs past a
          // thousand tokens, and re-prefilling it per request was the entire measured gap to the
          // local HTTP server. `MLXPromptCache` prefills it once and hands each request fresh
          // cache objects around the same arrays. Falls back to a plain session on any failure.
          let session = await Self.promptSession(
            container: container, type: mlxType, systemPrompt: systemText,
            reusePrefix: mayReusePrefix, temperature: options.temperature)
          DebugLogger.logNetwork(
            "MLX-CHAT-STREAM: model=\(mlxType.huggingFaceID) turns=\(messages.count)")
          for try await chunk in session.streamResponse(to: messages) {
            try Task.checkCancellation()
            if !chunk.isEmpty {
              continuation.yield(.textDelta(chunk))
            }
          }
          continuation.yield(.finished(sources: [], supports: [], finishReason: "stop"))
          ModelSelectionReconciler.adoptKeylessOfflineFallbacks()
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

  private func recordLoadMs(_ ms: Int) {
    loadMsLock.lock()
    recordedLoadMs = ms
    loadMsLock.unlock()
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let ms = start.duration(to: ContinuousClock.now) / .milliseconds(1)
    return Int(ms.rounded())
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

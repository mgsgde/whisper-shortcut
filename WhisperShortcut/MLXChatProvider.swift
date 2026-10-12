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
    // Of these only `reusablePromptPrefix` applies: an in-process model has no web search, no
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
          if shouldAnnounceNoTools(sessionKey: options.cacheKey) {
            continuation.yield(.textDelta(Self.noToolsNotice))
          }
          // Through the in-memory prefix cache: the Dictate Prompt system prompt runs past a
          // thousand tokens, and re-prefilling it per request was the entire measured gap to the
          // local HTTP server. `MLXPromptCache` prefills it once and hands each request fresh
          // cache objects around the same arrays. Falls back to a plain session on any failure.
          let session = try await Self.readySession(
            mlxType: mlxType, systemText: systemText, maxTokens: AppConstants.localPromptMaxOutputTokens,
            reusePrefix: mayReusePrefix)
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

  private func shouldAnnounceNoTools(sessionKey: String?) -> Bool {
    guard let sessionKey, !sessionKey.isEmpty else { return false }
    noticeLock.lock()
    defer { noticeLock.unlock() }
    return sessionsToldNoTools.insert(sessionKey).inserted
  }

  /// Smart Improvement running on the in-process MLX model. MLX has no constrained-decoding /
  /// `response_format` support, so the schema is appended to the system prompt as plain
  /// instructions instead of enforced by the server. A small model occasionally answers with
  /// prose or a code fence anyway, so a bad first reply gets one retry with an extra turn asking
  /// for JSON only before this gives up.
  func generateStructured(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    schema: [String: Any],
    schemaName: String,
    thinkingLevel: ThinkingLevel
  ) async throws -> [String: Any] {
    guard let mlxType = PromptModel(rawValue: model)?.localMLXModelType else {
      throw TranscriptionError.networkError(
        "Unknown MLX model \"\(model)\". Pick an offline MLX model in Settings.")
    }
    let systemText = [Self.plainText(from: systemInstruction), Self.schemaInstruction(schema: schema, schemaName: schemaName)]
      .compactMap { $0 }
      .joined(separator: "\n\n")
    var messages = Self.chatMessages(from: contents)
    let requiredKeys = (schema["required"] as? [String]) ?? []

    DebugLogger.logNetwork("MLX-STRUCTURED: model=\(mlxType.huggingFaceID) schema=\(schemaName)")

    let firstReply = try await Self.generateFullReply(
      mlxType: mlxType, systemText: systemText, messages: messages, reusePrefix: false)
    if let parsed = Self.validatedObject(from: firstReply, requiredKeys: requiredKeys) {
      return parsed
    }

    DebugLogger.logWarning(
      "MLX-STRUCTURED: first reply was not valid JSON for schema \(schemaName) — retrying once")
    messages.append(.assistant(firstReply))
    messages.append(
      .user("That reply was not valid JSON for the requested schema. Answer again with only the JSON object — no prose, no code fence."))
    let secondReply = try await Self.generateFullReply(
      mlxType: mlxType, systemText: systemText, messages: messages, reusePrefix: false)
    if let parsed = Self.validatedObject(from: secondReply, requiredKeys: requiredKeys) {
      return parsed
    }

    DebugLogger.logError("MLX-STRUCTURED: second reply was not valid JSON for schema \(schemaName) either — giving up")
    throw TranscriptionError.networkError(
      "The offline model did not return valid structured output. Try again, or pick a larger model for Smart Improvement.")
  }

  /// Instructs the model to reply with only the JSON object matching `schema`, serialized
  /// alongside the instruction so the model can read its exact shape.
  private static func schemaInstruction(schema: [String: Any], schemaName: String) -> String? {
    guard let schemaData = try? JSONSerialization.data(
      withJSONObject: schema, options: [.prettyPrinted, .sortedKeys]),
      let schemaText = String(data: schemaData, encoding: .utf8) else {
      return nil
    }
    return """
      Reply with ONLY one JSON object named "\(schemaName)" that matches this JSON Schema — no \
      prose, no code fence, nothing before or after the object:

      \(schemaText)
      """
  }

  /// Parses `reply` and checks every key the schema's `required` array lists is present. nil on
  /// either failure, so the caller treats "not JSON" and "missing a required field" the same way.
  private static func validatedObject(from reply: String, requiredKeys: [String]) -> [String: Any]? {
    guard let parsed = StructuredJSONExtractor.object(from: reply) else { return nil }
    guard requiredKeys.allSatisfy({ parsed[$0] != nil }) else { return nil }
    return parsed
  }

  /// Builds a ready-to-use MLX chat session: ensures the weights are on disk/RAM, resolves the
  /// model container, and primes (or reuses) the prompt-cache session. Shared by `sendChatStream`
  /// (which streams the reply incrementally) and `generateStructured` (which needs the whole
  /// reply before it can parse it) so the readiness/container/cache plumbing exists once.
  private static func readySession(
    mlxType: LocalLLMModelType, systemText: String?, maxTokens: Int, reusePrefix: Bool
  ) async throws -> MLXLMCommon.ChatSession {
    // Readiness lives here, not in the callers: every path that reaches this provider needs
    // the weights on disk and in RAM, and the title stays neutral because both Chat and
    // Dictate Prompt come through. A 2.3 GB first download must not look like a hang.
    try await LocalLLMModelManager.shared.ensureReadyWithUI(mlxType, title: "Offline Model")
    let container = try await LocalLLMModelManager.shared.container(for: mlxType)
    var parameters = GenerateParameters()
    parameters.maxTokens = maxTokens
    return await MLXPromptCache.shared.session(
      container: container,
      modelID: mlxType.huggingFaceID,
      systemPrompt: systemText,
      reusePrefix: reusePrefix,
      parameters: parameters,
      additionalContext: ["enable_thinking": false])
  }

  /// One full (non-streaming) generation turn, for callers that need the whole reply before they
  /// can use it (`generateStructured`'s JSON parse).
  private static func generateFullReply(
    mlxType: LocalLLMModelType, systemText: String?, messages: [MLXLMCommon.Chat.Message],
    reusePrefix: Bool
  ) async throws -> String {
    let session = try await readySession(
      mlxType: mlxType, systemText: systemText,
      maxTokens: AppConstants.localStructuredMaxOutputTokens, reusePrefix: reusePrefix)
    var reply = ""
    for try await chunk in session.streamResponse(to: messages) {
      try Task.checkCancellation()
      reply += chunk
    }
    return reply
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

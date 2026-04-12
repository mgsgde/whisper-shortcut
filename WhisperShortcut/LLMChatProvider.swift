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
    }
  }
}

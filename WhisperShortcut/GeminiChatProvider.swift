import Foundation

/// Gemini implementation of `LLMChatProvider`.
/// Delegates to `GeminiAPIClient.sendChatMessageStream()` and translates
/// `LLMToolDeclaration` to Gemini's native function declaration format.
final class GeminiChatProvider: LLMChatProvider {
  static let shared = GeminiChatProvider()

  private let apiClient = GeminiAPIClient()
  private init() {}

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    useGrounding: Bool
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard let credential = await GeminiCredentialProvider.shared.getCredential() else {
            throw TranscriptionError.networkError("No Gemini credential available. Add your Google API key in Settings or sign in with Google.")
          }
          let geminiFuncDecls = tools.map { tool -> [String: Any] in
            [
              "name": tool.name,
              "description": tool.description,
              "parameters": tool.parameters,
            ]
          }
          let stream = self.apiClient.sendChatMessageStream(
            model: model,
            contents: contents,
            credential: credential,
            useGrounding: useGrounding,
            systemInstruction: systemInstruction,
            functionDeclarations: geminiFuncDecls)
          for try await event in stream {
            try Task.checkCancellation()
            // GeminiAPIClient.GeminiStreamEvent → top-level ChatStreamEvent
            switch event {
            case .textDelta(let text):
              continuation.yield(.textDelta(text))
            case .functionCall(let name, let args, let sig):
              continuation.yield(.functionCall(name: name, args: args, thoughtSignature: sig))
            case .finished(let sources, let supports, let reason):
              continuation.yield(.finished(sources: sources, supports: supports, finishReason: reason))
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }
}

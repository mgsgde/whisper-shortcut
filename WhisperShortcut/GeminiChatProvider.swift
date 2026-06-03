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
    useGrounding: Bool,
    thinkingLevel: ThinkingLevel,
    disableBuiltInTools: Bool,
    cacheKey: String?  // Gemini caches implicitly (no per-request key); ignored.
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard let credential = await GeminiCredentialProvider.shared.getCredential() else {
            throw TranscriptionError.networkError("No Gemini credential available. Add your Google API key in Settings or sign in with Google.")
          }
          // Native image-generation models ("Nano Banana") don't stream and ignore
          // tools/grounding/thinking — route them through a single :generateContent call with
          // responseModalities IMAGE. The returned text carries any image as a ⟦GEMINI_IMG:…⟧
          // marker (rendered inline by ChatView). Yield it as one delta, then finish.
          if PromptModel(rawValue: model)?.generatesImages == true {
            let text = try await self.apiClient.generateImageContent(
              model: model, contents: contents, credential: credential)
            try Task.checkCancellation()
            if !text.isEmpty {
              continuation.yield(.textDelta(text))
            }
            continuation.yield(.finished(sources: [], supports: [], finishReason: "STOP"))
            continuation.finish()
            return
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
            functionDeclarations: geminiFuncDecls,
            thinkingLevel: thinkingLevel,
            disableBuiltInTools: disableBuiltInTools)
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

  func generateStructured(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    schema: [String: Any],
    schemaName: String,  // Gemini doesn't name schemas; ignored.
    thinkingLevel: ThinkingLevel  // Structured tasks use the model's default thinking; ignored.
  ) async throws -> [String: Any] {
    guard let credential = await GeminiCredentialProvider.shared.getCredential() else {
      throw TranscriptionError.networkError("No Gemini credential available. Add your Google API key in Settings or sign in with Google.")
    }
    return try await apiClient.generateStructured(
      model: model,
      contents: contents,
      systemInstruction: systemInstruction,
      schema: schema,
      credential: credential)
  }
}

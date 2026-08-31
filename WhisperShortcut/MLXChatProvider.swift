import Foundation
import MLXLLM
import MLXLMCommon

/// In-process local LLM via MLX. Same `LLMChatProvider` seam as Ollama/LM Studio, but no HTTP.
///
/// Slice 1: one hardcoded model, no Settings UI. Flip on with
/// `defaults write com.magnusgoedde.whispershortcut useInProcessMLX -bool true`
/// (the non-sandboxed Debug build) so Dictate Prompt can be timed against the HTTP path.
final class MLXChatProvider: LLMChatProvider {
  static let shared = MLXChatProvider()

  /// Hardcoded Slice 1 catalogue entry. Slice 2 replaces this with `LocalLLMModelType`.
  static let hardcodedModelID = "mlx-community/Qwen3-4B-4bit"

  private let loader = MLXModelLoader()

  private init() {}

  func sendChatStream(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    tools: [LLMToolDeclaration],
    options: ChatRequestOptions
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    _ = model
    _ = tools
    _ = options
    let systemText = Self.plainText(from: systemInstruction)
    let messages = Self.chatMessages(from: contents)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let container = try await self.loader.container()
          var parameters = GenerateParameters()
          parameters.maxTokens = AppConstants.localPromptMaxOutputTokens
          let session = MLXLMCommon.ChatSession(
            container,
            instructions: systemText,
            generateParameters: parameters,
            additionalContext: ["enable_thinking": false])
          DebugLogger.logNetwork("MLX-CHAT-STREAM: model=\(Self.hardcodedModelID) turns=\(messages.count)")
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

  func generateStructured(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    schema: [String: Any],
    schemaName: String,
    thinkingLevel: ThinkingLevel
  ) async throws -> [String: Any] {
    throw TranscriptionError.networkError("Structured output is not supported for the in-process MLX model yet.")
  }

  /// Gemini-format `parts` → a single string. Image/audio parts are ignored (text-only Slice 1).
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

/// Owns the loaded MLX model. Join-in-flight so two Dictate Prompts don't start two downloads.
actor MLXModelLoader {
  private var loaded: ModelContainer?
  private var inFlight: Task<ModelContainer, Error>?

  func container() async throws -> ModelContainer {
    if let loaded { return loaded }
    if let inFlight {
      return try await inFlight.value
    }
    let task = Task {
      DebugLogger.log("MLX: loading \(MLXChatProvider.hardcodedModelID)")
      let context = try await loadModel(
        from: TransformersHubDownloader(),
        using: TransformersTokenizerLoader(),
        id: MLXChatProvider.hardcodedModelID
      ) { progress in
        let pct = Int(progress.fractionCompleted * 100)
        if pct % 10 == 0 {
          DebugLogger.log("MLX: download \(pct)%")
        }
      }
      DebugLogger.log("MLX: ready \(MLXChatProvider.hardcodedModelID)")
      return ModelContainer(context: context)
    }
    inFlight = task
    do {
      let value = try await task.value
      loaded = value
      inFlight = nil
      return value
    } catch {
      inFlight = nil
      throw error
    }
  }
}

import Foundation
import Hub
import MLXLMCommon
import Tokenizers

/// Adapts Hugging Face `HubApi` (swift-transformers 1.1.9) to mlx-swift-lm's `Downloader`.
///
/// mlx-swift-lm 3.x no longer depends on swift-transformers; the mapping is the documented
/// "few properties and methods" path, written against the version WhisperKit already resolved.
struct TransformersHubDownloader: MLXLMCommon.Downloader {
  private let api: HubApi

  init(api: HubApi = .shared) {
    self.api = api
  }

  func download(
    id: String,
    revision: String?,
    matching patterns: [String],
    useLatest: Bool,
    progressHandler: @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    _ = useLatest
    return try await api.snapshot(
      from: id,
      revision: revision ?? "main",
      matching: patterns,
      progressHandler: { progress in
        progressHandler(progress)
      })
  }
}

/// Adapts a swift-transformers `Tokenizer` to mlx-swift-lm's tokenizer protocol.
struct TransformersTokenizerAdapter: MLXLMCommon.Tokenizer {
  private let upstream: Tokenizers.Tokenizer

  init(_ upstream: Tokenizers.Tokenizer) {
    self.upstream = upstream
  }

  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
  }

  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }

  func convertTokenToId(_ token: String) -> Int? {
    upstream.convertTokenToId(token)
  }

  func convertIdToToken(_ id: Int) -> String? {
    upstream.convertIdToToken(id)
  }

  var bosToken: String? { upstream.bosToken }
  var eosToken: String? { upstream.eosToken }
  var unknownToken: String? { upstream.unknownToken }

  func applyChatTemplate(
    messages: [[String: any Sendable]],
    tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    try upstream.applyChatTemplate(
      messages: messages,
      tools: tools,
      additionalContext: additionalContext)
  }
}

/// Loads a tokenizer from a local model directory via `AutoTokenizer.from(modelFolder:)`.
struct TransformersTokenizerLoader: TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
    return TransformersTokenizerAdapter(tokenizer)
  }
}

import CryptoKit
import Foundation
import MLX
import MLXLMCommon

/// Holds the KV state of the Dictate Prompt system prompt **in memory**, so it is prefilled once
/// per app session instead of once per request.
///
/// Why this exists, measured (`LocalLLMBenchmarkTests`, same model on both sides): a warm MLX
/// request spent ~3s in prefill against Ollama's ~0.4s, while generation was competitive. The gap
/// was entirely the thousand-token system prompt being re-processed every time, because the
/// provider built a fresh `ChatSession` per request. Ollama avoids it by keeping the KV cache of
/// the shared prefix in RAM between requests.
///
/// A first attempt used the package's file-based prefix cache directly — `saveCache(to:)` before
/// each request, `loadPromptCache(url:)` after — and did **not** pay: the cache for this prompt is
/// a 75 MB `.safetensors` file, and deserializing it costs about what re-prefilling costs. So the
/// file is now written and read exactly **once**, and what survives between requests is the array
/// state, held here.
///
/// Two properties of `KVCacheSimple` make sharing that state across requests safe, and both were
/// read out of the implementation rather than assumed:
///
///   - Its `state` setter leaves `offset == keys.dim(2)`, i.e. the restored cache is exactly full.
///     `update(keys:values:)` therefore takes its reallocating branch on the very first token,
///     builds new buffers with `concatenated`, and writes only into those. The snapshot arrays are
///     read, never written — so every request can be handed the same arrays.
///   - The *objects* are mutated (`offset`, `keys`), so each request still needs its own
///     `KVCacheSimple` instances. Cheap: they wrap the shared arrays.
///
/// Only `KVCacheSimple` is reconstructed. A model whose cache is rotating or quantized falls back
/// to a plain per-request session rather than being handed a cache of the wrong shape.
///
/// **Only for prompts that repeat.** Priming costs seconds and holds tens of megabytes, so it is
/// gated on `ChatRequestOptions.reusablePromptPrefix` — true for Dictate Prompt and the Read Aloud
/// rewrite, false for Chat, whose system prompt carries the date, the live meeting transcript,
/// memory and the workspace map and therefore differs on nearly every message.
///
/// **The primed prefix contains one throwaway exchange.** The KV state only becomes real once
/// something has been generated, and the public API to generate is `respond(to:)` — so the cache
/// covers `system + user("hi") + one assistant token`, and every request restores that before its
/// own turn. Removing it would mean truncating the KV to the system prompt's token length, and
/// getting that boundary wrong mid-template is exactly the mismatch the package documents as
/// incoherent output. Verified on the Dictate Prompt task that rewrites come back clean; revisit
/// if a prompt ever turns out to be sensitive to the leading turn.
actor MLXPromptCache {
  static let shared = MLXPromptCache()

  private init() {}

  /// One entry per model+prompt pair. `[MLXArray]` per layer, plus the metaState that came with it.
  private struct Snapshot {
    let layers: [(state: [MLXArray], metaState: [String])]
  }

  private var snapshots: [String: Snapshot] = [:]

  /// In-flight priming per key, so two requests arriving together prime once instead of twice.
  /// Without it the `await` below suspends the actor between the "is it cached?" check and the
  /// store, and both callers run the multi-second generation. `ModelManager.readyTasks` solves the
  /// same problem for model loads; this is that pattern.
  private var priming: [String: Task<Snapshot?, Never>] = [:]

  /// Keys in least-recently-used order. Even gated to stable prompts, editing the Dictate Prompt
  /// system prompt in Settings mints a new key each time, and nothing else would ever free the old
  /// one.
  private var lru: [String] = []
  private static let maxSnapshots = 2

  private func key(model: String, systemPrompt: String) -> String {
    var hasher = SHA256()
    hasher.update(data: Data(model.utf8))
    hasher.update(data: Data(systemPrompt.utf8))
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// A session for one request, starting from the shared prefix when one could be built.
  ///
  /// Falls back to a plain session — the behaviour before this type existed — whenever anything on
  /// the priming path fails. The feature is a latency optimization; it must never be the reason a
  /// rewrite does not happen.
  func session(
    container: ModelContainer,
    modelID: String,
    systemPrompt: String?,
    reusePrefix: Bool,
    parameters: GenerateParameters,
    additionalContext: [String: any Sendable]?
  ) async -> MLXLMCommon.ChatSession {
    func plainSession() -> MLXLMCommon.ChatSession {
      MLXLMCommon.ChatSession(
        container, instructions: systemPrompt, generateParameters: parameters,
        additionalContext: additionalContext)
    }

    // A prompt that will not come back is not worth priming — see `reusablePromptPrefix`.
    guard reusePrefix else { return plainSession() }
    guard let systemPrompt, !systemPrompt.isEmpty else { return plainSession() }
    let id = key(model: modelID, systemPrompt: systemPrompt)

    guard let snapshot = await snapshot(
      id: id, container: container, modelID: modelID, systemPrompt: systemPrompt,
      parameters: parameters, additionalContext: additionalContext)
    else { return plainSession() }

    // Fresh cache objects around the shared arrays. `instructions: nil` — the cache already
    // encodes the system prompt, and passing it again would re-tokenize it against KV state that
    // does not match, which the package documents as incoherent output rather than an error.
    let caches: [KVCache] = snapshot.layers.map { layer in
      let cache = KVCacheSimple()
      cache.state = layer.state
      cache.metaState = layer.metaState
      return cache
    }
    return MLXLMCommon.ChatSession(
      container, instructions: nil, cache: caches, generateParameters: parameters,
      additionalContext: additionalContext)
  }

  /// The snapshot for `id`, priming it once if it is not there yet.
  private func snapshot(
    id: String,
    container: ModelContainer,
    modelID: String,
    systemPrompt: String,
    parameters: GenerateParameters,
    additionalContext: [String: any Sendable]?
  ) async -> Snapshot? {
    if let cached = snapshots[id] {
      touch(id)
      return cached
    }
    if let inFlight = priming[id] { return await inFlight.value }

    // Registered before the first suspension point, so a concurrent caller finds it.
    let task = Task { [container, modelID, systemPrompt, parameters, additionalContext] in
      await buildSnapshot(
        container: container, modelID: modelID, systemPrompt: systemPrompt,
        parameters: parameters, additionalContext: additionalContext)
    }
    priming[id] = task
    let built = await task.value
    priming[id] = nil
    if let built { store(id, built) }
    return built
  }

  private func store(_ id: String, _ snapshot: Snapshot) {
    snapshots[id] = snapshot
    touch(id)
    while lru.count > Self.maxSnapshots, let oldest = lru.first {
      lru.removeFirst()
      snapshots[oldest] = nil
      DebugLogger.log("MLX-PROMPT-CACHE: evicted the least recently used prefix")
    }
  }

  private func touch(_ id: String) {
    lru.removeAll { $0 == id }
    lru.append(id)
  }

  /// Prefills the system prompt once and lifts its KV state into memory.
  ///
  /// Routes through the package's file format because that is the only public way to get at a
  /// session's cache — `ChatSession.withCache` is internal. The file is written to a temporary
  /// location, read back, and deleted; nothing on the request path touches disk afterwards.
  private func buildSnapshot(
    container: ModelContainer,
    modelID: String,
    systemPrompt: String,
    parameters: GenerateParameters,
    additionalContext: [String: any Sendable]?
  ) async -> Snapshot? {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-prefix-\(UUID().uuidString).safetensors")
    defer { try? FileManager.default.removeItem(at: url) }

    do {
      let start = CFAbsoluteTimeGetCurrent()
      var priming = parameters
      priming.maxTokens = 1
      let builder = MLXLMCommon.ChatSession(
        container, instructions: systemPrompt, generateParameters: priming,
        additionalContext: additionalContext)
      _ = try await builder.respond(to: "hi")
      try await builder.saveCache(to: url)

      let (caches, _) = try loadPromptCache(url: url)
      guard !caches.isEmpty else { return nil }
      guard let simple = caches as? [KVCacheSimple] else {
        DebugLogger.log(
          "MLX-PROMPT-CACHE: \(modelID) uses a cache this path does not reconstruct — "
            + "prefilling per request")
        return nil
      }

      // Materialize before sharing: the state getter hands back lazy slices, and every request
      // would otherwise re-evaluate the same graph.
      let layers = simple.map { (state: $0.state, metaState: $0.metaState) }
      eval(layers.flatMap(\.state))

      DebugLogger.log(
        "MLX-PROMPT-CACHE: primed \(modelID) in "
          + "\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s "
          + "(\(layers.count) layers, held in memory)")
      return Snapshot(layers: layers)
    } catch {
      DebugLogger.logWarning(
        "MLX-PROMPT-CACHE: could not prime \(modelID) (\(error.localizedDescription)) — "
          + "prefilling per request")
      return nil
    }
  }
}

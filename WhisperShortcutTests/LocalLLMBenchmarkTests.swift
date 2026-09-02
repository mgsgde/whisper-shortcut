import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Slice 1's gate from `plans/active/local-llm-mlx.md`: is an in-process MLX model meaningfully
/// faster than the local HTTP server it is meant to replace? The plan says this measurement is
/// allowed to kill the feature, so it has to exist before the UI is judged worth keeping.
///
/// Opt-in via `WHISPERSHORTCUT_BENCH_LOCAL_LLM=1`. It downloads gigabytes on first run and takes
/// minutes, which is exactly what `run-tests.sh` must never do — `/release` gates on that suite.
///
/// What is measured, per provider:
///   - **load**: weights from disk into RAM (MLX) — the HTTP server pays its own, invisible to us
///   - **prefill**: request sent → first token, i.e. prompt processing
///   - **generation**: first token → last token
///
/// Prefill and generation are split because they respond to different fixes: a primed prompt cache
/// versus a smaller model. This mirrors the `SPEED:` line `executePromptWithLocal` already logs, so
/// numbers from here and from real use are comparable.
@Suite("Local LLM benchmark (opt-in)", .tags(.liveNetwork), .enabled(if: !TestRun.isHermetic))
struct LocalLLMBenchmarkTests {

  private static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["WHISPERSHORTCUT_BENCH_LOCAL_LLM"] == "1"
  }

  /// A realistic Dictate Prompt turn: a paragraph to edit plus a spoken instruction. Fixed text so
  /// the two providers are asked to do the same work — token counts differ per tokenizer, but the
  /// input is identical.
  private static let selectedText = """
    The quarterly review meeting has been moved to next Thursday at 3pm because several \
    stakeholders raised conflicts with the original slot. Please make sure the updated deck is \
    circulated at least one day in advance so everyone has time to read it beforehand, and note \
    that the finance section still needs the revised headcount numbers from operations.
    """
  private static let instruction = "Make this shorter and more direct."

  private struct Timing {
    let load: Double
    let prefill: Double
    let generation: Double
    let characters: Int
    var total: Double { load + prefill + generation }
  }

  /// Streams one request and splits the wall clock the same way `executePromptWithLocal` does.
  private static func measure(
    provider: LLMChatProvider,
    model: String,
    load: Double
  ) async throws -> Timing {
    let systemPrompt = SpeechService.buildDictatePromptSystemPrompt(
      logPrefix: "BENCH", usesScreenshotSelection: false)
    let userText = """
      \(AppConstants.clipboardSelectionHeader)

      \(selectedText)

      VOICE INSTRUCTION:
      \(instruction)
      """
    let contents: [[String: Any]] = [["role": "user", "parts": [["text": userText]]]]
    let systemInstruction: [String: Any] = ["parts": [["text": systemPrompt]]]

    let start = CFAbsoluteTimeGetCurrent()
    var firstToken: CFAbsoluteTime?
    var combined = ""

    for try await event in provider.sendChatStream(
      model: model, contents: contents, systemInstruction: systemInstruction,
      tools: [], options: .textTransform)
    {
      if case .textDelta(let delta) = event {
        if firstToken == nil { firstToken = CFAbsoluteTimeGetCurrent() }
        combined += delta
      }
    }

    let end = CFAbsoluteTimeGetCurrent()
    let reply = LocalLLMChatProvider.strippingReasoningBlocks(combined)
    #expect(!reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(model) produced no text")

    return Timing(
      load: load,
      prefill: (firstToken ?? end) - start,
      generation: end - (firstToken ?? end),
      characters: reply.count)
  }

  private static func report(_ label: String, _ t: Timing) {
    print(String(
      format: "BENCH [%@] load %.2fs + prefill %.2fs + generation %.2fs = %.2fs total (%d chars)",
      label, t.load, t.prefill, t.generation, t.total, t.characters))
  }

  @Test(
    "In-process MLX: load, prefill, generation",
    .enabled(if: isEnabled, "Set WHISPERSHORTCUT_BENCH_LOCAL_LLM=1 to run (downloads gigabytes)")
  )
  func mlx() async throws {
    let model = PromptModel.localMLXQwen34BInstruct
    let type = try #require(model.localMLXModelType)

    // Cold: whatever the user pays on first use, download included.
    let loadStart = CFAbsoluteTimeGetCurrent()
    try await LocalLLMModelManager.shared.ensureReady(type)
    let load = CFAbsoluteTimeGetCurrent() - loadStart

    let cold = try await Self.measure(provider: MLXChatProvider.shared, model: model.rawValue, load: load)
    Self.report("mlx cold \(type.huggingFaceID)", cold)

    // Warm: the second Dictate Prompt of a session, which is the common case. `load` is zero here
    // because the weights are already resident — that is the whole point of the in-process design.
    let warm = try await Self.measure(provider: MLXChatProvider.shared, model: model.rawValue, load: 0)
    Self.report("mlx warm \(type.huggingFaceID)", warm)
  }

  @Test(
    "Local HTTP server: prefill, generation",
    .enabled(if: isEnabled, "Set WHISPERSHORTCUT_BENCH_LOCAL_LLM=1 to run (needs a local server)")
  )
  func httpServer() async throws {
    // Overridable so the two sides can be pointed at the *same* model. Comparing MLX's Qwen3-4B
    // against whatever tag happens to be configured measures two models, not two runtimes.
    let tag = ProcessInfo.processInfo.environment["WHISPERSHORTCUT_BENCH_OLLAMA_MODEL"]
      ?? LocalLLMPreferences.modelID

    // Cold includes whatever the server does on demand — Ollama loads the model here, and that
    // load is invisible to us, so it lands inside prefill rather than in a `load` column.
    let cold = try await Self.measure(
      provider: LocalLLMChatProvider.shared, model: tag, load: 0)
    Self.report("http cold \(tag)", cold)

    let warm = try await Self.measure(
      provider: LocalLLMChatProvider.shared, model: tag, load: 0)
    Self.report("http warm \(tag)", warm)
  }
}

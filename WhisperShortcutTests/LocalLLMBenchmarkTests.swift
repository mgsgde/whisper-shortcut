import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Opt-in check that an in-process MLX model answers an offline Chat turn and does not leak a
/// reasoning block. `WHISPERSHORTCUT_BENCH_LOCAL_LLM=1` downloads the model on first run and takes
/// minutes, which `run-tests.sh` must never do.
@Suite("Local LLM benchmark (opt-in)", .tags(.liveNetwork), .enabled(if: !TestRun.isHermetic))
struct LocalLLMBenchmarkTests {

  private static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["WHISPERSHORTCUT_BENCH_LOCAL_LLM"] == "1"
  }

  @Test(
    "In-process MLX: offline Chat answer",
    .enabled(if: isEnabled, "Set WHISPERSHORTCUT_BENCH_LOCAL_LLM=1 to run (downloads gigabytes)")
  )
  func mlxChatAnswer() async throws {
    let raw = ProcessInfo.processInfo.environment["WHISPERSHORTCUT_BENCH_MLX_MODEL"]
      ?? PromptModel.localMLXQwen34BInstruct.rawValue
    let model = try #require(PromptModel(rawValue: raw))
    let type = try #require(model.localMLXModelType)
    try await LocalLLMModelManager.shared.ensureReady(type)

    let contents: [[String: Any]] = [["role": "user", "parts": [["text":
      "Was ist der Unterschied zwischen einer GmbH und einer UG?"]]]]
    let systemInstruction: [String: Any] = [
      "parts": [["text": AppConstants.defaultOfflineChatSystemPrompt]]]
    for turn in ["cold", "warm"] {
      let start = CFAbsoluteTimeGetCurrent()
      var firstToken: CFAbsoluteTime?
      var combined = ""
      for try await event in MLXChatProvider.shared.sendChatStream(
        model: model.rawValue, contents: contents, systemInstruction: systemInstruction,
        tools: [], options: ChatRequestOptions())
      {
        if case .textDelta(let delta) = event {
          if firstToken == nil { firstToken = CFAbsoluteTimeGetCurrent() }
          combined += delta
        }
      }
      let end = CFAbsoluteTimeGetCurrent()
      #expect(!combined.contains("<think>"), "\(raw) leaked a reasoning block")
      #expect(!combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      print(String(format: "BENCH-CHAT [%@ %@] first token %.2fs, total %.2fs\n%@",
                   type.huggingFaceID, turn, (firstToken ?? end) - start, end - start, combined))
    }
  }
}

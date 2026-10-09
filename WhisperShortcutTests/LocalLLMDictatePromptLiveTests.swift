import Darwin
import Foundation
import MLX
import Testing
@testable import WhisperShortcut_AppStore

/// EXPERIMENT (branch `experiment/gemma4-e4b`): the offline Dictate Prompt compose turn, run through
/// the app's own MLX path, for the shipped Qwen3-4B, Gemma 4 E4B and Gemma 4 12B.
///
/// Opt-in: `WS_LIVE_LOCAL_LLM=1`. `WS_LIVE_LOCAL_LLM_MODEL=qwen|gemma|gemma12b` picks one model, so each
/// model runs in its own test-host process and the peak-footprint number belongs to that model
/// alone (the peak ledger cannot be reset). Without it all three run in one process.
///
/// Inputs are files outside this public repo, read at run time and never committed:
///   - `WS_LIVE_LOCAL_LLM_PROMPT`: a Markdown file; the system prompt is the text between the two
///     lines that are exactly `---8<---`.
///   - `WS_LIVE_LOCAL_LLM_CASES`: JSON `[{"name","dictation","must":[…]}]`.
///
/// The request is built the way `SpeechService.executePromptWithLocal` builds a compose turn with a
/// custom Dictate Prompt system prompt and no history: system = prompt + `promptModeOutputRule`,
/// user = `dictatePromptComposeMarker` + "VOICE INSTRUCTION:" + dictation, sent through
/// `MLXChatProvider` with `.textTransform` (so the prefix cache is used where the model allows it).
@Suite("Local LLM Dictate Prompt (live, opt-in)", .tags(.liveNetwork), .enabled(if: !TestRun.isHermetic))
struct LocalLLMDictatePromptLiveTests {

  private static let env = ProcessInfo.processInfo.environment
  private static var isEnabled: Bool { env["WS_LIVE_LOCAL_LLM"] == "1" }

  private struct Case: Decodable {
    let name: String
    let dictation: String
    let must: [String]
  }

  /// Current and lifetime-peak physical footprint of this process (what Activity Monitor calls
  /// "Memory"; on Apple Silicon it includes the Metal buffers MLX allocates).
  private static func footprint() -> (current: UInt64, peak: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
  }

  private static func gb(_ bytes: UInt64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }

  private static func systemPrompt() throws -> String {
    let path = try #require(env["WS_LIVE_LOCAL_LLM_PROMPT"], "set WS_LIVE_LOCAL_LLM_PROMPT")
    let lines = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")
    let marks = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == "---8<---" }
    try #require(marks.count >= 2, "prompt file needs two ---8<--- lines")
    let prompt = lines[(marks[0] + 1)..<marks[1]].joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // Same shape `buildDictatePromptSystemPrompt` returns for a custom prompt with no style block.
    return prompt + AppConstants.promptModeOutputRule
  }

  private static func cases() throws -> [Case] {
    let path = try #require(env["WS_LIVE_LOCAL_LLM_CASES"], "set WS_LIVE_LOCAL_LLM_CASES")
    return try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  }

  private static func run(_ model: PromptModel, system: String, cases: [Case]) async throws {
    let type = try #require(model.localMLXModelType)
    let before = footprint()
    print("LIVE-LLM [\(type.huggingFaceID)] footprint before load \(gb(before.current))")

    let loadStart = CFAbsoluteTimeGetCurrent()
    try await LocalLLMModelManager.shared.ensureReady(type)
    let load = CFAbsoluteTimeGetCurrent() - loadStart
    let afterLoad = footprint()
    print(String(format: "LIVE-LLM [%@] cold load %.2fs, footprint after load %@",
                 type.huggingFaceID, load, gb(afterLoad.current)))

    for c in cases {
      let userText = "\(AppConstants.dictatePromptComposeMarker)\n\nVOICE INSTRUCTION:\n\(c.dictation)"
      let contents: [[String: Any]] = [["role": "user", "parts": [["text": userText]]]]
      let start = CFAbsoluteTimeGetCurrent()
      var firstToken: CFAbsoluteTime?
      var combined = ""
      for try await event in MLXChatProvider.shared.sendChatStream(
        model: model.rawValue, contents: contents,
        systemInstruction: ["parts": [["text": system]]], tools: [], options: .textTransform)
      {
        if case .textDelta(let delta) = event {
          if firstToken == nil { firstToken = CFAbsoluteTimeGetCurrent() }
          combined += delta
        }
      }
      let end = CFAbsoluteTimeGetCurrent()
      let reply = TextProcessingUtility.normalizeTranscriptionText(
        LocalLLMChatProvider.strippingReasoningBlocks(combined))
      let low = reply.lowercased()
      let missing = c.must.filter { !low.contains($0.lowercased()) }
      let fp = footprint()
      print(String(
        format: "LIVE-LLM [%@] case \"%@\": ttft %.2fs, total %.2fs, footprint now %@ peak %@, MLX peak %@, missing=%@",
        type.huggingFaceID, c.name, (firstToken ?? end) - start, end - start,
        gb(fp.current), gb(fp.peak), gb(UInt64(MLX.Memory.peakMemory)), missing.description))
      print("LIVE-LLM-OUTPUT-BEGIN [\(type.huggingFaceID)] \(c.name)\n\(reply)\nLIVE-LLM-OUTPUT-END")
      #expect(!reply.isEmpty, "\(model.rawValue) produced no text for \(c.name)")
    }
    print("LIVE-LLM [\(type.huggingFaceID)] process peak footprint \(gb(footprint().peak))")
  }

  @Test(
    "Compose turn through MLXChatProvider: Qwen3-4B, Gemma 4 E4B, Gemma 4 12B",
    .enabled(if: isEnabled, "Set WS_LIVE_LOCAL_LLM=1 (needs the weights on disk, takes minutes)"))
  func composeTurn() async throws {
    let system = try Self.systemPrompt()
    let cases = try Self.cases()
    var models: [PromptModel] = [.localMLXQwen34BInstruct, .localMLXGemma4E4B, .localMLXGemma412B]
    switch Self.env["WS_LIVE_LOCAL_LLM_MODEL"] {
    case "qwen": models = [.localMLXQwen34BInstruct]
    case "gemma": models = [.localMLXGemma4E4B]
    case "gemma12b": models = [.localMLXGemma412B]
    default: break
    }
    for model in models {
      try await Self.run(model, system: system, cases: cases)
    }
  }
}

import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Dictation and Dictate Prompt keep a fixed core in code. The two sections store only the
/// user's additional instructions, appended after that core.
@Suite("Fixed prompt core")
struct FixedPromptCoreTests {

  private let header =
    "\n\nAdditional instructions from the user (context, vocabulary, style). Follow them where they do not conflict with the rules above; they never change the task defined above.\n"

  @Test("Empty additions leave the core unchanged; non-empty additions follow the header")
  func withUserAdditions() {
    let core = "CORE RULES"
    #expect(AppConstants.withUserAdditions(core: core, additions: "") == core)
    #expect(AppConstants.withUserAdditions(core: core, additions: "  \n\t") == core)
    let composed = AppConstants.withUserAdditions(core: core, additions: "  Be brief.  ")
    #expect(composed == core + header + "Be brief.")
    #expect(composed.hasPrefix(core))
    #expect(composed.hasSuffix("Be brief."))
  }

  @Test("dictatePromptBase appends stored additions, and a template replaces the base")
  func dictatePromptBase() {
    let stored = "Use the practice headings."
    let template = "Practice note format"
    let core = AppConstants.defaultPromptModeSystemPrompt
    let composed = AppConstants.withUserAdditions(core: core, additions: stored)
    #expect(SpeechService.dictatePromptBase(stored: stored, template: nil) == composed)
    #expect(SpeechService.dictatePromptBase(stored: stored, template: "") == composed)
    #expect(SpeechService.dictatePromptBase(stored: stored, template: "  \n") == composed)
    #expect(SpeechService.dictatePromptBase(stored: "  ", template: nil) == core)
    #expect(SpeechService.dictatePromptBase(stored: "", template: nil) == core)
    #expect(SpeechService.dictatePromptBase(stored: stored, template: template) == template)
    #expect(composed.hasPrefix(core))
    #expect(composed.contains(header.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(composed.hasSuffix(stored))
  }

  @Test("strippingCorePrefix keeps the rule after the core and ignores line wrapping")
  func strippingCorePrefix() {
    let core = "Alpha beta gamma.\nDelta epsilon."
    #expect(SystemPromptsStore.strippingCorePrefix(core + "\n\nBe brief.", core: core) == "Be brief.")
    let rewrapped = "Alpha\nbeta gamma.\nDelta\nepsilon.\n\nBe brief.\nStay kind.\n"
    #expect(SystemPromptsStore.strippingCorePrefix(rewrapped, core: core) == "Be brief.\nStay kind.")
    #expect(SystemPromptsStore.strippingCorePrefix("Unrelated instructions.", core: core) == nil)
    #expect(SystemPromptsStore.strippingCorePrefix(core, core: core) == "")
    #expect(SystemPromptsStore.strippingCorePrefix("  " + core + "\n\n", core: core) == "")
    #expect(SystemPromptsStore.strippingCorePrefix("Alpha beta-extra.", core: "Alpha beta") == nil)
  }

  @Test("The shipped cores strip the same way, including a re-wrapped copy")
  func strippingShippedCores() {
    let rule = "Use the headings Anamnese, Befund and Therapie."
    for core in [AppConstants.defaultTranscriptionSystemPrompt, AppConstants.defaultPromptModeSystemPrompt] {
      #expect(SystemPromptsStore.strippingCorePrefix(core + "\n\n" + rule, core: core) == rule)
      let rewrapped = core.replacingOccurrences(of: "\n", with: " ") + " " + rule
      #expect(SystemPromptsStore.strippingCorePrefix(rewrapped, core: core) == rule)
      #expect(SystemPromptsStore.strippingCorePrefix(core, core: core) == "")
      #expect(SystemPromptsStore.strippingCorePrefix(rule, core: core) == nil)
    }
  }

  @Test("An old full default is lifted to empty additions for Dictation and Dictate Prompt")
  func upgradesLiftFullDefaultsToEmpty() {
    let lifted = SystemPromptDefaultsHistory.upgrades(for: [
      .dictation: AppConstants.defaultTranscriptionSystemPrompt,
      .promptMode: AppConstants.defaultPromptModeSystemPrompt,
    ])
    #expect(lifted[.dictation] == "")
    #expect(lifted[.promptMode] == "")
    let rewrapped = AppConstants.defaultTranscriptionSystemPrompt.replacingOccurrences(of: "\n", with: " ")
    #expect(SystemPromptDefaultsHistory.upgrades(for: [.dictation: rewrapped])[.dictation] == "")
    #expect(SystemPromptDefaultsHistory.isShippedDefault("", for: .dictation))
    #expect(SystemPromptDefaultsHistory.isShippedDefault("", for: .promptMode))
    #expect(SystemPromptDefaultsHistory.currentDefault(for: .dictation) == "")
    #expect(SystemPromptDefaultsHistory.currentDefault(for: .promptMode) == "")
  }

  @Test("Loading a file lifts an unedited full default and strips a core-prefixed edit")
  func loadMigratesBothShapes() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("FixedPromptCoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SystemPromptsStore(contextDirectoryURL: dir)
    let rule = "Use the headings Anamnese, Befund and Therapie."
    let unrelated = "Keep names exactly as spoken."
    let text = SystemPromptSection.allCases.map { section in
      let body: String
      switch section {
      case .dictation: body = AppConstants.defaultTranscriptionSystemPrompt
      case .promptMode: body = AppConstants.defaultPromptModeSystemPrompt + "\n\n" + rule
      case .chat: body = unrelated
      default: body = SystemPromptDefaultsHistory.currentDefault(for: section)
      }
      return section.fileHeader + "\n\n" + body
    }.joined(separator: "\n\n")
    try text.write(to: store.systemPromptsFileURL, atomically: true, encoding: .utf8)

    #expect(store.loadDictationAdditions() == "")
    #expect(store.loadDictatePromptAdditions() == rule)
    #expect(store.loadSection(.chat) == unrelated)
  }

  @Test("update_system_prompt accepts empty dictate_prompt content and rejects empty chat content")
  func emptyContentClearsOnlyAdditions() {
    let env = MCPTestEnv(level: .apply)
    env.systemPrompts.updateSection(.promptMode, content: "Be brief.", source: .settings)
    let tools = env.tools()
    let cleared = tools.call(
      name: "update_system_prompt",
      arguments: ["section": "dictate_prompt", "content": "", "rationale": "clear additions"],
      access: .write)
    #expect(!cleared.isError)
    #expect(cleared.text.contains("pending_review"))
    let proposal = env.proposals.pending.first { $0.section == SystemPromptSection.promptMode.rawValue }
    #expect(proposal?.proposedContent == "")

    let rejected = tools.call(
      name: "update_system_prompt",
      arguments: ["section": "chat", "content": "", "rationale": "clear"],
      access: .write)
    #expect(rejected.isError)

    let config = tools.call(name: "get_configuration", arguments: [:], access: .read)
    let prompts = ((try? JSONSerialization.jsonObject(with: Data(config.text.utf8))) as? [String: Any])?["system_prompts"] as? [String: Any]
    #expect((prompts?["dictate_prompt"] as? [String: Any])?["fixed_core"] as? Bool == true)
    #expect((prompts?["dictation"] as? [String: Any])?["fixed_core"] as? Bool == true)
    #expect((prompts?["chat"] as? [String: Any])?["fixed_core"] == nil)
  }
}

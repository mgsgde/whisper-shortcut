import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Dictate Prompt's tool set must stay read-only: a tool that changes something would need an
/// approval prompt in the middle of a paste, which the agent path answers with "no".
@MainActor
@Suite("Dictate Prompt agent")
struct DictatePromptAgentTests {

  @Test("Every Dictate Prompt tool is read-only (needs no approval) and exists in the registry")
  func toolsAreReadOnly() {
    let registered = Set(ChatToolRegistry.allDeclarations(
      calendarConnected: true, trelloConnected: true, imageGenerationAvailable: false,
      meetingContext: false, workspaceAvailable: true, workspaceWritable: false
    ).compactMap { $0["name"] as? String })
    for name in DictatePromptAgent.readOnlyToolNames {
      #expect(!ChatToolRegistry.requiresUserApproval(name), "\(name) must not need approval")
      #expect(registered.contains(name), "\(name) is not a registered tool")
    }
    for writer in ["write_text_file", "edit_text_file", "google_calendar_create_event", "remember_about_user", "trello_move_card"] {
      #expect(!DictatePromptAgent.readOnlyToolNames.contains(writer))
    }
  }

  @Test("The setting off means no tools, so the classic single request runs")
  func settingOffDisablesTools() {
    let key = UserDefaultsKeys.dictatePromptToolsEnabled
    let previous = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(previous, forKey: key) }
    UserDefaults.standard.set(false, forKey: key)
    #expect(DictatePromptAgent.availableTools().isEmpty)
  }

  @Test("Agent path only where tool calling exists: Gemini, OpenAI, a local server — not MLX")
  func agentSupportByProvider() {
    #expect(DictatePromptAgent.supportsAgent(.openaiGPT4oAudio))
    #expect(DictatePromptAgent.supportsAgent(SettingsDefaults.selectedPromptModel))
    #expect(DictatePromptAgent.supportsAgent(.localModel))
    #expect(!DictatePromptAgent.supportsAgent(.localMLXQwen34BInstruct))
  }

  @Test("Offline Mode offers no cloud integration tools")
  func offlineModeDropsCloudTools() {
    let previous = OfflineMode.isEnabled
    defer { OfflineMode.setEnabled(previous) }
    OfflineMode.setEnabled(true)
    let names = Set(DictatePromptAgent.availableTools().map(\.name))
    let cloud = ["gmail_search", "gmail_read", "google_calendar_list_events", "google_tasks_list", "trello_list_cards"]
    #expect(names.isDisjoint(with: cloud))
  }

  @Test("Round cap stays small")
  func roundCap() {
    #expect(DictatePromptAgent.maxToolRounds == 3)
  }
}

/// The agent path against the real Gemini API: typed history/parts converted to the chat
/// provider's shape, the tool preamble in front of the system prompt, tools declared, and a
/// normal rewrite still coming back (most instructions need no lookup).
@MainActor
@Suite("Dictate Prompt agent (live)", .tags(.liveNetwork), .enabled(if: !TestRun.isHermetic))
struct DictatePromptAgentLiveTests {
  private final class TestResourceAnchor {}

  @Test(
    "A plain rewrite comes back through the agent path with tools declared",
    .enabled(if: KeychainManager.shared.hasNonEmpty(.google), "No Gemini key in .env"))
  func rewriteWithToolsDeclared() async throws {
    let tools = ChatToolRegistry.allDeclarations(
      calendarConnected: false, trelloConnected: false, imageGenerationAvailable: false,
      meetingContext: false, workspaceAvailable: true, workspaceWritable: false
    ).compactMap { decl -> LLMToolDeclaration? in
      guard let name = decl["name"] as? String, name == "list_workspace_folders",
            let desc = decl["description"] as? String,
            let params = decl["parameters"] as? [String: Any] else { return nil }
      return LLMToolDeclaration(name: name, description: desc, parameters: params)
    }
    #expect(tools.count == 1)
    let parts = [
      GeminiChatRequest.GeminiChatPart(
        text: "\(AppConstants.clipboardSelectionHeader)\n\nhelo wrold, see you tomorow",
        inlineData: nil, fileData: nil, url: nil),
      GeminiChatRequest.GeminiChatPart(
        text: "VOICE INSTRUCTION:\nFix the spelling.", inlineData: nil, fileData: nil, url: nil),
    ]
    let model = SettingsDefaults.selectedPromptModel
    let text = try await DictatePromptAgent.run(
      provider: LLMProviderFactory.provider(for: model),
      requestModel: model.rawValue,
      contents: try DictatePromptAgent.makeContents(history: [], userParts: parts),
      systemPrompt: SpeechService.buildDictatePromptSystemPrompt(
        logPrefix: "TEST", usesScreenshotSelection: false),
      tools: tools,
      logPrefix: "TEST-DICTATE-PROMPT-AGENT")
    let lower = text.lowercased()
    #expect(lower.contains("hello world"), "got: \(text)")
    #expect(lower.contains("tomorrow"), "got: \(text)")
  }

  @Test(
    "OpenAI GPT-Audio accepts the agent path's Chat Completions request with a tool declared",
    .enabled(if: KeychainManager.shared.hasNonEmpty(.openAI), "No OpenAI key in .env"))
  func openAIRewriteWithToolsDeclared() async throws {
    let tools = ChatToolRegistry.workspaceFunctionDeclarations.compactMap { decl -> LLMToolDeclaration? in
      guard let name = decl["name"] as? String, name == "list_workspace_folders",
            let desc = decl["description"] as? String,
            let params = decl["parameters"] as? [String: Any] else { return nil }
      return LLMToolDeclaration(name: name, description: desc, parameters: params)
    }
    #expect(tools.count == 1)
    // GPT-Audio requires audio in the input, exactly as the real path always attaches it.
    let audioURL = try #require(
      Bundle(for: TestResourceAnchor.self).url(forResource: "sample", withExtension: "wav"))
    let audio = try Data(contentsOf: audioURL).base64EncodedString()
    let contents: [[String: Any]] = [[
      "role": "user",
      "parts": [
        ["text": "\(AppConstants.clipboardSelectionHeader)\n\nhelo wrold, see you tomorow"],
        ["text": "VOICE INSTRUCTION (typed, the recording is only background):\nFix the spelling."],
        ["inline_data": ["mime_type": "audio/wav", "data": audio]],
      ],
    ]]
    let model = PromptModel.openaiGPT4oAudio
    let text = try await DictatePromptAgent.run(
      provider: LLMProviderFactory.provider(for: model),
      requestModel: model.rawValue,
      contents: contents,
      systemPrompt: SpeechService.buildDictatePromptSystemPrompt(
        logPrefix: "TEST", usesScreenshotSelection: false),
      tools: tools,
      logPrefix: "TEST-DICTATE-PROMPT-AGENT-OPENAI")
    #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty reply")
  }
}

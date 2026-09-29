import Foundation

/// Dictate Prompt on the chat's agent core (plans/active/voice-agent-core.md, slice 2).
///
/// "Answer this and offer my free slot on Thursday" or "fill in the ticket number from the Trello
/// card" need a lookup before the rewrite. With a connected integration, Dictate Prompt now runs
/// the same `ChatAgentRunner` as the chat, restricted to read-only tools and a few rounds, and
/// pastes the final text exactly as before. Without one — or with the setting off — nothing
/// changes: the single-request pipeline in `SpeechService` runs as it always did.
///
/// Decisions (Magnus, 2026-09-29, "nimm deine Empfehlungen"): read-only tools only, 3 tool rounds,
/// on by default for connected integrations with a Settings → Dictate Prompt switch.
enum DictatePromptAgent {

  /// Tool rounds before the tool-less final round. Dictate Prompt is a latency-sensitive paste;
  /// the chat allows 16.
  static let maxToolRounds = 3

  /// Tools Dictate Prompt may call. None of them changes anything, so none needs approval — a
  /// prompt in the middle of a paste would be the wrong place to ask.
  static let readOnlyToolNames: Set<String> = [
    "google_calendar_list_events", "google_tasks_list_tasklists", "google_tasks_list",
    "gmail_search", "gmail_read",
    "trello_list_boards", "trello_list_lists", "trello_list_cards",
    "list_workspace_folders", "list_directory", "read_text_file", "search_files",
  ]

  static var isEnabledInSettings: Bool {
    UserDefaults.standard.object(forKey: UserDefaultsKeys.dictatePromptToolsEnabled) as? Bool ?? true
  }

  /// Declarations for the read-only tools the user's connections make available. Empty means the
  /// agent path has nothing to offer and the classic pipeline should run.
  @MainActor
  static func availableTools() -> [LLMToolDeclaration] {
    guard isEnabledInSettings else { return [] }
    return ChatToolRegistry.allDeclarations(
      calendarConnected: GoogleAccountOAuthService.shared.isConnected,
      trelloConnected: TrelloOAuthService.shared.isConnected,
      imageGenerationAvailable: false,
      meetingContext: false,
      workspaceAvailable: !WorkspaceFolders.displayPaths(scope: .all).isEmpty,
      workspaceWritable: false
    ).compactMap { decl in
      guard let name = decl["name"] as? String, readOnlyToolNames.contains(name),
            let desc = decl["description"] as? String,
            let params = decl["parameters"] as? [String: Any] else { return nil }
      return LLMToolDeclaration(name: name, description: desc, parameters: params)
    }
  }

  /// Put in front of the Dictate Prompt system prompt on the agent path. In front, not appended:
  /// the output rule at the end of that prompt must stay the last thing the model reads.
  static let toolPreamble = """
    You can look things up with read-only tools (calendar, tasks, email, Trello, the user's shared \
    files) when the spoken instruction needs a fact you do not have — a free time slot, a ticket \
    number, what an email said. Use them only for that; most instructions need none. Never mention \
    the tools or your lookups in the result.


    """

  /// Runs one Dictate Prompt turn on the agent core and returns the model's final text (not yet
  /// normalized — the caller applies the same normalization and validation as the classic path).
  @MainActor
  static func run(
    model: PromptModel,
    history: [GeminiChatRequest.GeminiChatContent],
    userParts: [GeminiChatRequest.GeminiChatPart],
    systemPrompt: String,
    tools: [LLMToolDeclaration],
    logPrefix: String
  ) async throws -> String {
    var turns = history
    turns.append(GeminiChatRequest.GeminiChatContent(role: "user", parts: userParts))
    let contents = try turns.map(Self.dictionary(from:))
    let systemInstruction: [String: Any] = ["parts": [["text": toolPreamble + systemPrompt]]]
    let useGrounding = model.supportsGrounding
    DebugLogger.log(
      "\(logPrefix): Agent path — \(tools.count) read-only tool(s), max \(maxToolRounds) round(s), grounding=\(useGrounding)")

    let runner = ChatAgentRunner(
      provider: LLMProviderFactory.provider(for: model),
      model: model.rawValue,
      tools: tools,
      maxToolRounds: maxToolRounds,
      steps: ToolStepsBuffer(),
      systemInstruction: { systemInstruction },
      options: { isFinalRound in
        ChatRequestOptions(useGrounding: useGrounding, disableBuiltInTools: isFinalRound)
      },
      toolContext: { ChatToolContext(workspaceScope: .all) },
      // Every tool offered here is read-only; a call to anything else is refused, not asked about.
      approve: { name, _, _ in
        DebugLogger.logWarning("\(logPrefix): Refused non-read-only tool \(name)")
        return false
      },
      onDisplayText: { _, _ in })
    let result = try await runner.run(contents: contents)
    DebugLogger.log(
      "\(logPrefix): Agent finished — \(result.executedToolCalls) tool call(s) [\(result.records.map(\.name).joined(separator: ", "))]")
    return result.text
  }

  /// Gemini-typed content → the `[String: Any]` shape `LLMChatProvider` takes. The typed structs
  /// already encode the Gemini wire keys (`inline_data`, `file_data`), so audio, screenshot and
  /// history reach the model exactly as on the classic path.
  private static func dictionary(from content: GeminiChatRequest.GeminiChatContent) throws -> [String: Any] {
    let data = try JSONEncoder().encode(content)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TranscriptionError.networkError("Could not prepare the Dictate Prompt request")
    }
    return object
  }
}

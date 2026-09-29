import Foundation

/// Dictate Prompt on the chat's agent core (plans/active/voice-agent-core.md, slices 2 and 3).
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

  /// Dictate Prompt paths that can run the agent: a streaming chat API with tool calling. Gemini
  /// and OpenAI GPT-Audio take the recording directly; a local server (Ollama / LM Studio) gets
  /// the transcript. In-process MLX has no tool-calling path and keeps the single request.
  static func supportsAgent(_ model: PromptModel) -> Bool {
    switch model.provider {
    case .gemini, .openai, .local: return true
    case .grok, .anthropic, .customOpenAI, .localMLX: return false
    }
  }

  /// Local model ids whose server refused `tools` this session (Ollama: "… does not support
  /// tools" for gemma, phi, older deepseek-r1). Those skip the agent path so Dictate Prompt keeps
  /// working instead of failing on every request once an integration is connected. Main thread and
  /// the prompt path only touch it in sequence; a lost insert just means one more fallback.
  static var localModelsWithoutTools: Set<String> = []

  /// True when a local server rejected the request because the model has no tool support.
  static func isToolsUnsupported(_ error: Error) -> Bool {
    let text: String
    if case TranscriptionError.networkError(let message) = error {
      text = message
    } else {
      text = error.localizedDescription
    }
    let lower = text.lowercased()
    return lower.contains("support tools") || lower.contains("does not support tool")
      || lower.contains("tools are not supported") || lower.contains("tool calling is not supported")
  }

  static var isEnabledInSettings: Bool {
    UserDefaults.standard.object(forKey: UserDefaultsKeys.dictatePromptToolsEnabled) as? Bool ?? true
  }

  /// Declarations for the read-only tools the user's connections make available. Empty means the
  /// agent path has nothing to offer and the classic pipeline should run. Built from the per-area
  /// arrays rather than `allDeclarations`, which returns nothing while the *chat* runs on MLX.
  @MainActor
  static func availableTools() -> [LLMToolDeclaration] {
    guard isEnabledInSettings else { return [] }
    var decls: [[String: Any]] = []
    // Offline Mode blocks Google and Trello at the network layer; offering them would only produce
    // failed lookups. The shared-folder tools read this Mac and stay.
    if !OfflineMode.isEnabled {
      if GoogleAccountOAuthService.shared.isConnected {
        decls += ChatToolRegistry.calendarFunctionDeclarations + ChatToolRegistry.tasksFunctionDeclarations
          + ChatToolRegistry.gmailFunctionDeclarations
      }
      if TrelloOAuthService.shared.isConnected {
        decls += ChatToolRegistry.trelloFunctionDeclarations
      }
    }
    if !WorkspaceFolders.displayPaths(scope: .all).isEmpty {
      decls += ChatToolRegistry.workspaceFunctionDeclarations
    }
    return decls.compactMap { decl in
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

  /// History plus this turn as the `[String: Any]` contents the runner takes. Not main-actor: the
  /// inline audio can be megabytes of base64, and encoding it must not hitch the UI at paste time.
  static func makeContents(
    history: [GeminiChatRequest.GeminiChatContent],
    userParts: [GeminiChatRequest.GeminiChatPart]
  ) throws -> [[String: Any]] {
    var turns = history
    turns.append(GeminiChatRequest.GeminiChatContent(role: "user", parts: userParts))
    return try turns.map(Self.dictionary(from:))
  }

  /// Runs one Dictate Prompt turn on the agent core and returns the text to paste (not yet
  /// normalized — the caller applies the same normalization and validation as the classic path).
  /// `requestModel` is the id sent to `provider` — the picker's rawValue, or the tag the user typed
  /// for a local server. `baseOptions` carries the path's own request knobs (the local path's
  /// `.textTransform`); grounding and built-in tools are always off here.
  @MainActor
  static func run(
    provider: LLMChatProvider,
    requestModel: String,
    contents: [[String: Any]],
    systemPrompt: String,
    tools: [LLMToolDeclaration],
    baseOptions: ChatRequestOptions = ChatRequestOptions(),
    logPrefix: String
  ) async throws -> String {
    let systemInstruction: [String: Any] = ["parts": [["text": toolPreamble + systemPrompt]]]
    // No web grounding: Gemini's grounding also enables `url_context`, and an instruction planted in
    // the selection or in an email read with `gmail_read` could make Google fetch a URL carrying
    // private data — the reason the chat asks before `open_url`. The lookups here are the user's own.
    DebugLogger.log(
      "\(logPrefix): Agent path — \(tools.count) read-only tool(s), max \(maxToolRounds) round(s)")

    let runner = ChatAgentRunner(
      provider: provider,
      model: requestModel,
      tools: tools,
      maxToolRounds: maxToolRounds,
      steps: ToolStepsBuffer(),
      systemInstruction: { systemInstruction },
      options: { _ in
        var options = baseOptions
        options.useGrounding = false
        options.disableBuiltInTools = true
        return options
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
    if result.finalRoundText.isEmpty, result.toolLoopExhausted {
      // Otherwise the empty text would surface as "no speech detected", which is not what happened.
      throw TranscriptionError.networkError(
        "Dictate Prompt kept looking things up and didn't finish. Try again, or say more precisely what to look up.")
    }
    // Only the last round: earlier rounds' lead-ins ("Let me check your calendar.") must not be pasted.
    return result.finalRoundText
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

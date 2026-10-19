import Testing
@testable import WhisperShortcut_AppStore

/// The chat's slash menu: bare "/" lists commands only, models sit behind one `/model` row.
/// Inputs are passed in explicitly so these tests do not depend on this Mac's keys, chip or
/// Offline Mode setting.
@MainActor
@Suite("Slash menu suggestions")
struct SlashMenuSuggestionTests {

  private let commands = ChatViewModel.commandsBeforeModels + ChatViewModel.commandsAfterModels
  private let models: [PromptModel] = [
    .gemini31FlashLite, .gemini38Flash, .grok47, .openaiGPT6Sol, .claudeSonnet55, .claudeOpus55,
    .localMLXQwen34BInstruct,
  ]

  private func rows(_ text: String, current: PromptModel = .gemini38Flash) -> [ChatViewModel.SlashSuggestion] {
    ChatViewModel.slashSuggestions(composerText: text, commands: commands, models: models, current: current)
  }

  @Test("Bare slash lists commands only, with a single /model row")
  func bareSlashIsCommandsOnly() {
    let list = rows("/")
    #expect(list.allSatisfy { $0.model == nil })
    #expect(list.map(\.command) == commands.map(\.command))
    #expect(list.filter { $0.command == "/model" }.count == 1)
    #expect(list.first { $0.command == "/model" }?.detail == "Switch model…")
    let aliases = Set(ChatViewModel.modelCommandLookup.keys)
    #expect(list.allSatisfy { !aliases.contains($0.command) })
  }

  @Test("Command prefixes still filter commands")
  func commandPrefix() {
    #expect(rows("/mo").map(\.command) == ["/model"])
    #expect(rows("/s").map(\.command) == ["/screenshot", "/settings"])
  }

  @Test("`/model ` lists every offered model by display name, grouped like the picker")
  func modelListOpens() {
    let list = rows("/model ")
    #expect(list.compactMap(\.model) == models)
    #expect(list.first?.title == "Gemini 3.1 Flash-Lite")
    #expect(list.first { $0.model == .gemini38Flash }?.isCurrent == true)
    #expect(list.filter(\.isCurrent).count == 1)
  }

  @Test("The /model list filters as you type, word by word")
  func modelListFilters() {
    #expect(rows("/model claude").compactMap(\.model) == [.claudeSonnet55, .claudeOpus55])
    #expect(rows("/model opus").compactMap(\.model) == [.claudeOpus55])
    #expect(rows("/model flash lite").compactMap(\.model) == [.gemini31FlashLite])
    #expect(rows("/model 3.8").compactMap(\.model) == [.gemini38Flash])
    #expect(rows("/model offline").compactMap(\.model) == [.localMLXQwen34BInstruct])
    #expect(rows("/MODEL Grok").compactMap(\.model) == [.grok47])
    #expect(rows("/model nothing-like-this").isEmpty)
  }

  @Test("Only models passed in are listed (no MLX where it cannot run, no Local Server)")
  func onlyOfferedModels() {
    let cloudOnly: [PromptModel] = [.gemini38Flash, .grok47]
    let list = ChatViewModel.slashSuggestions(
      composerText: "/model ", commands: commands, models: cloudOnly, current: .gemini38Flash)
    #expect(list.compactMap(\.model) == cloudOnly)
    // Local Server is not a chat model, so the live list never contains it either.
    #expect(!PromptModel.chatModels.contains(.localModel))
  }

  @Test("A slash word that matches no command falls back to matching models")
  func aliasFallback() {
    #expect(rows("/claude").compactMap(\.model) == [.claudeSonnet55, .claudeOpus55])
    #expect(rows("/gemini31flashlite").compactMap(\.model) == [.gemini31FlashLite])
    #expect(rows("/g").isEmpty) // one letter is not enough to guess a model
    // A full alias for a model not offered here lists nothing, so Return dispatches the alias
    // (which explains why) instead of picking a look-alike such as an offline MLX model.
    #expect(rows("/local").isEmpty)
    let noMLX = models.filter { $0.provider != .localMLX }
    #expect(ChatViewModel.slashSuggestions(
      composerText: "/mlx", commands: commands, models: noMLX, current: .gemini38Flash).isEmpty)
    #expect(rows("hello there").isEmpty)
  }

  @Test("Missing credentials are marked on model rows")
  func needsSetup() {
    let list = ChatViewModel.slashSuggestions(
      composerText: "/model grok", commands: commands, models: models, current: .gemini38Flash,
      needsSetup: { $0 == .grok })
    #expect(list.first?.detail == "Grok · needs setup")
  }

  @Test("Initial highlight: exact command, alias target, then current model")
  func initialHighlight() {
    let modelList = rows("/model ", current: .grok47)
    #expect(modelList[ChatViewModel.initialSlashHighlight(in: modelList, composerText: "/model ")].model == .grok47)

    let gemini = rows("/gemini")
    let index = ChatViewModel.initialSlashHighlight(in: gemini, composerText: "/gemini")
    #expect(gemini[index].model == ChatModelProvider.gemini.defaultChatModel)

    let slash = rows("/")
    #expect(ChatViewModel.initialSlashHighlight(in: slash, composerText: "/") == 0)
    let settings = rows("/settings")
    #expect(settings[ChatViewModel.initialSlashHighlight(in: settings, composerText: "/settings")].command == "/settings")
  }

  @Test("Typed aliases keep dispatching even though they are not listed")
  func aliasesStillDispatch() {
    #expect(ChatViewModel.modelCommandLookup["/gemini31flashlite"] == .gemini31FlashLite)
    #expect(ChatViewModel.modelCommandLookup["/mlx"] == .localMLXQwen34BInstruct)
    #expect(ChatViewModel.modelCommandLookup["/local"] == .localModel)
  }

  @Test("Local Server is refused with a reason instead of a fake 'Model set to'")
  func localServerRefused() {
    let reason = ChatViewModel.chatUnavailableReason(for: .localModel)
    #expect(reason?.contains("only powers Dictate Prompt") == true)
  }
}

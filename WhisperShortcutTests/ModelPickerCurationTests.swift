import Testing
@testable import WhisperShortcut_AppStore

/// A stand-in model so the curation rule is tested without keychain or Offline Mode state.
private enum FakeModel: String, CaseIterable, PickerCuratedModel {
  case flagship, quick, quicker, local, oldFlash, newFlash, extra1, extra2

  var pickerSpeedRank: Int? {
    switch self {
    case .quicker: return 1
    case .quick: return 2
    case .flagship: return 5
    default: return nil
    }
  }

  var pickerOfflineRank: Int? { self == .local ? 0 : nil }
  var pickerSupersededBy: FakeModel? { self == .oldFlash ? .newFlash : nil }
  var pickerSetupBadge: String? { nil }
  var pickerStandInRank: Int? { self == .extra1 ? 0 : nil }
}

@Suite("Curated model pickers")
struct ModelPickerCurationTests {

  private typealias Curation = ModelPickerCuration<FakeModel>

  @Test("Top row is Recommended · Fastest · Offline, the rest goes behind More models")
  func topRow() {
    let curation = Curation(models: FakeModel.allCases, recommended: .flagship, selected: .flagship)
    #expect(curation.featured.map(\.model) == [.flagship, .quicker, .local])
    #expect(curation.featured.map(\.badges) == [[.recommended], [.fastest], [.offline]])
    #expect(curation.more == [.quick, .newFlash, .extra1, .extra2])
  }

  @Test("A selection outside the three joins the top row and leaves More models")
  func selectionAlwaysVisible() {
    let curation = Curation(models: FakeModel.allCases, recommended: .flagship, selected: .extra2)
    #expect(curation.featured.map(\.model) == [.flagship, .quicker, .local, .extra2])
    #expect(curation.featured.last?.badges == [])
    #expect(!curation.more.contains(.extra2))
  }

  @Test("One model winning two slots carries both badges")
  func mergedBadges() {
    let curation = Curation(models: FakeModel.allCases, recommended: .quicker, selected: .quicker)
    #expect(curation.featured.first == .init(model: .quicker, badges: [.recommended, .fastest]))
    #expect(curation.featured.count == 2)
  }

  @Test("Superseded models are hidden unless selected or their replacement is missing")
  func supersession() {
    let hidden = Curation(models: FakeModel.allCases, recommended: .flagship, selected: .flagship)
    let shown = hidden.featured.map(\.model) + hidden.more
    #expect(!shown.contains(.oldFlash))

    let selected = Curation(models: FakeModel.allCases, recommended: .flagship, selected: .oldFlash)
    #expect(selected.featured.map(\.model).contains(.oldFlash))

    let noReplacement = FakeModel.allCases.filter { $0 != .newFlash }
    let kept = Curation(models: noReplacement, recommended: .flagship, selected: .flagship)
    #expect(kept.more.contains(.oldFlash))
  }

  @Test("Short lists skip the disclosure")
  func shortList() {
    let curation = Curation(models: [.flagship, .extra1, .local], recommended: .flagship, selected: .flagship)
    #expect(curation.more.isEmpty)
    #expect(curation.featured.map(\.model) == [.flagship, .local, .extra1])
  }

  @Test("A recommendation the picker does not offer gives way to the stand-in")
  func recommendationNotOffered() {
    let curation = Curation(models: [.quick, .local, .extra1, .extra2, .newFlash], recommended: .flagship, selected: .quick)
    #expect(curation.featured.map(\.model) == [.extra1, .quick, .local])
    #expect(curation.featured.map(\.badges) == [[.recommended], [.fastest], [.offline]])
  }

  @Test("An unusable recommendation gives way to the stand-in, Fastest to the fastest usable")
  func unusableRecommendation() {
    let curation = Curation(
      models: FakeModel.allCases, recommended: .flagship, selected: .extra1,
      isUsable: { $0 != .flagship && $0 != .quicker })
    #expect(curation.featured.map(\.model) == [.extra1, .quick, .local])
    #expect(curation.featured.map(\.badges) == [[.recommended], [.fastest], [.offline]])
  }

  @Test("Without a stand-in the on-device model is recommended")
  func offlineRecommendation() {
    let curation = Curation(
      models: FakeModel.allCases, recommended: .flagship, selected: .local,
      isUsable: { $0 == .local })
    #expect(curation.featured.map(\.model) == [.local])
    #expect(curation.featured.first?.badges == [.recommended, .offline])
  }

  @Test("With nothing usable the slots keep the global choice")
  func nothingUsable() {
    let curation = Curation(
      models: FakeModel.allCases, recommended: .flagship, selected: .flagship, isUsable: { _ in false })
    #expect(curation.featured.map(\.model) == [.flagship, .quicker, .local])
    #expect(curation.featured.map(\.badges) == [[.recommended], [.fastest], [.offline]])
  }

  // MARK: - Credentials on the real pickers
  //
  // Each case passes the providers a user has keys for; on-device models are always usable.

  private static func dictate(_ providers: Set<TranscriptionProvider>, selected: TranscriptionModel)
    -> ModelPickerCuration<TranscriptionModel> {
    ModelPickerCuration(
      models: TranscriptionModel.selectableForDictation(offlineMode: false),
      recommended: SettingsDefaults.selectedTranscriptionModel, selected: selected,
      isUsable: { $0.provider == .offline || providers.contains($0.provider) })
  }

  private static func chat(_ providers: Set<ChatModelProvider>, selected: PromptModel)
    -> ModelPickerCuration<PromptModel> {
    ModelPickerCuration(
      models: PromptModel.chatModels, recommended: SettingsDefaults.selectedChatModel,
      selected: selected,
      isUsable: { $0.provider == .localMLX || $0.provider == .local || providers.contains($0.provider) })
  }

  private static func readAloud(_ providers: Set<TTSProvider>, selected: TTSModel)
    -> ModelPickerCuration<TTSModel> {
    ModelPickerCuration(
      models: TTSModel.readAloudModels, recommended: SettingsDefaults.readAloudModel,
      selected: selected, isUsable: { $0.provider == .system || providers.contains($0.provider) })
  }

  private static func model<M>(_ curation: ModelPickerCuration<M>, badge: ModelPickerBadge) -> M? {
    curation.featured.first { $0.badges.contains(badge) }?.model
  }

  @Test("Gemini only: Dictate recommends Gemini, nothing featured needs a key")
  func geminiOnly() {
    let dictate = Self.dictate([.google], selected: .gemini31FlashLite)
    #expect(dictate.featured.first == .init(model: .gemini31FlashLite, badges: [.recommended, .fastest]))
    let allUsable = dictate.featured.allSatisfy { $0.model.provider == .google || $0.model.isOffline }
    #expect(allUsable)

    let chat = Self.chat([.gemini], selected: .gemini38Flash)
    #expect(Self.model(chat, badge: .recommended) == .gemini38Flash)
    #expect(Self.model(chat, badge: .fastest) == .gemini31FlashLite)

    let read = Self.readAloud([.gemini], selected: .gemini38FlashLiteTTS)
    #expect(read.featured.first == .init(model: .gemini38FlashLiteTTS, badges: [.recommended, .fastest]))
  }

  @Test("OpenAI only: the defaults that are OpenAI stay, the rest move to OpenAI or on-device")
  func openAIOnly() {
    let dictate = Self.dictate([.openAI], selected: .openAIGPTTranscribe)
    #expect(Self.model(dictate, badge: .recommended) == .openAIGPTTranscribe)
    #expect(Self.model(dictate, badge: .fastest) == .openAIGPT4oTranscribe)

    let chat = Self.chat([.openai], selected: .openaiGPT6Sol)
    #expect(Self.model(chat, badge: .recommended) == .openaiGPT6Sol)
    // Only Gemini tiers carry a speed rank, so no OpenAI model is called fastest on a guess.
    #expect(Self.model(chat, badge: .fastest) == nil)

    // Same as the reconciler: Read Aloud without a Gemini key falls to the macOS voice.
    let read = Self.readAloud([.openai], selected: .systemMacOS)
    #expect(read.featured.first == .init(model: .systemMacOS, badges: [.recommended, .offline]))
  }

  @Test("OpenRouter only: both Dictate and Chat recommend the OpenRouter entry")
  func openRouterOnly() {
    let dictate = Self.dictate([.openRouter], selected: .openRouterTranscription)
    #expect(Self.model(dictate, badge: .recommended) == .openRouterTranscription)
    #expect(Self.model(dictate, badge: .fastest) == nil)

    let chat = Self.chat([.openRouter], selected: .openRouterChat)
    #expect(Self.model(chat, badge: .recommended) == .openRouterChat)
  }

  @Test("No key: every picker recommends what runs on this Mac")
  func noKey() {
    let dictate = Self.dictate([], selected: SettingsDefaults.selectedTranscriptionModel)
    let dictateRecommended = Self.model(dictate, badge: .recommended)
    #expect(dictateRecommended?.isOffline == true)
    #expect(dictate.featured.first?.badges == [.recommended, .offline])
    #expect(Self.model(dictate, badge: .fastest) == nil)

    let chat = Self.chat([], selected: SettingsDefaults.selectedChatModel)
    #expect(chat.featured.first?.badges == [.recommended, .offline])
    #expect(chat.featured.first?.model.pickerOfflineRank == 0)

    let read = Self.readAloud([], selected: SettingsDefaults.readAloudModel)
    #expect(Self.model(read, badge: .recommended) == .systemMacOS)
  }

  // MARK: - Data on the real enums

  @Test("Every featured slot in every picker is a real, offered model")
  func realPickers() {
    let dictation = ModelPickerCuration(
      models: TranscriptionModel.selectableForDictation(offlineMode: false),
      recommended: SettingsDefaults.selectedTranscriptionModel,
      selected: SettingsDefaults.selectedTranscriptionModel, isUsable: { _ in true })
    #expect(dictation.featured.count <= 3)
    #expect(dictation.featured.first?.model == .openAIGPTTranscribe)
    let fastestIsGrok = dictation.featured.contains { $0.model == .xaiTranscribe && $0.badges == [.fastest] }
    let offlineFeatured = dictation.featured.contains { $0.model.isOffline && $0.badges == [.offline] }
    #expect(fastestIsGrok)
    #expect(offlineFeatured)

    let readAloud = ModelPickerCuration(
      models: TTSModel.allCases, recommended: SettingsDefaults.readAloudModel,
      selected: SettingsDefaults.readAloudModel, isUsable: { _ in true })
    #expect(readAloud.featured.map(\.model) == [.gemini38FlashLiteTTS, .systemMacOS])
    #expect(readAloud.featured.first?.badges == [.recommended, .fastest])
  }

  @Test("Fastest prompt model is 3.1 Flash-Lite; offline pick is the catalogue's recommended MLX model")
  func promptRanks() {
    let ranked = PromptModel.allCases.filter { $0.pickerSpeedRank != nil }
    let fastest = ranked.min { ($0.pickerSpeedRank ?? .max) < ($1.pickerSpeedRank ?? .max) }
    #expect(fastest == .gemini31FlashLite)
    let onlyGemini = ranked.allSatisfy { $0.isGemini }
    #expect(onlyGemini)
    #expect(PromptModel.forLocalLLMModel(.defaultModel).pickerOfflineRank == 0)
    let onDevice = PromptModel.allCases.filter { $0.pickerOfflineRank != nil }
    let allLocal = onDevice.allSatisfy { $0.provider == .local || $0.provider == .localMLX }
    #expect(allLocal)
  }

  @Test("Gemini 3.7 Flash is hidden from transcription pickers only")
  func gemini37Supersession() {
    #expect(TranscriptionModel.gemini37Flash.pickerSupersededBy == .gemini38Flash)
    #expect(PromptModel.gemini37Flash.pickerSupersededBy == nil)
    let visible = ModelPickerCuration<TranscriptionModel>.visibleModels(
      TranscriptionModel.selectableForDictation(offlineMode: false), selected: .openAIGPTTranscribe)
    #expect(!visible.contains(.gemini37Flash))
    let selected = ModelPickerCuration<TranscriptionModel>.visibleModels(
      TranscriptionModel.selectableForDictation(offlineMode: false), selected: .gemini37Flash)
    #expect(selected.contains(.gemini37Flash))
  }

  @Test("Speed ranks never feature on-device models as Fastest")
  func ranksAreDisjoint() {
    let disjointTranscriptionModel = TranscriptionModel.allCases.allSatisfy { $0.pickerSpeedRank == nil || $0.pickerOfflineRank == nil }
    #expect(disjointTranscriptionModel)
    let disjointPromptModel = PromptModel.allCases.allSatisfy { $0.pickerSpeedRank == nil || $0.pickerOfflineRank == nil }
    #expect(disjointPromptModel)
    let disjointTTSModel = TTSModel.allCases.allSatisfy { $0.pickerSpeedRank == nil || $0.pickerOfflineRank == nil }
    #expect(disjointTTSModel)
  }

  @Test("More models marks each provider's own pick where that provider has a choice")
  func providerPicks() {
    let models = TranscriptionModel.selectableForDictation(offlineMode: false)
    let picks = TranscriptionModel.providerPicks(among: models)
    #expect(picks.contains(.gemini31FlashLite))
    #expect(picks.contains(.openAIGPTTranscribe))
    // A provider's sole tile gets no badge.
    #expect(!picks.contains(.xaiTranscribe))
    #expect(!picks.contains(.openRouterTranscription))
    // With the OpenAI pick in the top row, its siblings in More models carry no badge.
    let more = models.filter { $0 != .openAIGPTTranscribe }
    #expect(TranscriptionModel.providerPicks(among: more) == [.gemini31FlashLite])
    #expect(TranscriptionModel.gemini31FlashLite.providerPickName == "Gemini")
  }
}

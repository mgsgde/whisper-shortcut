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

  @Test("A recommendation the picker does not offer is not featured")
  func recommendationNotOffered() {
    let curation = Curation(models: [.quick, .local, .extra1, .extra2, .newFlash], recommended: .flagship, selected: .quick)
    let hasRecommended = curation.featured.contains { $0.badges.contains(.recommended) }
    #expect(!hasRecommended)
    #expect(curation.featured.map(\.model) == [.quick, .local])
  }

  // MARK: - Data on the real enums

  @Test("Every featured slot in every picker is a real, offered model")
  func realPickers() {
    let dictation = ModelPickerCuration(
      models: TranscriptionModel.selectableForDictation(offlineMode: false),
      recommended: SettingsDefaults.selectedTranscriptionModel,
      selected: SettingsDefaults.selectedTranscriptionModel)
    #expect(dictation.featured.count <= 3)
    #expect(dictation.featured.first?.model == .openAIGPTTranscribe)
    let fastestIsGrok = dictation.featured.contains { $0.model == .xaiTranscribe && $0.badges == [.fastest] }
    let offlineFeatured = dictation.featured.contains { $0.model.isOffline && $0.badges == [.offline] }
    #expect(fastestIsGrok)
    #expect(offlineFeatured)

    let readAloud = ModelPickerCuration(
      models: TTSModel.allCases, recommended: SettingsDefaults.readAloudModel,
      selected: SettingsDefaults.readAloudModel)
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
}

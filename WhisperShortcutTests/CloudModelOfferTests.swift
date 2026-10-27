import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("CloudModelOffer (pure decision)")
@MainActor
struct CloudModelOfferTests {

  private let mlx = PromptModel.forLocalLLMModel(LocalLLMModelType.defaultModel)
  private let offlineWhisper = TranscriptionModel.forOfflineModel(OfflineModelType.mostAccurate)

  private func keyless() -> [String: String] {
    [
      UserDefaultsKeys.selectedTranscriptionModel: offlineWhisper.rawValue,
      UserDefaultsKeys.selectedTranscriptionModelForMeetings: offlineWhisper.rawValue,
      UserDefaultsKeys.selectedPromptModel: mlx.rawValue,
      UserDefaultsKeys.selectedChatModel: mlx.rawValue,
    ]
  }

  @Test("No key → nothing to offer")
  func nothingWithoutKey() {
    #expect(CloudModelOffer.upgrades(selections: keyless(), hasKey: { _ in false }).isEmpty)
  }

  @Test("A Gemini key offers every on-device slot, onto Gemini")
  func geminiKeyOffersAllOnDeviceSlots() {
    let upgrades = CloudModelOffer.upgrades(selections: keyless(), hasKey: { $0 == .gemini })
    #expect(Set(upgrades.map(\.key)) == Set(keyless().keys))
    #expect(upgrades.allSatisfy { $0.provider == .gemini })
    let dictation = upgrades.first { $0.key == UserDefaultsKeys.selectedTranscriptionModel }
    #expect(dictation?.to == ModelSelectionReconciler.transcriptionReplacement(for: .gemini)?.rawValue)
  }

  @Test("Cloud selections and unset slots are left out")
  func cloudSlotsAreNotOffered() {
    var selections = keyless()
    selections[UserDefaultsKeys.selectedChatModel] = PromptModel.gemini38Flash.rawValue
    selections[UserDefaultsKeys.selectedTranscriptionModelForMeetings] = nil
    let keys = CloudModelOffer.upgrades(selections: selections, hasKey: { $0 == .gemini }).map(\.key)
    #expect(!keys.contains(UserDefaultsKeys.selectedChatModel))
    #expect(!keys.contains(UserDefaultsKeys.selectedTranscriptionModelForMeetings))
  }

  @Test("An Anthropic-only key moves Chat but never dictation — Anthropic has no transcription")
  func anthropicKeyLeavesTranscription() {
    let upgrades = CloudModelOffer.upgrades(selections: keyless(), hasKey: { $0 == .anthropic })
    #expect(!upgrades.contains { $0.key == UserDefaultsKeys.selectedTranscriptionModel })
    #expect(upgrades.allSatisfy { $0.provider == .anthropic })
  }

  @Test("A declined provider is not asked again; a new provider is")
  func declineIsRememberedPerProvider() {
    let gemini = CloudModelOffer.upgrades(selections: keyless(), hasKey: { $0 == .gemini })
    #expect(CloudModelOffer.shouldOffer(gemini, declined: []))
    #expect(!CloudModelOffer.shouldOffer(gemini, declined: ["gemini"]))
    let openAI = CloudModelOffer.upgrades(selections: keyless(), hasKey: { $0 == .openai })
    #expect(CloudModelOffer.shouldOffer(openAI, declined: ["gemini"]))
    #expect(!CloudModelOffer.shouldOffer([], declined: []))
  }
}

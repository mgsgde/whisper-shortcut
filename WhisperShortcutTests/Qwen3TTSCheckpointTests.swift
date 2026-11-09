import Testing
@testable import WhisperShortcut_AppStore

/// The two Qwen3-TTS checkpoints share one provider (`.localMLX`) and one stored voice key, but
/// not one speaker catalogue. These tests pin the split: a CustomVoice speaker id must never be
/// resolved as a VoiceDesign persona (and vice versa), because both would silently fall back to
/// the first entry of the wrong catalogue and read in a voice the user did not pick.
@Suite("Qwen3 TTS checkpoints")
struct Qwen3TTSCheckpointTests {

  @Test("Both checkpoints are offered, VoiceDesign first")
  func lineup() {
    let qwen3 = TTSModel.readAloudModels.filter { $0.qwen3ModelType != nil }
    // Offered checkpoints depend on this Mac's RAM (VoiceDesign needs 32 GB, CustomVoice 16 GB).
    let expected: [TTSModel] = [.qwen3VoiceDesign, .qwen3CustomVoice].filter {
      $0.qwen3ModelType?.isOfferable ?? true
    }
    #expect(qwen3 == expected)
    #expect(TTSModel.qwen3VoiceDesign.qwen3ModelType == .voiceDesign)
    #expect(TTSModel.qwen3CustomVoice.qwen3ModelType == .customVoice)
  }

  @Test("Each checkpoint has its own speaker catalogue and default")
  func catalogues() {
    let voiceDesign = TTSModel.qwen3VoiceDesign.availableVoices
    let customVoice = TTSModel.qwen3CustomVoice.availableVoices

    #expect(!voiceDesign.isEmpty)
    #expect(customVoice.count == Qwen3VoicePersona.customVoiceSpeakers.count)
    // Disjoint: no id is valid for both checkpoints.
    #expect(Set(voiceDesign.map(\.id)).isDisjoint(with: Set(customVoice.map(\.id))))

    #expect(TTSModel.qwen3CustomVoice.defaultVoice == Qwen3VoicePersona.customVoiceSpeakers[0].id)
    #expect(TTSModel.qwen3VoiceDesign.defaultVoice == Qwen3VoicePersona.default.id)
  }

  @Test("A CustomVoice speaker resolves to itself, not to a VoiceDesign persona")
  func customVoiceResolution() {
    for speaker in Qwen3VoicePersona.customVoiceSpeakers {
      let resolved = Qwen3VoicePersona.customVoiceSpeaker(for: speaker.id)
      #expect(resolved.id == speaker.id)
      #expect(resolved.customVoiceSpeaker == speaker.id)
    }
    // Unknown and empty ids fall back to the first speaker rather than crashing.
    #expect(Qwen3VoicePersona.customVoiceSpeaker(for: "not-a-speaker").id == Qwen3VoicePersona.customVoiceSpeakers[0].id)
    #expect(Qwen3VoicePersona.customVoiceSpeaker(for: "  ").id == Qwen3VoicePersona.customVoiceSpeakers[0].id)
  }

  @Test("VoiceDesign personas carry no CustomVoice speaker id")
  func voiceDesignPersonasHaveNoSpeaker() {
    for persona in Qwen3VoicePersona.all + Qwen3CustomPersonas.all {
      #expect(persona.customVoiceSpeaker == nil)
    }
  }

  @Test("CustomVoice shares the 16 GB floor and is the smaller download")
  func hardwareAndSize() {
    #expect(Qwen3ModelType.customVoice.minimumPhysicalMemoryGB == 16)
    #expect(Qwen3ModelType.customVoice.estimatedSizeMB < Qwen3ModelType.voiceDesign.estimatedSizeMB)
    // Faster of the two, so it sits ahead of VoiceDesign in the offline order.
    #expect(TTSModel.qwen3CustomVoice.pickerOfflineRank ?? .max < TTSModel.qwen3VoiceDesign.pickerOfflineRank ?? .max)
  }
}

import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Covers the two request knobs added for transcription and the cleanup that has to come with them.
///
/// Both failure modes here are silent. A wrong `thinkingLevel` for a tier is a hard HTTP 400 that
/// only shows up as "dictation stopped working" on that one model, and a preamble that survives
/// cleanup is pasted straight into whatever the user was typing into.
///
/// Everything is driven through the pure overloads rather than UserDefaults: suites run in
/// parallel, so writing the real transcription settings here raced the settings round-trip suite.
@Suite("Transcription tuning")
struct TranscriptionTuningTests {

  @Test("Flash tiers send the configured thinking level and temperature")
  func flashTiersSendConfiguredValues() {
    for model in [TranscriptionModel.gemini31FlashLite, .gemini35FlashLite, .gemini35Flash, .gemini36Flash] {
      let config = model.geminiTranscriptionGenerationConfig(temperature: 0.2, effort: .medium)
      #expect(config.thinkingConfig?.thinkingLevel == "medium", "\(model.rawValue)")
      #expect(config.thinkingConfig?.thinkingBudget == nil, "\(model.rawValue)")
      #expect(config.temperature == 0.2, "\(model.rawValue)")
    }
  }

  @Test("Pro is clamped off minimal — the API rejects that level for it")
  func proClampsMinimal() {
    // Unreachable in the shipped app since 2026-08-03 (Pro is no longer selectable for dictation),
    // but kept so re-offering it cannot regress into sending a level the API rejects.
    let clamped = TranscriptionModel.gemini31Pro.geminiTranscriptionGenerationConfig(
      temperature: 0.0, effort: .minimal)
    #expect(clamped.thinkingConfig?.thinkingLevel == "low")

    let unclamped = TranscriptionModel.gemini31Pro.geminiTranscriptionGenerationConfig(
      temperature: 0.0, effort: .high)
    #expect(unclamped.thinkingConfig?.thinkingLevel == "high")
  }

  @Test("Temperature is always encoded — omitting it means the model default of 1.0")
  func temperatureIsEncoded() {
    let config = TranscriptionModel.gemini35FlashLite.geminiTranscriptionGenerationConfig(
      temperature: 0.0, effort: .minimal)
    guard let json = try? JSONEncoder().encode(config),
          let decoded = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    else {
      Issue.record("generationConfig did not encode")
      return
    }
    #expect(decoded["temperature"] as? Double == 0.0)
  }

  @Test("Non-Gemini backends get no thinking config")
  func nonGeminiHasNoThinkingConfig() {
    for model in [TranscriptionModel.openRouterTranscription, .whisperBase, .openAIGPT4oTranscribe] {
      let config = model.geminiTranscriptionGenerationConfig(temperature: 0.0, effort: .high)
      #expect(config.thinkingConfig == nil, "\(model.rawValue)")
    }
  }

  @Test("Every temperature option parses back to a number the API accepts")
  func temperatureValuesAreInRange() {
    for option in TranscriptionTemperature.allCases {
      #expect(option.value >= 0.0 && option.value <= 2.0, "\(option.rawValue)")
      #expect(Double(option.rawValue) == option.value, "\(option.rawValue)")
    }
  }

  @Test("Chatty preambles are stripped, including the ones the literal list misses")
  func stripsPreambles() {
    // Both observed live when the thinking level was raised.
    #expect(
      TextProcessingUtility.strippingTranscriptionPreamble("**Transcription:**\nTesting 1, 2, 3.")
        == "Testing 1, 2, 3.")
    #expect(
      TextProcessingUtility.strippingTranscriptionPreamble(
        "Here is the transcription of the audio you provided: Testing 1, 2, 3.")
        == "Testing 1, 2, 3.")
    #expect(
      TextProcessingUtility.strippingTranscriptionPreamble("Transcription: hello world") == "hello world")
  }

  @Test("Real speech that merely mentions transcription is left alone")
  func leavesRealSpeechAlone() {
    let spoken = "Testing 1, 2, 3."
    #expect(TextProcessingUtility.strippingTranscriptionPreamble(spoken) == spoken)
    let mentions = "The transcription quality has improved a lot lately."
    #expect(TextProcessingUtility.strippingTranscriptionPreamble(mentions) == mentions)
  }

  @Test("A preamble that is the whole answer is kept, so validation can reject it")
  func keepsPreambleOnlyAnswer() {
    let onlyPreamble = "**Transcription:**"
    #expect(TextProcessingUtility.strippingTranscriptionPreamble(onlyPreamble) == onlyPreamble)
  }

  @Test("An empty OpenRouter model slug falls back to the default instead of being sent blank")
  func openRouterModelFallback() {
    #expect(TranscriptionTuning.resolveOpenRouterModelID("   ") == SettingsDefaults.openRouterTranscriptionModelID)
    #expect(TranscriptionTuning.resolveOpenRouterModelID(nil) == SettingsDefaults.openRouterTranscriptionModelID)
    #expect(TranscriptionTuning.resolveOpenRouterModelID("openai/gpt-audio-mini") == "openai/gpt-audio-mini")
  }
}

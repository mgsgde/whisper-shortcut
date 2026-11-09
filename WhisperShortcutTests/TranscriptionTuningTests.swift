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
    for model in [TranscriptionModel.gemini31FlashLite, .gemini35FlashLite, .gemini38Flash] {
      let config = model.geminiTranscriptionGenerationConfig(temperature: 0.2, effort: .medium)
      #expect(config.thinkingConfig?.thinkingLevel == "medium", "\(model.rawValue)")
      #expect(config.thinkingConfig?.thinkingBudget == nil, "\(model.rawValue)")
      #expect(config.temperature == 0.2, "\(model.rawValue)")
    }
  }

  @Test("Pro, Argon and 3.8 Flash are clamped off minimal — the API rejects that level for them")
  func clampsMinimal() {
    // Pro: unreachable in the shipped app since 2026-08-03 (no longer selectable for dictation),
    // but kept so re-offering it cannot regress into sending a level the API rejects.
    // Argon is the same shape: flagship reasoning, not a dictation model, and it documents
    // low/medium/high only.
    // 3.8 Flash: live-verified 2026-09-06, gemini-3.8-flash returns HTTP 400 for thinkingLevel MINIMAL.
    for model in [TranscriptionModel.gemini31Pro, .gemini4Argon, .gemini38Flash] {
      let clamped = model.geminiTranscriptionGenerationConfig(
        temperature: 0.0, effort: .minimal)
      #expect(clamped.thinkingConfig?.thinkingLevel == "low", "\(model.rawValue)")

      let unclamped = model.geminiTranscriptionGenerationConfig(
        temperature: 0.0, effort: .high)
      #expect(unclamped.thinkingConfig?.thinkingLevel == "high", "\(model.rawValue)")
    }
  }

  @Test("Temperature and maxOutputTokens are actually encoded into the request body")
  func requestKnobsAreEncoded() {
    // Temperature: omitting it means the model default of 1.0.
    // maxOutputTokens: the cap is worthless if it stays Swift-side, so assert on the encoded JSON.
    let config = TranscriptionModel.gemini35FlashLite.geminiTranscriptionGenerationConfig(
      temperature: 0.0, effort: .minimal)
    guard let json = try? JSONEncoder().encode(config),
          let decoded = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    else {
      Issue.record("generationConfig did not encode")
      return
    }
    #expect(decoded["temperature"] as? Double == 0.0)
    #expect(decoded["maxOutputTokens"] as? Int == 8192)
  }

  @Test("Every tier caps maxOutputTokens — the cost fuse must not depend on the tier")
  func everyTierCapsOutputTokens() {
    // Regression guard for 2026-08-03: gemini-3.1-pro-preview thought its way to 1.39M billed
    // output tokens (~€14.59) on a 1.3s recording because nothing bounded the response. The 90s
    // client timeout did not help — aborting the connection does not stop server-side generation.
    // Asserted over `allCases` rather than a hand-listed set so a tier added later fails here
    // instead of silently shipping uncapped.
    for model in TranscriptionModel.allCases {
      let config = model.geminiTranscriptionGenerationConfig(temperature: 0.0, effort: .minimal)
      #expect(
        config.maxOutputTokens
          == GeminiTranscriptionRequest.GeminiTranscriptionGenerationConfig.maxOutputTokens,
        "\(model.rawValue) sends an uncapped transcription request")
    }
  }

  @Test("Non-Gemini backends get no thinking config")
  func nonGeminiHasNoThinkingConfig() {
    for model in [TranscriptionModel.openRouterTranscription, .whisperBase, .openAIGPT4oTranscribe] {
      let config = model.geminiTranscriptionGenerationConfig(temperature: 0.0, effort: .high)
      #expect(config.thinkingConfig == nil, "\(model.rawValue)")
    }
  }

  @Test("Chatty preambles are stripped; real speech and a preamble-only answer are kept")
  func preambleCleanup() {
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

    // Real speech that merely mentions transcription is left alone.
    let spoken = "Testing 1, 2, 3."
    #expect(TextProcessingUtility.strippingTranscriptionPreamble(spoken) == spoken)
    let mentions = "The transcription quality has improved a lot lately."
    #expect(TextProcessingUtility.strippingTranscriptionPreamble(mentions) == mentions)

    // A preamble that is the whole answer is kept, so validation can reject it.
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

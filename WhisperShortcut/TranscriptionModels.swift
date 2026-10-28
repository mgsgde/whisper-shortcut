//
//  TranscriptionModels.swift
//  WhisperShortcut
//
//  Data models for transcription API interactions (Gemini, OpenAI, xAI, self-hosted, offline Whisper)
//

import Foundation

/// The two request knobs that apply to every cloud transcription, read straight from UserDefaults.
///
/// Deliberately not threaded through the call sites: `SpeechService`, `ChunkTranscriptionService`
/// and the meeting path all build their requests from `TranscriptionModel`, so reading the settings
/// where the request body is assembled is the only way for all three to stay in agreement.
enum TranscriptionTuning {
  static var temperature: Double {
    guard let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.transcriptionTemperature),
          let parsed = TranscriptionTemperature(rawValue: raw)
    else { return SettingsDefaults.transcriptionTemperature.value }
    return parsed.value
  }

  static var thinkingEffort: TranscriptionThinkingEffort {
    guard let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.transcriptionThinkingEffort),
          let parsed = TranscriptionThinkingEffort(rawValue: raw)
    else { return SettingsDefaults.transcriptionThinkingEffort }
    return parsed
  }

  /// Model slug sent to OpenRouter.
  static var openRouterModelID: String {
    resolveOpenRouterModelID(
      UserDefaults.standard.string(forKey: UserDefaultsKeys.openRouterTranscriptionModelID))
  }

  /// Empty (user cleared the field) falls back to the default rather than sending no model, which
  /// OpenRouter rejects. Pure so it can be tested without writing to the shared UserDefaults.
  static func resolveOpenRouterModelID(_ stored: String?) -> String {
    let trimmed = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? SettingsDefaults.openRouterTranscriptionModelID : trimmed
  }
}

// MARK: - Transcription Model Enum
// Current Gemini model IDs: https://ai.google.dev/gemini-api/docs/models (Gemini API, not Vertex AI).
// GA (stable IDs, no -preview): gemini-3.1-flash-lite, gemini-3.5-flash-lite,
// gemini-3.8-flash, gemini-4-argon. Preview (keep -preview): gemini-3.1-pro-preview.
// gemini-3.1-pro-preview and gemini-4-argon are present but **not offered for dictation**,
// see `isSelectableForDictation`.
// gemini-3.1-flash-lite is GA but *on the deprecation clock*: shutdown 2027-05-07, Google names
// gemini-3.5-flash-lite as the replacement. We deliberately do not follow that pointer — see the
// measurement note in `plans/model-audits/2026-09-03-audit.md`. Revisit by early 2027.
// Removed and forwarded via migrateLegacyTranscriptionRawValue: both Pro slugs
// (gemini-3-pro-preview, shut down by Google 2026-03-09, and gemini-3.1-pro-preview, withdrawn
// 2026-08-03 because it never answers a short dictation) → gemini-3.1-flash-lite; the Gemini 2.5
// family (gemini-2.5-flash / -flash-lite, shutdown 2026-10-16) → gemini-3.8-flash /
// gemini-3.1-flash-lite; gemini-3-flash-preview (deprecated-pending) → gemini-3.8-flash;
// gemini-3.5-flash and gemini-3.6-flash (removed 2026-10-19, dominated by 3.7) → gemini-3.8-flash;
// gemini-3.7-flash (removed 2026-10-21 because Google routes it to 3.8) → gemini-3.8-flash.
// Do not offer a Pro tier for dictation without benchmarking the 1.3 s case first.
enum TranscriptionModel: String, CaseIterable {
  // Gemini models (online)
  /// Not selectable for dictation — flagship reasoning is far too slow and expensive for it.
  /// The case stays so `PromptModel.asTranscriptionModel` can resolve the Gemini endpoint.
  case gemini4Argon = "gemini-4-argon"
  /// **Not selectable for dictation** — excluded from every picker via `isSelectableForDictation`,
  /// and persisted selections are migrated away. The case survives only because `PromptModel`
  /// borrows this enum to resolve its Gemini endpoint (`PromptModel.asTranscriptionModel`), which
  /// Dictate Prompt and Smart Improvement both depend on. Removing the case would break those.
  case gemini31Pro = "gemini-3.1-pro-preview"
  case gemini31FlashLite = "gemini-3.1-flash-lite"
  case gemini35FlashLite = "gemini-3.5-flash-lite"
  case gemini38Flash = "gemini-3.8-flash"

  // Offline Whisper models
  case whisperTiny = "whisper-tiny"
  case whisperBase = "whisper-base"
  case whisperSmall = "whisper-small"
  case whisperMedium = "whisper-medium"
  case whisperLarge = "whisper-large"
  /// large-v3-turbo: large-v3's encoder with a 4-layer decoder instead of 32. Half the download
  /// and several times faster than `whisperLarge` at the same accuracy, which makes it — not
  /// `large-v3` — the on-device model to reach for when the transcript has to be right.
  case whisperLargeTurbo = "whisper-large-turbo"
  /// Offline, but not Whisper: NVIDIA Parakeet TDT (Moondream's "Ultra" retrain) through
  /// FluidAudio. Same accuracy as turbo on the user's German at ~1/20 of the wait
  /// (`benchmarks/local-asr/README.md`). Raw value matches `OfflineModelType.parakeetUltra`.
  case parakeetUltra = "parakeet-ultra"

  // OpenAI transcription models (cloud, OpenAI API key required).
  // `gpt-transcribe` is OpenAI's recommended starting model; the gpt-4o pair is explicitly
  // "not the recommended starting model for a new transcription integration"
  // (https://developers.openai.com/api/docs/guides/transcription). All three stay: the gpt-4o
  // family follows instructions in `prompt` (which gpt-transcribe does not) and mini is the
  // cheapest tier, so neither is dominated.
  case openAIGPTTranscribe = "openai-gpt-transcribe"
  case openAIGPT4oTranscribe = "openai-gpt-4o-transcribe"
  case openAIGPT4oMiniTranscribe = "openai-gpt-4o-mini-transcribe"

  // xAI Grok transcription (cloud, xAI API key required) — POST /v1/stt, multipart, model=grok-stt.
  case xaiTranscribe = "grok-stt"

  // Self-hosted transcription endpoint (any OpenAI /v1/audio/transcriptions–compatible endpoint, e.g.
  // faster-whisper-server, whisper-asr-webservice, or any proxy). Raw value kept stable from the
  // original "Custom Transcription API" feature so existing UserDefaults selections still resolve.
  case selfHostedTranscription = "custom-transcription-api"

  // OpenRouter (cloud, OpenRouter API key required). OpenRouter exposes NO /v1/audio/transcriptions —
  // audio goes to /api/v1/chat/completions as an `input_audio` content part (verified against
  // https://openrouter.ai/docs/features/multimodal/audio), which is why this cannot reuse
  // `.selfHostedTranscription`'s multipart path. The model slug is user-configurable, so one entry
  // covers every audio-capable model OpenRouter routes to.
  case openRouterTranscription = "openrouter-transcription"

  var displayName: String {
    switch self {
    case .gemini4Argon:
      return "Gemini 4 Argon"
    case .gemini31Pro:
      return "Gemini 3.1 Pro"
    case .gemini31FlashLite:
      return "Gemini 3.1 Flash-Lite"
    case .gemini35FlashLite:
      return "Gemini 3.5 Flash-Lite"
    case .gemini38Flash:
      return "Gemini 3.8 Flash"
    case .whisperTiny:
      return String(localized: "Whisper Tiny (Offline)")
    case .whisperBase:
      return String(localized: "Whisper Base (Offline)")
    case .whisperSmall:
      return String(localized: "Whisper Small (Offline)")
    case .whisperMedium:
      return String(localized: "Whisper Medium (Offline)")
    case .whisperLarge:
      return String(localized: "Whisper Large (Offline)")
    case .whisperLargeTurbo:
      return String(localized: "Whisper Large v3 Turbo (Offline)")
    case .parakeetUltra:
      return String(localized: "Parakeet Ultra (Offline)")
    case .openAIGPTTranscribe:
      return "GPT Transcribe"
    case .openAIGPT4oTranscribe:
      return "GPT-4o Transcribe"
    case .openAIGPT4oMiniTranscribe:
      return "GPT-4o Mini Transcribe"
    case .xaiTranscribe:
      return "Grok Speech-to-Text"
    case .selfHostedTranscription:
      return String(localized: "Own server")
    case .openRouterTranscription:
      return "OpenRouter"
    }
  }

  /// Uses v1beta so Gemini 3 preview models are available (v1 returns 404 for them).
  ///
  /// Every provider but Google has one fixed endpoint, so it is declared once on
  /// `TranscriptionProvider`. Google's embeds the model id — which is exactly this enum's raw
  /// value, so the five Gemini rows are one template rather than five spelled-out URLs that had to
  /// be edited by hand whenever a model was added.
  var apiEndpoint: String {
    if let fixed = provider.fixedEndpoint { return fixed }
    return "https://generativelanguage.googleapis.com/v1beta/models/\(rawValue):generateContent"
  }

  /// Upstream OpenAI model ID used as the `model` form field on POSTs to /v1/audio/transcriptions.
  /// Nil for models that do not route through an OpenAI-compatible endpoint.
  var openAIAPIModelID: String? {
    switch self {
    case .openAIGPTTranscribe: return "gpt-transcribe"
    case .openAIGPT4oTranscribe: return "gpt-4o-transcribe"
    case .openAIGPT4oMiniTranscribe: return "gpt-4o-mini-transcribe"
    default: return nil
    }
  }

  /// Whether this model may be offered as a dictation / meeting transcription choice.
  ///
  /// Mirrors `PromptModel.isSelectableInChat`: the case stays in the enum so persisted values and
  /// internal lookups keep resolving, but pickers never show it.
  ///
  /// `gemini31Pro` and `gemini4Argon` are excluded. Measured 2026-08-03 against the 1.3 s fixture,
  /// 3.1 Pro returns no response at all when sent any real transcription prompt — 4/4, including a
  /// 300 s attempt that received zero bytes, while a trivial-prompt control answered in ~6 s between
  /// the failures. Rewording the prompt does not help (an unrelated 436-char instruction fails the
  /// same way) and neither does streaming. With `SpeechService.Constants.resourceTimeout` at 300 s,
  /// offering it meant a five-minute freeze for anyone who dictated a short phrase.
  /// Detail: plans/model-audits/2026-08-03-audit.md.
  /// Gemini 4 Argon is flagship reasoning, far too slow and expensive for dictation, so it stays
  /// out of the pickers the same way.
  var isSelectableForDictation: Bool {
    switch self {
    case .gemini4Argon, .gemini31Pro: return false
    // Whisper Medium and Large v3 are superseded by turbo (see `OfflineModelType.isSuperseded`).
    // Unlike the Gemini exclusions these are not broken, only dominated, so a user who already
    // downloaded one keeps it offered — hiding a model that is on disk and working would take a
    // working setup away to make a point.
    case .whisperMedium, .whisperLarge: return isOfflineModelAvailable()
    default: return true
    }
  }

  /// Every model a user may actually pick for dictation. Pickers default to this, not `allCases`.
  ///
  /// Offline Mode narrows it to what runs on this Mac. Showing a cloud model there would offer a
  /// choice the network guard then refuses — the picker and `OfflineModeURLProtocol` have to agree
  /// on what is possible, and this is the side that can explain itself.
  static var selectableForDictation: [TranscriptionModel] {
    selectableForDictation(offlineMode: OfflineMode.isEnabled)
  }

  /// The same list with the mode passed in, so the narrowing can be tested without switching the
  /// real mode on process-wide.
  static func selectableForDictation(offlineMode: Bool) -> [TranscriptionModel] {
    let selectable = allCases.filter { $0.isSelectableForDictation }
    guard offlineMode else { return selectable }
    return selectable.filter(\.runsOnThisMac)
  }

  /// Whether running this model sends nothing to the internet. Offline Whisper always qualifies;
  /// a self-hosted endpoint qualifies when the user pointed it at their own machine or network,
  /// which is the same rule the network guard applies.
  var runsOnThisMac: Bool {
    switch provider {
    case .offline:
      return true
    case .selfHosted:
      let raw = CustomEndpointPreferences.transcriptionURL ?? ""
      return OfflineMode.allows(URL(string: raw))
    case .google, .openAI, .xai, .openRouter:
      return false
    }
  }

  var isRecommended: Bool {
    switch self {
    // The offline recommendation is Parakeet Ultra: turbo's accuracy on real German dictation at
    // ~1/20 of the wait, and less than half the download (`benchmarks/local-asr/README.md`).
    // Base remains the quick way to try offline at 140 MB.
    // Cloud: the app default, see `SettingsDefaults.selectedTranscriptionModel`.
    case .openAIGPTTranscribe:
      return true
    // Language-dependent (Parakeet covers 25 languages); one source of truth for both pickers.
    case .parakeetUltra, .whisperLargeTurbo:
      return offlineModelType?.isRecommended ?? false
    case .gemini4Argon, .gemini31Pro, .gemini31FlashLite, .gemini35FlashLite,
         .gemini38Flash, .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium,
         .whisperLarge, .openAIGPT4oTranscribe, .openAIGPT4oMiniTranscribe, .xaiTranscribe,
         .selfHostedTranscription, .openRouterTranscription:
      return false
    }
  }

  /// Gemini 2.0 family was removed from this enum; no transcription option is deprecated in-app.
  var isDeprecated: Bool { false }

  var costLevel: CostLevel {
    switch self {
    case .gemini31FlashLite, .gemini35FlashLite,
         .gemini38Flash:
      return .low
    case .gemini4Argon:
      return .high
    case .gemini31Pro:
      return .medium
    case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge,
         .whisperLargeTurbo, .parakeetUltra:
      return .freeOffline
    case .openAIGPTTranscribe:
      return .low
    case .openAIGPT4oTranscribe:
      return .medium
    case .openAIGPT4oMiniTranscribe:
      return .low
    case .xaiTranscribe:
      return .low
    case .selfHostedTranscription:
      return .custom
    case .openRouterTranscription:
      return .varies
    }
  }

  var description: String {
    switch self {
    case .gemini4Argon:
      return String(localized: "Google's Gemini 4 Argon • Flagship reasoning for hard research questions • Paid (no free tier)")
    case .gemini31Pro:
      return String(localized: "Google's Gemini 3.1 Pro model • Complex reasoning and agentic workflows • Multimodal")
    case .gemini31FlashLite:
      return String(localized: "Google's Gemini 3.1 Flash-Lite • Fastest, most cost-efficient 3-series • Ideal for dictation")
    case .gemini35FlashLite:
      return String(localized: "Google's Gemini 3.5 Flash-Lite • Cheapest audio input ($0.30/1M) • Fast, high-throughput")
    case .gemini38Flash:
      return String(localized: "Google's Gemini 3.8 Flash • Most intelligent Flash • Most capable workhorse for coding and agents")
    case .whisperTiny:
      return String(localized: "OpenAI Whisper Tiny • Fastest • ~75MB • Offline")
    case .whisperBase:
      return String(localized: "OpenAI Whisper Base • Small download • ~140MB • Offline")
    case .whisperSmall:
      return String(localized: "OpenAI Whisper Small • Better quality • ~460MB • Offline")
    case .whisperMedium:
      return String(localized: "OpenAI Whisper Medium • Best quality • ~1.5GB • Offline")
    case .whisperLarge:
      return String(localized: "OpenAI Whisper Large v3 • Highest quality • ~3GB • Offline")
    case .whisperLargeTurbo:
      return String(localized: "OpenAI Whisper Large v3 Turbo • Large-v3 accuracy at a fraction of the time • ~1.6GB • Offline")
    case .parakeetUltra:
      return String(localized: "NVIDIA Parakeet Ultra • Turbo's accuracy, about 20× faster • 25 European languages • ~700MB • Offline")
    case .openAIGPTTranscribe:
      return String(localized: "OpenAI's current transcription model • $0.0045/min • Glossary sent as keyword hints • Ignores the Dictation prompt")
    case .openAIGPT4oTranscribe:
      return String(localized: "OpenAI's flagship audio transcription model • High accuracy • Cloud")
    case .openAIGPT4oMiniTranscribe:
      return String(localized: "OpenAI's faster, cheaper transcription model • Cloud")
    case .xaiTranscribe:
      return String(localized: "xAI's Grok Speech-to-Text • Cloud • Requires xAI API key")
    case .selfHostedTranscription:
      return String(localized: "Transcribes on your own OpenAI-compatible server (LiteLLM, Azure, faster-whisper-server, …), the same one Chat and Dictate Prompt can use")
    case .openRouterTranscription:
      return String(localized: "Any audio-capable model on OpenRouter • Pick the model in Dictate settings • Connect your OpenRouter account in Settings → Accounts")
    }
  }
  
  /// `generationConfig` to send with a Gemini transcription request: the user's thinking effort and
  /// temperature, clamped to what this tier actually accepts. Both knobs are read here rather than
  /// threaded through every call site, so the chunked meeting path picks them up too.
  ///
  /// Every tier also gets `maxOutputTokens` — the init supplies it, so a tier added later is capped
  /// whether or not whoever adds it thinks about billing. See the constant for why that matters.
  var geminiTranscriptionGenerationConfig: GeminiTranscriptionRequest.GeminiTranscriptionGenerationConfig {
    geminiTranscriptionGenerationConfig(
      temperature: TranscriptionTuning.temperature, effort: TranscriptionTuning.thinkingEffort)
  }

  /// The same, with the settings passed in — pure, so the per-tier clamping can be tested without
  /// writing to the shared UserDefaults (which raced the settings round-trip suite).
  func geminiTranscriptionGenerationConfig(
    temperature: Double, effort: TranscriptionThinkingEffort
  ) -> GeminiTranscriptionRequest.GeminiTranscriptionGenerationConfig {
    switch self {
    case .gemini31FlashLite, .gemini35FlashLite:
      return .init(
        thinkingConfig: .init(thinkingLevel: effort.geminiValue, thinkingBudget: nil),
        temperature: temperature)
    case .gemini4Argon, .gemini31Pro, .gemini38Flash:
      // Argon, 3.1 Pro, and 3.8 Flash reject `thinkingLevel: minimal` (HTTP 400) and
      // `thinkingBudget: 0` — they only run in thinking mode. Argon documents low/medium/high
      // only. `minimal` therefore means "as little as this model allows", i.e. `low`.
      // Verified live: 3.8 Flash 2026-09-06 (minimal → 400, low → 200).
      let level = effort == .minimal ? TranscriptionThinkingEffort.low : effort
      return .init(
        thinkingConfig: .init(thinkingLevel: level.geminiValue, thinkingBudget: nil),
        temperature: temperature)
    default:
      return .init(thinkingConfig: nil, temperature: temperature)
    }
  }

  var isGemini: Bool { provider == .google }

  /// True for models that route through xAI's hosted /v1/stt endpoint (user pays via xAI API key).
  var isXAI: Bool { provider == .xai }

  /// Whether the user currently has what this transcription model needs to run: the matching
  /// provider API key (Gemini / OpenAI / xAI), a downloaded offline Whisper model, or a configured
  /// self-hosted endpoint. Drives menu enablement so dictation works with any single provider key.
  var hasRequiredCredential: Bool {
    // Offline is the one provider whose answer is per model, not per provider: availability means
    // "is *this* Whisper file downloaded".
    if provider == .offline { return isOfflineModelAvailable() }
    return provider.hasCredential
  }

  /// Popup title matching `apiKeyRequiredMessage`.
  var credentialRequiredTitle: String { provider.credentialRequiredTitle }

  /// Actionable message shown when this transcription model can't run for lack of a credential.
  var apiKeyRequiredMessage: String { provider.credentialRequiredMessage }

  /// True for models that route through OpenAI's *hosted* /v1/audio/transcriptions endpoint
  /// (i.e. user pays via their OpenAI API key). Does NOT include `.selfHostedTranscription`,
  /// which uses the same OpenAI wire format but points at a user-controlled endpoint.
  var isOpenAI: Bool { provider == .openAI }

  var isOffline: Bool { provider == .offline }

  /// Whether this model actually acts on the dictation **system prompt**.
  ///
  /// The Settings editor presents one "System prompt" for every model, so a model that silently
  /// drops it makes the app lie: the prompt's first rule is "Remove disfluencies silently", and a
  /// user on `gpt-transcribe` gets every "ähm" back with no indication why. `SpeechToTextSettingsTab`
  /// says so out loud instead, and this property is what it asks.
  ///
  /// Two families answer false, for opposite reasons:
  /// - `.openAIGPTTranscribe` is a pure ASR model with dedicated context fields. It ignores
  ///   instructions in `prompt`, and forwarding them *hurts* — measured 2026-08-02, with the
  ///   dictation prompt attached "WhisperShortcut" degraded to "Whisper Shortcut" in 2 of 3 runs
  ///   against 5 of 5 correct on keywords alone. `sendOpenAICompatibleTranscriptionRequest`
  ///   therefore drops it on purpose; the vocabulary still arrives, as `keywords`.
  /// - Offline Whisper's API accepts no instructions at all, only the Glossary as priming text.
  ///
  /// Not consulted by the request builders — they key off the wire-level model id, which is the
  /// distinction that matters there. Keep this in agreement with `isContextFieldStyle` in
  /// `SpeechService` (both resolve `.openAIGPTTranscribe` through `openAIAPIModelID`).
  var honorsSystemPrompt: Bool {
    switch self {
    case .openAIGPTTranscribe: return false
    // Provider-wide, not model-by-model: the hand-kept list here and in
    // `systemPromptIgnoredReason` both missed `whisperLargeTurbo` when it was added, which is how
    // the recommended offline model ended up presented as prompt-honouring. No offline model can
    // take an instruction, so the provider is the right granularity.
    case _ where provider == .offline: return false
    default: return true
    }
  }

  /// Why `honorsSystemPrompt` is false, phrased for the Settings tab. Nil when it is true.
  var systemPromptIgnoredReason: String? {
    switch self {
    case .openAIGPTTranscribe:
      return String(localized: "\(displayName) ignores the system prompt below — it is a pure speech-recognition model, not an instructable one. Filler-word removal, punctuation and formatting rules have no effect; your Glossary still applies, as keyword hints. Pick a Gemini model or GPT-4o Transcribe if you want the prompt honoured.")
    // Provider-wide rather than case-by-case: this list was spelled out per model and
    // `whisperLargeTurbo` was added to the enum without being added here, so the newest — and
    // recommended — offline model was the one showing an inert prompt editor with no warning.
    case _ where provider == .offline:
      return String(localized: "Offline models ignore the system prompt below — they accept no instructions. Only the Glossary reaches them: as conditioning text for Whisper, as terms Parakeet listens for.")
    default:
      return nil
    }
  }
  
  var offlineModelType: OfflineModelType? {
    switch self {
    case .whisperTiny: return .whisperTiny
    case .whisperBase: return .whisperBase
    case .whisperSmall: return .whisperSmall
    case .whisperMedium: return .whisperMedium
    case .whisperLarge: return .whisperLarge
    case .whisperLargeTurbo: return .whisperLargeTurbo
    case .parakeetUltra: return .parakeetUltra
    default: return nil
    }
  }

  /// The dictation selection that runs a given on-device model. Inverse of `offlineModelType`.
  static func forOfflineModel(_ type: OfflineModelType) -> TranscriptionModel {
    switch type {
    case .whisperTiny: return .whisperTiny
    case .whisperBase: return .whisperBase
    case .whisperSmall: return .whisperSmall
    case .whisperMedium: return .whisperMedium
    case .whisperLarge: return .whisperLarge
    case .whisperLargeTurbo: return .whisperLargeTurbo
    case .parakeetUltra: return .parakeetUltra
    }
  }
  
  // MARK: - Model Loading
  /// Loads the selected transcription model from UserDefaults, or returns the default model.
  /// When in subscription mode (no API key, signed in with Google), returns the saved model if it is an offline Whisper model; otherwise returns the fixed subscription (Gemini) model.
  /// Migrates removed models (gemini-2.0-flash, gemini-2.0-flash-lite) to current equivalents.
  static func loadSelected() -> TranscriptionModel {
    guard let savedModelString = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedTranscriptionModel) else {
      return SettingsDefaults.selectedTranscriptionModel
    }
    let migrated = migrateLegacyTranscriptionRawValue(savedModelString)
    if migrated != savedModelString {
      UserDefaults.standard.set(migrated, forKey: UserDefaultsKeys.selectedTranscriptionModel)
    }
    if let savedModel = TranscriptionModel(rawValue: migrated) {
      return savedModel
    }
    UserDefaults.standard.set(
      SettingsDefaults.selectedTranscriptionModel.rawValue,
      forKey: UserDefaultsKeys.selectedTranscriptionModel)
    return SettingsDefaults.selectedTranscriptionModel
  }

  /// Loads the transcription model for live meetings. If not set, returns the Dictate model (loadSelected()).
  static func loadSelectedForMeeting() -> TranscriptionModel {
    guard let savedModelString = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings) else {
      return loadSelected()
    }
    let migrated = migrateLegacyTranscriptionRawValue(savedModelString)
    if migrated != savedModelString {
      UserDefaults.standard.set(migrated, forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings)
    }
    if let savedModel = TranscriptionModel(rawValue: migrated) {
      return savedModel
    }
    return loadSelected()
  }

  /// Maps retired/renamed transcription raw values to current ones so persisted
  /// UserDefaults selections keep resolving after enum changes.
  static func migrateLegacyTranscriptionRawValue(_ raw: String) -> String {
    switch raw {
    case "gemini-2.0-flash", "gemini-2.0-flash-lite":
      return TranscriptionModel.gemini31FlashLite.rawValue
    case "gemini-3.1-flash-lite-preview":
      // GA replaced the -preview slug; same model, stable ID.
      return TranscriptionModel.gemini31FlashLite.rawValue
    case "gemini-3-pro-preview", "gemini-3.1-pro-preview":
      // No Pro tier is offered for transcription any more, so both Pro slugs land on Flash-Lite.
      //
      // gemini-3-pro-preview was shut down by Google 2026-03-09 (404) and used to forward to
      // gemini-3.1-pro-preview. That target was itself removed on 2026-08-03: measured against the
      // 1.3 s fixture it returns *nothing* — 4/4 no response, including a 300 s attempt that got
      // zero bytes, while a trivial-prompt control answered in ~6 s between the failures. Neither
      // rewording the prompt nor switching to streaming helps, and the app's own request timeout is
      // 300 s, so leaving it selectable meant a five-minute freeze on any short dictation.
      // Detail: plans/model-audits/2026-08-03-audit.md.
      return TranscriptionModel.gemini31FlashLite.rawValue
    case "gemini-2.5-flash":
      // Deprecated, shutdown 2026-10-16; 3.5 and 3.7 Flash were removed, so forward to 3.8.
      return TranscriptionModel.gemini38Flash.rawValue
    case "gemini-2.5-flash-lite":
      // Deprecated, shutdown 2026-10-16; replacement is the current Flash-Lite.
      return TranscriptionModel.gemini31FlashLite.rawValue
    case "gemini-3.6-flash":
      // Removed 2026-10-19: dominated by 3.7 on price, tier and speed. 3.7 was removed
      // 2026-10-21 (Google routes it to 3.8), so this lands on 3.8.
      return TranscriptionModel.gemini38Flash.rawValue
    case "gemini-3.7-flash":
      // Removed 2026-10-21: Google routes every request to gemini-3.8-flash (dead alias, same price).
      return TranscriptionModel.gemini38Flash.rawValue
    case "gemini-3-flash-preview":
      // Deprecated-pending; 3.5 and 3.7 Flash were removed, so forward to 3.8.
      return TranscriptionModel.gemini38Flash.rawValue
    case "gemini-3.5-flash":
      // Removed 2026-10-19: dominated by 3.7 on price and tier. Forwards to 3.8 with 3.7.
      return TranscriptionModel.gemini38Flash.rawValue
    default:
      return raw
    }
  }

  // MARK: - Model Availability
  /// Checks if this model is an offline model and if it's available
  /// - Returns: True if the model is offline and available, false otherwise
  func isOfflineModelAvailable() -> Bool {
    guard isOffline, let offlineModelType = offlineModelType else {
      return false
    }
    return ModelManager.shared.isModelAvailable(offlineModelType)
  }

  // MARK: - Smart Improvement Audio Verification

  /// Coarse capability tier used by Smart Improvement to decide whether re-listening to audio
  /// produced by another model can add information. Within Gemini, Pro > Flash > Flash-Lite.
  /// Non-Gemini backends (offline Whisper, OpenAI cloud, self-hosted OpenAI-compatible endpoints)
  /// are treated as separate families that Gemini can always informatively verify.
  enum AsymmetryClass: Int {
    case offlineWhisper
    case openAIAudio
    case xaiAudio
    case selfHostedTranscription
    case openRouterAudio
    case geminiFlashLite
    case geminiFlash
    case geminiPro
  }

  var asymmetryClass: AsymmetryClass {
    switch self {
    // Parakeet shares the class: what matters here is "not Gemini, so Gemini re-listening adds
    // information", not which on-device engine produced the transcript.
    case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge,
         .whisperLargeTurbo, .parakeetUltra:
      return .offlineWhisper
    case .openAIGPTTranscribe, .openAIGPT4oTranscribe, .openAIGPT4oMiniTranscribe:
      return .openAIAudio
    case .xaiTranscribe:
      return .xaiAudio
    case .selfHostedTranscription:
      return .selfHostedTranscription
    case .openRouterTranscription:
      return .openRouterAudio
    case .gemini31FlashLite, .gemini35FlashLite:
      return .geminiFlashLite
    case .gemini38Flash:
      return .geminiFlash
    case .gemini4Argon, .gemini31Pro:
      return .geminiPro
    }
  }

  /// Returns true when Smart Improvement using `self` can plausibly add information by re-listening
  /// to audio originally transcribed by `transcriptionModel`. Audio from non-Gemini backends always
  /// benefits from Gemini verification (different family). Same-family Gemini verification only adds
  /// information when `self` is strictly in a higher tier.
  func canInformativelyVerify(audioFrom transcriptionModel: TranscriptionModel) -> Bool {
    switch transcriptionModel.asymmetryClass {
    case .offlineWhisper, .openAIAudio, .xaiAudio, .selfHostedTranscription, .openRouterAudio:
      return self.isGemini
    default:
      guard self.isGemini else { return false }
      return self.asymmetryClass.rawValue > transcriptionModel.asymmetryClass.rawValue
    }
  }

}

// MARK: - Gemini Transcription Request Models
struct GeminiTranscriptionRequest: Codable {
  let contents: [GeminiTranscriptionContent]
  let generationConfig: GeminiTranscriptionGenerationConfig?

  struct GeminiTranscriptionContent: Codable {
    let parts: [GeminiTranscriptionPart]
  }

  /// `generationConfig` for transcription: how hard the model may think, and how freely it may
  /// sample. Built by `TranscriptionModel.geminiTranscriptionGenerationConfig`.
  ///
  /// The thinking knob is model-dependent, and getting it wrong is a hard HTTP 400 (verified against
  /// the live API with real audio, 2026-07):
  ///   - `thinkingBudget: 0` — accepted by 2.5 and 3.1, **rejected by 3.5 / 3.6 / 3.7**
  ///     ("Request contains an invalid argument").
  ///   - `thinkingLevel` — Flash / Flash-Lite through 3.6 accept all four levels
  ///     (`minimal`/`low`/`medium`/`high`) *with audio input*; Pro and 3.7 Flash accept all
  ///     but `minimal` ("Thinking level MINIMAL is not supported for this model").
  ///
  /// `temperature` is accepted alongside audio on every tier. Omitting it is not neutral: the model
  /// default is `1.0` (`GET /v1beta/models/{id}` reports `temperature: 1, maxTemperature: 2`), which
  /// is why it is now always sent.
  /// Docs: https://ai.google.dev/gemini-api/docs/thinking
  struct GeminiTranscriptionGenerationConfig: Codable {
    /// Hard ceiling on a single transcription response, thinking tokens included.
    ///
    /// The app-wide cost fuse (`AppConstants.llmMaxOutputTokens`) applied to transcription; see
    /// there for why it exists and what it cost to learn. Nothing about transcription wants a
    /// tighter value than the shared one: meeting chunks cap at 60 s, and even continuous dictation
    /// would need ~40 minutes of speech to reach 8192 tokens. A transcription that hits this is a
    /// runaway, not a long dictation.
    static let maxOutputTokens = AppConstants.llmMaxOutputTokens

    let thinkingConfig: GeminiThinkingConfig?
    let temperature: Double?
    let maxOutputTokens: Int?

    init(
      thinkingConfig: GeminiThinkingConfig?, temperature: Double? = nil,
      maxOutputTokens: Int? = GeminiTranscriptionGenerationConfig.maxOutputTokens
    ) {
      self.thinkingConfig = thinkingConfig
      self.temperature = temperature
      self.maxOutputTokens = maxOutputTokens
    }
  }

  struct GeminiThinkingConfig: Codable {
    let thinkingLevel: String?
    let thinkingBudget: Int?
  }

  struct GeminiTranscriptionPart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
    let fileData: GeminiFileData?

    enum CodingKeys: String, CodingKey {
      case text
      case inlineData = "inline_data"
      case fileData = "file_data"
    }

    static func text(_ s: String) -> GeminiTranscriptionPart {
      GeminiTranscriptionPart(text: s, inlineData: nil, fileData: nil)
    }

    static func inline(mimeType: String, data: String) -> GeminiTranscriptionPart {
      GeminiTranscriptionPart(
        text: nil,
        inlineData: GeminiInlineData(mimeType: mimeType, data: data),
        fileData: nil
      )
    }

    static func file(uri: String, mimeType: String) -> GeminiTranscriptionPart {
      GeminiTranscriptionPart(
        text: nil,
        inlineData: nil,
        fileData: GeminiFileData(fileUri: uri, mimeType: mimeType)
      )
    }
  }
  
  struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String
    
    enum CodingKeys: String, CodingKey {
      case mimeType  // API returns "mimeType" (camelCase), not "mime_type"
      case data
    }
  }
  
  struct GeminiFileData: Codable {
    let fileUri: String
    let mimeType: String
    
    enum CodingKeys: String, CodingKey {
      case fileUri = "file_uri"
      case mimeType = "mime_type"
    }
  }
}

// MARK: - Gemini Response Models
struct GeminiResponse: Codable {
  let candidates: [GeminiCandidate]
  let usageMetadata: GeminiUsageMetadata?

  struct GeminiCandidate: Codable {
    let content: GeminiContent?
    let groundingMetadata: GeminiGroundingMetadata?
    let finishReason: String?
  }

  struct GeminiUsageMetadata: Codable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let totalTokenCount: Int?
    let cachedContentTokenCount: Int?
    let thoughtsTokenCount: Int?
    /// Tokens the built-in tools (Google Search, URL context, code execution) fed back into the
    /// prompt. Grows by 10–30k per grounding round — the only sign that the model is searching.
    let toolUsePromptTokenCount: Int?
  }

  struct GeminiGroundingMetadata: Codable {
    let groundingChunks: [GeminiGroundingChunk]?
    let groundingSupports: [GeminiGroundingSupport]?
    let webSearchQueries: [String]?

    struct GeminiGroundingChunk: Codable {
      let web: WebSource?

      struct WebSource: Codable {
        let uri: String?
        let title: String?
      }
    }

    struct GeminiGroundingSupport: Codable {
      let segment: GeminiGroundingSegment?
      let groundingChunkIndices: [Int]?

      struct GeminiGroundingSegment: Codable {
        let startIndex: Int?
        let endIndex: Int?
      }
    }
  }
  
  struct GeminiContent: Codable {
    let parts: [GeminiPart]?
  }
  
  struct GeminiPart: Codable {
    let text: String?
    /// `true` when this part is the model's internal reasoning (thinking) rather than the
    /// user-facing answer. Such parts must never be shown to the user — see `extractText`.
    let thought: Bool?
    /// Code generated by the model for execution (Python only).
    let executableCode: ExecutableCode?
    /// Result of running the generated code (stdout on success).
    let codeExecutionResult: CodeExecutionResult?
    /// Inline binary data (e.g. generated images) returned by the model.
    let inlineData: InlineData?

    struct ExecutableCode: Codable {
      let language: String?
      let code: String?
    }

    struct CodeExecutionResult: Codable {
      let outcome: String?
      let output: String?
    }

    struct InlineData: Codable {
      let mimeType: String
      let data: String // Base64-encoded
    }
  }
}

struct GeminiFileInfo: Codable {
  let file: GeminiFile
  
  struct GeminiFile: Codable {
    let uri: String
  }
}

// MARK: - Gemini Chat Request/Response Models (for multimodal prompt/voice response modes)
struct GeminiChatRequest: Codable {
  let contents: [GeminiChatContent]
  let systemInstruction: GeminiSystemInstruction?
  let tools: [GeminiTool]?
  let generationConfig: GeminiGenerationConfig?
  let model: String?  // Optional model field (required for TTS models)

  enum CodingKeys: String, CodingKey {
    case contents
    case systemInstruction = "system_instruction"
    case tools
    case generationConfig = "generationConfig"
    case model
  }
  
  // MARK: - Generation Config
  struct GeminiGenerationConfig: Codable {
    let responseModalities: [String]?
    let speechConfig: GeminiSpeechConfig?
    
    enum CodingKeys: String, CodingKey {
      case responseModalities = "responseModalities"
      case speechConfig = "speechConfig"
    }
  }
  
  struct GeminiChatContent: Codable {
    let role: String  // "user" or "model"
    let parts: [GeminiChatPart]
  }
  
  struct GeminiChatPart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
    let fileData: GeminiFileData?
    let url: String?
    
    enum CodingKeys: String, CodingKey {
      case text
      case inlineData = "inline_data"
      case fileData = "file_data"
      case url
    }
  }
  
  struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String
    
    enum CodingKeys: String, CodingKey {
      case mimeType  // API returns "mimeType" (camelCase), not "mime_type"
      case data
    }
  }
  
  struct GeminiFileData: Codable {
    let fileUri: String
    let mimeType: String
    
    enum CodingKeys: String, CodingKey {
      case fileUri = "file_uri"
      case mimeType = "mime_type"
    }
  }
  
  struct GeminiSystemInstruction: Codable {
    let parts: [GeminiSystemPart]
  }
  
  struct GeminiSystemPart: Codable {
    let text: String
  }
  
  // MARK: - Gemini Tools
  struct GeminiTool: Codable {
    let googleSearch: GoogleSearch?
    
    enum CodingKeys: String, CodingKey {
      case googleSearch = "google_search"
    }
    
    struct GoogleSearch: Codable {
      // Empty struct - Google Search tool requires no parameters
    }
  }
  
  // MARK: - Audio Output Configuration
  struct GeminiSpeechConfig: Codable {
    let voiceConfig: GeminiVoiceConfig?
    
    enum CodingKeys: String, CodingKey {
      case voiceConfig = "voice_config"
    }
  }
  
  struct GeminiVoiceConfig: Codable {
    let prebuiltVoiceConfig: GeminiPrebuiltVoiceConfig?
    
    enum CodingKeys: String, CodingKey {
      case prebuiltVoiceConfig = "prebuilt_voice_config"
    }
  }
  
  struct GeminiPrebuiltVoiceConfig: Codable {
    let voiceName: String
    
    enum CodingKeys: String, CodingKey {
      case voiceName = "voice_name"
    }
  }
}

struct GeminiChatResponse: Codable {
  let candidates: [GeminiChatCandidate]
  
  struct GeminiChatCandidate: Codable {
    let content: GeminiChatContent
    let finishReason: String?
    
    enum CodingKeys: String, CodingKey {
      case content
      case finishReason = "finish_reason"
    }
  }
  
  struct GeminiChatContent: Codable {
    let parts: [GeminiChatResponsePart]
    let role: String?
  }
  
  struct GeminiChatResponsePart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
    let functionCall: GeminiFunctionCall?
    
    enum CodingKeys: String, CodingKey {
      case text
      case inlineData  // API returns "inlineData" (camelCase), not "inline_data"
      case functionCall = "function_call"
    }
  }
  
  struct GeminiFunctionCall: Codable {
    let name: String?
    let args: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
      case name
      case args
    }
  }
  
  // Helper for decoding arbitrary JSON values in function call args
  struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
      self.value = value
    }
    
    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let bool = try? container.decode(Bool.self) {
        value = bool
      } else if let int = try? container.decode(Int.self) {
        value = int
      } else if let double = try? container.decode(Double.self) {
        value = double
      } else if let string = try? container.decode(String.self) {
        value = string
      } else if let array = try? container.decode([AnyCodable].self) {
        value = array.map { $0.value }
      } else if let dict = try? container.decode([String: AnyCodable].self) {
        value = dict.mapValues { $0.value }
      } else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "AnyCodable value cannot be decoded"
        )
      }
    }
    
    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch value {
      case let bool as Bool:
        try container.encode(bool)
      case let int as Int:
        try container.encode(int)
      case let double as Double:
        try container.encode(double)
      case let string as String:
        try container.encode(string)
      case let array as [Any]:
        try container.encode(array.map { AnyCodable($0) })
      case let dict as [String: Any]:
        try container.encode(dict.mapValues { AnyCodable($0) })
      default:
        throw EncodingError.invalidValue(
          value,
          EncodingError.Context(codingPath: container.codingPath, debugDescription: "AnyCodable value cannot be encoded")
        )
      }
    }
  }
  
  struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String
    
    enum CodingKeys: String, CodingKey {
      case mimeType  // API returns "mimeType" (camelCase), not "mime_type"
      case data
    }
  }
}

// MARK: - Gemini TTS (Generative Language API generateContent)
// Request/response for TTS via generativelanguage.googleapis.com; see https://ai.google.dev/gemini-api/docs/speech-generation
// API expects camelCase in JSON. Official docs use contents + generationConfig only (no systemInstruction).
// Style and literal reading are controlled via the text in contents (e.g. "Say the following: ...").
struct GeminiTTSRequest: Codable {
  let contents: [GeminiTTSContent]
  let generationConfig: GeminiTTSGenerationConfig

  struct GeminiTTSContent: Codable {
    let parts: [GeminiTTSPart]
  }

  struct GeminiTTSPart: Codable {
    let text: String
  }

  struct GeminiTTSGenerationConfig: Codable {
    let responseModalities: [String]
    let speechConfig: GeminiTTSSpeechConfig
  }

  struct GeminiTTSSpeechConfig: Codable {
    let voiceConfig: GeminiTTSVoiceConfig
  }

  struct GeminiTTSVoiceConfig: Codable {
    let prebuiltVoiceConfig: GeminiTTSPrebuiltVoiceConfig
  }

  struct GeminiTTSPrebuiltVoiceConfig: Codable {
    let voiceName: String
  }
}

// MARK: - Transcription Error

/// Which on-device Whisper phase overran its wall-clock budget (`TranscriptionError.localProcessingTimeout`).
enum LocalProcessingStage: String, Equatable {
  case modelLoad
  case decode
}

enum TranscriptionError: Error, Equatable {
  case noGoogleAPIKey
  case invalidAPIKey
  case incorrectAPIKey
  case countryNotSupported
  case invalidRequest
  case permissionDenied
  case notFound
  case modelDeprecated
  case rateLimited(retryAfter: TimeInterval?, topUpURL: URL? = nil)
  case quotaExceeded(retryAfter: TimeInterval?)
  /// Billing must be enabled (e.g. 400 FAILED_PRECONDITION "enable billing" from Gemini API).
  ///
  /// `topUpURL` is set when we know exactly where the user tops up — currently OpenRouter, whose
  /// 402 means "this balance is empty" and nothing else. Providers whose billing errors are
  /// ambiguous leave it nil and fall back to the list of dashboards in the message.
  case billingRequired(topUpURL: URL? = nil)
  case serverError(Int)
  case serviceUnavailable
  case slowDown
  case networkError(String)
  case requestTimeout
  case resourceTimeout
  case fileError(String)
  case fileTooLarge
  case emptyFile
  case noSpeechDetected
  case textTooShort
  case promptLeakDetected
  case modelNotAvailable(OfflineModelType)
  /// Voice/output (TTS) is not available via Sign in with Google; API key is required.
  case voiceRequiresAPIKey
  /// Backend returned 402: signed-in user has no active subscription.
  case subscriptionRequired
  /// Dictate Prompt with nothing selected to edit.
  ///
  /// An empty selection itself is a compose turn and does not throw (`SpeechService.performPrompt`).
  /// Thrown again when that compose turn's instruction is only a bare edit command ("Korrigiere",
  /// "Rephrase this"): the model would invent text to edit, and that text must not be pasted.
  /// Kept, not removed: these cases are logged by their integer index (`TranscriptionError error 21`),
  /// so removing it renumbers history.
  case noSelectedText
  /// An on-device Whisper model load or decode hit its wall-clock deadline (`WallClockDeadline`).
  /// Separate from `requestTimeout` so the user-facing copy does not blame the network.
  /// Appended last for the same index-logging reason as `noSelectedText`.
  case localProcessingTimeout(stage: LocalProcessingStage, seconds: Int)
  /// Dictate Prompt: the model answered with no text at all (a local model cut off inside its
  /// `<think>` block, a Gemini safety block with no text parts). Not "no speech detected": the
  /// user spoke, so the recording is kept and the run is retryable. Appended last for the same
  /// index-logging reason as `noSelectedText`.
  case emptyModelReply
  /// An on-device model (Parakeet, WhisperKit, MLX) failed to load or run. Keeps the recording and
  /// offers a manual Retry, but is not auto-retryable. Appended last for the index-logging reason
  /// above.
  case localModelFailed(String)

  var title: String {
    switch self {
    case .noGoogleAPIKey: return String(localized: "No Google API Key")
    case .invalidAPIKey: return String(localized: "Invalid Authentication")
    case .incorrectAPIKey: return String(localized: "Incorrect API Key")
    case .countryNotSupported: return String(localized: "Country Not Supported")
    case .invalidRequest: return String(localized: "Invalid Request")
    case .permissionDenied: return String(localized: "Permission Denied")
    case .notFound: return String(localized: "Not Found")
    case .modelDeprecated: return String(localized: "Model No Longer Available")
    case .rateLimited: return String(localized: "Rate Limited")
    case .quotaExceeded: return String(localized: "Quota Exceeded")
    case .billingRequired: return String(localized: "Billing Required")
    case .serverError: return String(localized: "Server Error")
    case .serviceUnavailable: return String(localized: "Service Unavailable")
    case .slowDown: return String(localized: "Slow Down")
    case .networkError: return String(localized: "Network Error")
    case .requestTimeout: return String(localized: "Request Timeout")
    case .resourceTimeout: return String(localized: "Resource Timeout")
    case .fileError: return String(localized: "File Error")
    case .fileTooLarge: return String(localized: "File Too Large")
    case .emptyFile: return String(localized: "Empty File")
    case .noSpeechDetected: return String(localized: "No Speech Detected")
    case .textTooShort: return String(localized: "Text Too Short")
    case .promptLeakDetected: return String(localized: "API Response Issue")
    case .modelNotAvailable: return String(localized: "Model Not Downloaded")
    case .voiceRequiresAPIKey: return String(localized: "Voice Requires API Key")
    case .subscriptionRequired: return String(localized: "Subscription Required")
    case .noSelectedText: return String(localized: "Nothing Selected")
    case .localProcessingTimeout: return String(localized: "Local Processing Timeout")
    case .emptyModelReply: return String(localized: "No Reply")
    case .localModelFailed: return String(localized: "Offline Model Error")
    }
  }

  /// Returns the retry delay if this error has one
  var retryAfter: TimeInterval? {
    switch self {
    case .rateLimited(let retryAfter, _), .quotaExceeded(let retryAfter):
      return retryAfter
    default:
      return nil
    }
  }

  var topUpURL: URL? {
    if case .rateLimited(_, let url) = self { return url }
    if case .billingRequired(let url) = self { return url }
    return nil
  }
  
  /// Determines if this error is retryable (temporary/transient errors)
  var isRetryable: Bool {
    switch self {
    // Retryable errors (temporary issues)
    case .networkError, .requestTimeout, .localProcessingTimeout, .resourceTimeout, .serverError, .serviceUnavailable, .slowDown, .emptyModelReply:
      return true
    // Rate limited and quota exceeded are retryable if we have a retry delay
    case .rateLimited(let retryAfter, _):
      return retryAfter != nil
    case .quotaExceeded(let retryAfter):
      return retryAfter != nil
    // Non-retryable errors (configuration/permanent issues)
    case .noGoogleAPIKey, .invalidAPIKey, .incorrectAPIKey, .countryNotSupported, .permissionDenied, .notFound, .modelDeprecated, .billingRequired, .fileError, .fileTooLarge, .emptyFile, .noSpeechDetected, .textTooShort, .promptLeakDetected, .modelNotAvailable, .localModelFailed, .invalidRequest, .voiceRequiresAPIKey, .subscriptionRequired, .noSelectedText:
      return false
    }
  }

  /// True when a failed run must keep the recording on disk and offer the user a manual Retry,
  /// even though the error is not auto-retryable. Model-preparation failures (on-device model
  /// missing, incomplete or failing to load) are fixed in Settings, and the dictation itself must
  /// survive until then. Deliberately separate from `isRetryable`: the chunk pipelines and
  /// schedulers key their automatic retry/backoff off that flag, and these errors must never loop.
  var keepsAudioForManualRetry: Bool {
    switch self {
    case .modelNotAvailable, .localModelFailed: return true
    default: return false
    }
  }

  /// True for server-side errors (500, 503) where exponential backoff is beneficial.
  var isServerOrUnavailable: Bool {
    switch self {
    case .serverError, .serviceUnavailable: return true
    default: return false
    }
  }
}


extension Error {
  /// Keep the recording and show Retry: transient errors (auto-retryable) plus model-preparation
  /// failures (`ModelStoreError` of any kind, see `TranscriptionError.keepsAudioForManualRetry`).
  /// Only the audio is kept; automatic retry still follows `TranscriptionError.isRetryable`.
  var offersManualRetry: Bool {
    if self is ModelStoreError { return true }
    guard let transcriptionError = self as? TranscriptionError else { return false }
    return transcriptionError.isRetryable || transcriptionError.keepsAudioForManualRetry
  }
}

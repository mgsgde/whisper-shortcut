import Foundation

// MARK: - Chat Model Provider
enum ChatModelProvider: String, CaseIterable {
  case gemini
  case grok
  case openai

  /// Model selected when the user invokes the bare provider slash-command
  /// (`/gemini`, `/grok`, `/openai`) with no qualifier, AND when `/model <provider>`
  /// is typed with no further narrowing keyword. Single source of truth so the
  /// autocomplete hint, the bare-command dispatch in `ChatView`, and the
  /// no-qualifier branch in `ChatModelCommandResolver` never drift apart —
  /// they all read `defaultChatModel` from here.
  var defaultChatModel: PromptModel {
    switch self {
    case .gemini: return .gemini35Flash
    case .grok:   return .grok43
    case .openai: return .openaiGPT55
    }
  }
}

// MARK: - Unified Prompt Model Enum (for Dictate Prompt) - Gemini multimodal models + Grok
// Current Gemini model IDs: https://ai.google.dev/gemini-api/docs/models (Gemini API, not Vertex AI).
// GA: gemini-2.5-flash, gemini-2.5-flash-lite, gemini-2.5-pro, gemini-3.1-flash-lite, gemini-3.5-flash.
// Preview: gemini-3-flash-preview, gemini-3.1-pro-preview.
// gemini-3-pro-preview was shut down 2026-03-09 (404) and removed; persisted values forward to
// gemini-3.1-pro-preview via migrateLegacyPromptRawValue.
// Grok model IDs: https://docs.x.ai/docs/models (grok-4-1-fast-non-reasoning was retired 2026-05-15
// and silently redirects to grok-4.3; the case was removed — see migrateLegacyPromptRawValue).
// OpenAI model IDs: https://platform.openai.com/docs/models.
enum PromptModel: String, CaseIterable {
  // Gemini Models (multimodal, direct audio input)
  case gemini25Flash = "gemini-2.5-flash"
  case gemini25FlashLite = "gemini-2.5-flash-lite"
  case gemini25Pro = "gemini-2.5-pro"
  case gemini3Flash = "gemini-3-flash-preview"
  case gemini31Pro = "gemini-3.1-pro-preview"
  case gemini31FlashLite = "gemini-3.1-flash-lite"
  case gemini35Flash = "gemini-3.5-flash"

  // Grok Models (xAI, OpenAI-compatible API, text + search for chat)
  case grok4 = "grok-4.20-0309-non-reasoning"
  case grok4Reasoning = "grok-4.20-0309-reasoning"
  case grok43 = "grok-4.3"

  // OpenAI Models (chat + Dictate Prompt via Chat Completions API)
  case openaiGPT5 = "gpt-5"
  case openaiGPT5Mini = "gpt-5-mini"
  case openaiGPT55 = "gpt-5.5"
  /// Audio-input chat model (renamed by OpenAI from `gpt-4o-audio-preview` → `gpt-audio`).
  /// Accepts inline `input_audio` content parts, which makes it the counterpart to Gemini for
  /// Dictate Prompt (the model "hears" the audio directly).
  /// Reference: https://platform.openai.com/docs/guides/audio
  case openaiGPT4oAudio = "gpt-audio"
  
  var displayName: String {
    switch self {
    case .gemini25Flash:
      return "Gemini 2.5 Flash"
    case .gemini25FlashLite:
      return "Gemini 2.5 Flash-Lite"
    case .gemini25Pro:
      return "Gemini 2.5 Pro"
    case .gemini3Flash:
      return "Gemini 3 Flash"
    case .gemini31Pro:
      return "Gemini 3.1 Pro"
    case .gemini31FlashLite:
      return "Gemini 3.1 Flash-Lite"
    case .gemini35Flash:
      return "Gemini 3.5 Flash"
    case .grok4:
      return "Grok 4"
    case .grok4Reasoning:
      return "Grok 4 Reasoning"
    case .grok43:
      return "Grok 4.3"
    case .openaiGPT5:
      return "OpenAI GPT-5"
    case .openaiGPT5Mini:
      return "OpenAI GPT-5 Mini"
    case .openaiGPT55:
      return "OpenAI GPT-5.5"
    case .openaiGPT4oAudio:
      return "OpenAI GPT Audio"
    }
  }

  var description: String {
    switch self {
    case .gemini25Flash:
      return "Google's Gemini 2.5 Flash model • Fast and efficient • Multimodal audio processing"
    case .gemini25FlashLite:
      return "Google's Gemini 2.5 Flash-Lite • Fastest latency • Cost-efficient • Multimodal"
    case .gemini25Pro:
      return "Google's Gemini 2.5 Pro model • Strong reasoning and instruction following • Stable (GA)"
    case .gemini3Flash:
      return "Google's Gemini 3 Flash model • Latest 3-series • Pro-level intelligence at Flash speed • Multimodal"
    case .gemini31Pro:
      return "Google's Gemini 3.1 Pro model • Complex reasoning and agentic workflows • Multimodal"
    case .gemini31FlashLite:
      return "Google's Gemini 3.1 Flash-Lite • Fastest, most cost-efficient 3-series • Multimodal"
    case .gemini35Flash:
      return "Google's Gemini 3.5 Flash • Latest GA flagship Flash • Strong on agentic + coding tasks • Multimodal"
    case .grok4:
      return "xAI's Grok 4 • Frontier-class intelligence • Web + X search • Requires xAI API key"
    case .grok4Reasoning:
      return "xAI's Grok 4 Reasoning • Extended thinking for complex tasks • Web + X search • Requires xAI API key"
    case .grok43:
      return "xAI's Grok 4.3 • Flagship • Leading non-hallucination + agentic tool use • 1M context • Web + X search • Requires xAI API key"
    case .openaiGPT5:
      return "OpenAI's GPT-5 • Flagship reasoning + tool use • Text + images • Requires OpenAI API key"
    case .openaiGPT5Mini:
      return "OpenAI's GPT-5 Mini • Cheaper, faster GPT-5 variant • Text + images • Requires OpenAI API key"
    case .openaiGPT55:
      return "OpenAI's GPT-5.5 • Newest flagship (April 2026) • Text + images • Requires OpenAI API key"
    case .openaiGPT4oAudio:
      return "OpenAI's GPT Audio • Accepts inline audio for voice-driven prompts • Requires OpenAI API key"
    }
  }
  
  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.selectedPromptModel
  }
  
  var costLevel: String {
    switch self {
    case .gemini25Flash, .gemini25FlashLite, .gemini3Flash, .gemini31FlashLite, .gemini35Flash:
      return "Low"
    case .gemini25Pro, .gemini31Pro:
      return "Medium"
    case .grok4, .grok4Reasoning, .grok43:
      return "Medium"
    case .openaiGPT5, .openaiGPT55, .openaiGPT4oAudio:
      return "Medium"
    case .openaiGPT5Mini:
      return "Low"
    }
  }

  var provider: ChatModelProvider {
    switch self {
    case .grok4, .grok4Reasoning, .grok43:
      return .grok
    case .openaiGPT5, .openaiGPT5Mini, .openaiGPT55, .openaiGPT4oAudio:
      return .openai
    default:
      return .gemini
    }
  }

  /// True for the OpenAI audio-preview models that accept `input_audio` content parts in
  /// Chat Completions requests — i.e. the OpenAI counterpart to Gemini's native audio handling
  /// in Dictate Prompt.
  var supportsDirectAudioInput: Bool {
    switch self {
    case .openaiGPT4oAudio:
      return true
    default:
      return provider == .gemini
    }
  }

  /// Whether the user has the API key this model's provider needs. Used to gate features
  /// (Dictate Prompt, chat, Smart Improvement) so a single provider key is enough.
  var hasRequiredCredential: Bool {
    switch provider {
    case .gemini: return GeminiCredentialProvider.shared.hasCredential()
    case .openai: return KeychainManager.shared.hasValidOpenAIAPIKey()
    case .grok: return KeychainManager.shared.hasValidXAIAPIKey()
    }
  }

  /// Actionable message when this model can't run Dictate Prompt for lack of a credential.
  var apiKeyRequiredMessageForDictatePrompt: String {
    switch provider {
    case .gemini: return "Add your Gemini API key in Settings (General tab) to use Dictate Prompt."
    case .openai: return "Add your OpenAI API key in Settings (General tab) to use Dictate Prompt."
    case .grok: return "Grok can't process audio directly. Pick a Gemini or OpenAI GPT-Audio model in Dictate Prompt settings."
    }
  }

  /// True for models whose chat endpoint accepts inline image content parts.
  /// OpenAI's gpt-4o-audio-preview is audio-only and rejects `image_url` parts with HTTP 400.
  var supportsImageInput: Bool {
    switch self {
    case .openaiGPT4oAudio:
      return false
    default:
      return true
    }
  }

  /// True for models that can power the text-based chat window. `gpt-4o-audio-preview`
  /// requires `input_audio` content or audio output on every request and 400s on plain text,
  /// so it's restricted to Dictate Prompt.
  var supportsTextChat: Bool {
    switch self {
    case .openaiGPT4oAudio:
      return false
    default:
      return true
    }
  }

  /// Gemini-only: `thinkingConfig.thinkingBudget` to send on chat requests.
  /// `0` disables thinking entirely (instant first token, faster streaming, weaker reasoning).
  /// `-1` enables dynamic thinking (3–10s before first token, stronger reasoning).
  /// Flash tier defaults to `0` because the streaming UX matters more than marginal quality gains.
  /// Pro tier defaults to `-1` because users choosing Pro are opting into the quality/latency trade.
  /// Non-Gemini models return `nil` (the field is ignored by other providers).
  var geminiThinkingBudget: Int? {
    switch self {
    case .gemini25Pro, .gemini31Pro:
      return -1
    case .gemini25Flash, .gemini25FlashLite, .gemini3Flash, .gemini31FlashLite, .gemini35Flash:
      return 0
    case .grok4, .grok4Reasoning, .grok43,
         .openaiGPT5, .openaiGPT5Mini, .openaiGPT55, .openaiGPT4oAudio:
      return nil
    }
  }

  var isGemini: Bool {
    return provider == .gemini
  }
  
  var isOffline: Bool {
    return false // Prompt mode doesn't support offline models yet
  }

  // Convert to TranscriptionModel for API endpoint access (for Gemini models)
  var asTranscriptionModel: TranscriptionModel? {
    switch self {
    case .gemini25Flash:
      return .gemini25Flash
    case .gemini25FlashLite:
      return .gemini25FlashLite
    case .gemini25Pro:
      return nil // 2.5 Pro not used for transcription in this app
    case .gemini3Flash:
      return .gemini3Flash
    case .gemini31Pro:
      return .gemini31Pro
    case .gemini31FlashLite:
      return .gemini31FlashLite
    case .gemini35Flash:
      return .gemini35Flash
    case .grok4, .grok4Reasoning, .grok43:
      return nil // Grok models are text-only, no audio transcription
    case .openaiGPT5, .openaiGPT5Mini, .openaiGPT55, .openaiGPT4oAudio:
      return nil // OpenAI chat models don't piggy-back on the transcription endpoint here
    }
  }

  /// Whether this model supports grounding/search.
  /// - Gemini: `google_search` + `url_context` tools on the standard endpoint.
  /// - Grok: `web_search` tool via the Responses API.
  /// - OpenAI text chat models: `web_search` tool via the Responses API (gpt-5, gpt-5-mini).
  /// - `gpt-4o-audio-preview` is audio-only and routes through Chat Completions only, so
  ///   the Responses API path doesn't apply.
  var supportsGrounding: Bool {
    switch self {
    case .openaiGPT4oAudio:
      return false
    default:
      return true
    }
  }

  /// All models available for the chat window (all providers). Excludes audio-only
  /// models such as `openaiGPT4oAudio`, which the OpenAI API rejects on text-only requests.
  static var chatModels: [PromptModel] {
    return allCases.filter { $0.supportsTextChat }
  }

  /// Models eligible for Dictate Prompt: every model that can accept inline audio directly.
  /// Gemini handles audio natively across all variants; OpenAI's GPT-4o Audio Preview handles
  /// it via `input_audio` content parts. Grok and text-only OpenAI models are excluded.
  static var dictatePromptCapableModels: [PromptModel] {
    return allCases.filter { $0.supportsDirectAudioInput }
  }

  /// Migrates deprecated in-enum cases; identity today (2.0 removed — use `migrateLegacyPromptRawValue` for UserDefaults).
  /// Kept as a stable hook so the 8 callers across `ChatView`, `ChatModelCommandResolver`, and `SettingsViewModel`
  /// don't need to be touched the next time an in-enum case is renamed.
  static func migrateIfDeprecated(_ model: PromptModel) -> PromptModel {
    model
  }

  /// Maps removed/renamed `PromptModel` raw values so `PromptModel(rawValue:)` succeeds after
  /// enum case removal or upstream model renames.
  static func migrateLegacyPromptRawValue(_ raw: String) -> String {
    switch raw {
    case "gemini-2.0-flash", "gemini-2.0-flash-lite":
      return Self.gemini31FlashLite.rawValue
    case "gemini-3.1-flash-lite-preview":
      // Same model — Google promoted -preview to GA.
      return Self.gemini31FlashLite.rawValue
    case "grok-4-1-fast-non-reasoning":
      // Retired by xAI on 2026-05-15; the slug silently redirected to grok-4.3 (now in enum).
      return Self.grok43.rawValue
    case "gpt-4o-audio-preview":
      // Renamed by OpenAI to `gpt-audio`; the case's rawValue now matches the new slug.
      return Self.openaiGPT4oAudio.rawValue
    case "gemini-3-pro-preview":
      // Shut down by Google 2026-03-09 (now returns 404); forward to the current Pro preview.
      return Self.gemini31Pro.rawValue
    default:
      return raw
    }
  }

  /// Loads the model selected for the chat window (Settings → Chat).
  static func loadSelectedChatModel() -> PromptModel {
    loadPromptModel(
      forKey: UserDefaultsKeys.selectedChatModel,
      default: SettingsDefaults.selectedChatModel,
      validate: { $0.supportsTextChat }
    )
  }

  /// Loads the model selected for meeting summary (rolling and final). Settings → Live Meeting → Summary Model.
  static func loadSelectedMeetingSummary() -> PromptModel {
    loadPromptModel(
      forKey: UserDefaultsKeys.selectedMeetingSummaryModel,
      default: SettingsDefaults.selectedMeetingSummaryModel
    )
  }

  /// Shared loader for any `PromptModel`-typed UserDefaults slot: reads the raw value, runs
  /// the legacy-raw migration (persisting the rewritten value), parses to a `PromptModel`,
  /// applies the in-enum `migrateIfDeprecated` hook (persisting if it changed), and applies
  /// the optional `validate` filter (e.g. "must support text chat"). Falls back to `default`
  /// on any miss. Single source of truth for "read a PromptModel slot from UserDefaults" —
  /// `SettingsViewModel.loadCurrentSettings`, `loadSelectedChatModel`, and
  /// `loadSelectedMeetingSummary` all route through here.
  static func loadPromptModel(
    forKey key: String,
    default fallback: PromptModel,
    validate: (PromptModel) -> Bool = { _ in true }
  ) -> PromptModel {
    guard let raw = UserDefaults.standard.string(forKey: key) else {
      return fallback
    }
    let migratedRaw = migrateLegacyPromptRawValue(raw)
    if migratedRaw != raw {
      UserDefaults.standard.set(migratedRaw, forKey: key)
    }
    guard let parsed = PromptModel(rawValue: migratedRaw) else {
      return fallback
    }
    // Validate the post-migration model — `migrateIfDeprecated` may map to a different case,
    // and the caller's filter (e.g. "must support text chat") must hold for what we return.
    let resolved = migrateIfDeprecated(parsed)
    guard validate(resolved) else {
      return fallback
    }
    if resolved.rawValue != migratedRaw {
      UserDefaults.standard.set(resolved.rawValue, forKey: key)
    }
    return resolved
  }
}

// MARK: - TTS Provider
/// Which backend a `TTSModel` talks to. Each provider uses a different endpoint, auth, and
/// request/response shape, but all are configured to return raw PCM (s16le, 24 kHz, mono) so
/// the shared playback path (`AudioMerger` / `playTTSAudio`) stays provider-agnostic.
enum TTSProvider {
  case gemini
  case openai
  case xai

  var displayName: String {
    switch self {
    case .gemini: return "Google Gemini"
    case .openai: return "OpenAI"
    case .xai: return "xAI (Grok)"
    }
  }
}

// MARK: - TTS Model Enum (for Text-to-Speech)
// Multi-provider Read Aloud. All models are configured to return raw PCM 24kHz mono 16-bit.
// Docs:
//   Gemini — https://ai.google.dev/gemini-api/docs/speech-generation (generateContent, not Cloud TTS)
//   OpenAI — https://platform.openai.com/docs/guides/text-to-speech (/v1/audio/speech)
//   xAI    — https://docs.x.ai/developers/model-capabilities/audio/text-to-speech (/v1/tts)
enum TTSModel: String, CaseIterable {
  // Google's only current Gemini TTS model. It replaced the 2.5 Flash/Pro TTS previews (shut down
  // 2026-10-16); persisted selections of those forward here via migrateLegacyReadAloudRawValue.
  // Verified live via scripts/test-gemini-models.sh.
  case gemini31FlashTTS = "gemini-3.1-flash-tts-preview"
  case openAIGpt4oMiniTTS = "gpt-4o-mini-tts"
  case grokVoiceTTS = "grok-voice-tts-1.0"

  var provider: TTSProvider {
    switch self {
    case .gemini31FlashTTS: return .gemini
    case .openAIGpt4oMiniTTS: return .openai
    case .grokVoiceTTS: return .xai
    }
  }

  var displayName: String {
    switch self {
    case .gemini31FlashTTS: return "Gemini 3.1 Flash TTS"
    case .openAIGpt4oMiniTTS: return "GPT-4o mini TTS"
    case .grokVoiceTTS: return "Grok Voice TTS"
    }
  }

  var description: String {
    switch self {
    case .gemini31FlashTTS:
      return "Google's Gemini 3.1 Flash TTS • Latest preview • Fast and efficient • Recommended"
    case .openAIGpt4oMiniTTS:
      return "OpenAI's GPT-4o mini TTS • Natural, steerable speech • Needs an OpenAI API key"
    case .grokVoiceTTS:
      return "xAI's Grok Voice TTS • Expressive multilingual speech • Needs an xAI API key"
    }
  }

  /// API endpoint for this model's provider. For Gemini the model id is in the path; for
  /// OpenAI and xAI it is passed in the request body.
  var apiEndpoint: String {
    switch provider {
    case .gemini:
      return "https://generativelanguage.googleapis.com/v1beta/models/\(rawValue):generateContent"
    case .openai:
      return AppConstants.openAISpeechEndpoint
    case .xai:
      return AppConstants.xaiTTSEndpoint
    }
  }

  var modelName: String {
    return self.rawValue
  }

  /// Default voice when the caller doesn't specify one. Each provider has its own voice
  /// catalogue, so "Charon" (Gemini) is not valid for OpenAI/xAI and vice versa.
  var defaultVoice: String {
    switch provider {
    case .gemini: return "Charon"
    case .openai: return "alloy"
    case .xai: return "eve"
    }
  }

  /// Whether the user has the API key this TTS model's provider needs. Gates Read Aloud so a
  /// single provider key is enough.
  var hasRequiredCredential: Bool {
    switch provider {
    case .gemini: return GeminiCredentialProvider.shared.hasCredential()
    case .openai: return KeychainManager.shared.hasValidOpenAIAPIKey()
    case .xai: return KeychainManager.shared.hasValidXAIAPIKey()
    }
  }

  /// Actionable message when this TTS model can't run Read Aloud for lack of a credential.
  var apiKeyRequiredMessage: String {
    switch provider {
    case .gemini: return "Add your Gemini API key in Settings (General) or sign in with Google to use Read Aloud."
    case .openai: return "Add your OpenAI API key in Settings (General tab) to use Read Aloud, or pick a different voice model."
    case .xai: return "Add your xAI API key in Settings (General tab) to use Read Aloud, or pick a different voice model."
    }
  }

  var isRecommended: Bool {
    return self == .gemini31FlashTTS
  }

  var costLevel: String {
    return "Low"
  }

  /// Models grouped for display in the Read Aloud picker (provider order: Gemini, OpenAI, xAI).
  static let readAloudModels: [TTSModel] = [
    .gemini31FlashTTS, .openAIGpt4oMiniTTS, .grokVoiceTTS,
  ]

  /// Maps removed/renamed persisted raw values onto current cases.
  static func migrateLegacyReadAloudRawValue(_ raw: String) -> String {
    switch raw {
    case "gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts":
      // Both 2.5 TTS previews shut down 2026-10-16; Gemini 3.1 Flash TTS is Google's replacement.
      return TTSModel.gemini31FlashTTS.rawValue
    default:
      return raw
    }
  }

  /// Reads the user's Read Aloud model selection from UserDefaults, applying legacy
  /// migration and falling back to `fallback` for unknown values.
  static func loadReadAloudModel(forKey key: String, default fallback: TTSModel) -> TTSModel {
    let migratedRaw = migrateLegacyReadAloudRawValue(
      UserDefaults.standard.string(forKey: key) ?? fallback.rawValue)
    return TTSModel(rawValue: migratedRaw) ?? fallback
  }
}

// MARK: - Notification Position Enum
enum NotificationPosition: String, CaseIterable {
  case leftBottom = "left-bottom"
  case rightBottom = "right-bottom"
  case leftTop = "left-top"
  case rightTop = "right-top"
  case centerTop = "center-top"
  case centerBottom = "center-bottom"
  
  var displayName: String {
    switch self {
    case .leftBottom:
      return "Left bottom"
    case .rightBottom:
      return "Right bottom"
    case .leftTop:
      return "Left top"
    case .rightTop:
      return "Right top"
    case .centerTop:
      return "Center top"
    case .centerBottom:
      return "Center bottom"
    }
  }
  
  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.notificationPosition
  }
}

// MARK: - Notification Duration Enum
enum NotificationDuration: Double, CaseIterable {
  case oneSecond = 1.0
  case twoSeconds = 2.0
  case threeSeconds = 3.0
  case fiveSeconds = 5.0
  case sevenSeconds = 7.0
  case tenSeconds = 10.0
  case fifteenSeconds = 15.0
  case thirtySeconds = 30.0
  
  var displayName: String {
    switch self {
    case .oneSecond:
      return "1 second"
    case .twoSeconds:
      return "2 seconds"
    case .threeSeconds:
      return "3 seconds"
    case .fiveSeconds:
      return "5 seconds"
    case .sevenSeconds:
      return "7 seconds"
    case .tenSeconds:
      return "10 seconds"
    case .fifteenSeconds:
      return "15 seconds"
    case .thirtySeconds:
      return "30 seconds"
    }
  }
  
  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.notificationDuration
  }
}

// MARK: - Confirm Above Duration (Recording Safeguard)
enum ConfirmAboveDuration: Double, CaseIterable {
  case never = 0
  case oneMinute = 60
  case twoMinutes = 120
  case fiveMinutes = 300
  case tenMinutes = 600

  var displayName: String {
    switch self {
    case .never: return "Never"
    case .oneMinute: return "1 minute"
    case .twoMinutes: return "2 minutes"
    case .fiveMinutes: return "5 minutes"
    case .tenMinutes: return "10 minutes"
    }
  }

  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.confirmAboveDuration
  }

  /// Loads value from UserDefaults or returns SettingsDefaults.confirmAboveDuration.
  static func loadFromUserDefaults() -> ConfirmAboveDuration {
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.confirmAboveDurationSeconds) != nil,
       let t = ConfirmAboveDuration(rawValue: UserDefaults.standard.double(forKey: UserDefaultsKeys.confirmAboveDurationSeconds)) {
      return t
    }
    return SettingsDefaults.confirmAboveDuration
  }
}

// MARK: - Meeting Safeguard Duration (Live Meeting)
enum MeetingSafeguardDuration: Double, CaseIterable {
  case never = 0
  case sixtyMinutes = 3600
  case ninetyMinutes = 5400
  case twoHours = 7200

  var displayName: String {
    switch self {
    case .never: return "Never"
    case .sixtyMinutes: return "60 minutes"
    case .ninetyMinutes: return "90 minutes"
    case .twoHours: return "2 hours"
    }
  }

  /// Loads value from UserDefaults or returns SettingsDefaults.liveMeetingSafeguardDuration.
  static func loadFromUserDefaults() -> MeetingSafeguardDuration {
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.liveMeetingSafeguardDurationSeconds) != nil,
       let t = MeetingSafeguardDuration(rawValue: UserDefaults.standard.double(forKey: UserDefaultsKeys.liveMeetingSafeguardDurationSeconds)) {
      return t
    }
    return SettingsDefaults.liveMeetingSafeguardDuration
  }
}

// MARK: - Improve from Usage auto-run interval
enum ImproveFromUsageAutoRunInterval: Int, CaseIterable {
  case off = 0
  case every3Days = 3
  case every7Days = 7
  case every14Days = 14
  case every30Days = 30

  var dayCount: Int? {
    switch self {
    case .off: return nil
    case .every3Days: return 3
    case .every7Days: return 7
    case .every14Days: return 14
    case .every30Days: return 30
    }
  }

  var displayName: String {
    switch self {
    case .off: return "Off"
    case .every3Days: return "Every 3 days"
    case .every7Days: return "Every 7 days"
    case .every14Days: return "Every 14 days"
    case .every30Days: return "Every 30 days"
    }
  }
}

// MARK: - Whisper Language Enum
enum WhisperLanguage: String, CaseIterable {
  case auto = "auto"
  case en = "en"
  case de = "de"
  case fr = "fr"
  case es = "es"
  case it = "it"
  case pt = "pt"
  case ru = "ru"
  case ja = "ja"
  case ko = "ko"
  case zh = "zh"
  case nl = "nl"
  case pl = "pl"
  case tr = "tr"
  case sv = "sv"
  case da = "da"
  case no = "no"
  case fi = "fi"
  case cs = "cs"
  case hu = "hu"
  case ro = "ro"
  case el = "el"
  case ar = "ar"
  case hi = "hi"
  
  var displayName: String {
    switch self {
    case .auto:
      return "Auto-detect"
    case .en:
      return "English"
    case .de:
      return "German"
    case .fr:
      return "French"
    case .es:
      return "Spanish"
    case .it:
      return "Italian"
    case .pt:
      return "Portuguese"
    case .ru:
      return "Russian"
    case .ja:
      return "Japanese"
    case .ko:
      return "Korean"
    case .zh:
      return "Chinese"
    case .nl:
      return "Dutch"
    case .pl:
      return "Polish"
    case .tr:
      return "Turkish"
    case .sv:
      return "Swedish"
    case .da:
      return "Danish"
    case .no:
      return "Norwegian"
    case .fi:
      return "Finnish"
    case .cs:
      return "Czech"
    case .hu:
      return "Hungarian"
    case .ro:
      return "Romanian"
    case .el:
      return "Greek"
    case .ar:
      return "Arabic"
    case .hi:
      return "Hindi"
    }
  }
  
  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.whisperLanguage
  }
  
  var languageCode: String? {
    return self == .auto ? nil : self.rawValue
  }
}

// MARK: - Settings Tab Definition
// Order mirrors the menu-bar dropdown (Dictate ⌘1 → Dictate Prompt ⌘2 → Read Aloud ⌘4 → Chat ⌥Space).
enum SettingsTab: String, CaseIterable {
  case general = "General"
  case speechToText = "Dictate"
  case speechToPrompt = "Dictate Prompt"
  case screenshot = "Screenshot"
  case readAloud = "Read Aloud"
  case chat = "Chat"
  case privacy = "Privacy & Permissions"
}

// MARK: - Read Aloud Playback Speed
/// Discrete playback rates applied locally via `AVAudioUnitTimePitch`. The Gemini TTS
/// API has no `speakingRate` parameter, so speed is post-processed during playback
/// rather than asked of the model.
enum ReadAloudSpeed: Double, CaseIterable {
  case x075 = 0.75
  case x100 = 1.0
  case x125 = 1.25
  case x150 = 1.5
  case x175 = 1.75
  case x200 = 2.0

  var displayName: String {
    switch self {
    case .x075: return "0.75×"
    case .x100: return "1×"
    case .x125: return "1.25×"
    case .x150: return "1.5×"
    case .x175: return "1.75×"
    case .x200: return "2×"
    }
  }

  var isRecommended: Bool {
    return self == SettingsDefaults.readAloudSpeed
  }
}

// MARK: - Read Aloud Preferences (UserDefaults Accessors)
/// Centralized read accessors for Read Aloud preferences so MenuBarController, SpeechService,
/// and SettingsViewModel don't each have to coalesce-with-default the same UserDefaults keys.
enum ReadAloudPreferences {
  static var speed: ReadAloudSpeed {
    guard UserDefaults.standard.object(forKey: UserDefaultsKeys.readAloudSpeed) != nil,
          let saved = ReadAloudSpeed(rawValue: UserDefaults.standard.double(forKey: UserDefaultsKeys.readAloudSpeed))
    else { return SettingsDefaults.readAloudSpeed }
    return saved
  }

  static var smartRewriteEnabled: Bool {
    guard UserDefaults.standard.object(forKey: UserDefaultsKeys.readAloudSmartRewriteEnabled) != nil
    else { return SettingsDefaults.readAloudSmartRewriteEnabled }
    return UserDefaults.standard.bool(forKey: UserDefaultsKeys.readAloudSmartRewriteEnabled)
  }

  /// The user's selected Read Aloud TTS model (across Gemini / OpenAI / xAI), or the default.
  static var model: TTSModel {
    TTSModel.loadReadAloudModel(
      forKey: UserDefaultsKeys.selectedReadAloudModel, default: SettingsDefaults.readAloudModel)
  }
}

// MARK: - Live Meeting Chunk Interval Options
enum LiveMeetingChunkInterval: Double, CaseIterable {
  case fifteenSeconds = 15.0
  case thirtySeconds = 30.0
  case fortyFiveSeconds = 45.0
  case sixtySeconds = 60.0
  
  var displayName: String {
    switch self {
    case .fifteenSeconds: return "15 seconds"
    case .thirtySeconds: return "30 seconds"
    case .fortyFiveSeconds: return "45 seconds"
    case .sixtySeconds: return "60 seconds"
    }
  }
}

// MARK: - Default Settings Configuration
struct SettingsDefaults {
  // MARK: - Global Settings
  static let googleAPIKey = ""
  static let launchAtLogin = false

  // MARK: - Toggle Shortcut Settings
  /// All shortcut defaults are `nil` here — the actual factory defaults live in
  /// `ShortcutConfig.default`. `nil` in `SettingsData` means "no shortcut /
  /// disabled" until the user records one or `SettingsViewModel.load()`
  /// populates it from the persisted `ShortcutConfig`.
  static let toggleDictation: ShortcutDefinition? = nil
  static let togglePrompting: ShortcutDefinition? = nil
  static let openSettings: ShortcutDefinition? = nil
  static let openChat: ShortcutDefinition? = nil
  static let screenshotCapture: ShortcutDefinition? = nil
  static let readAloud: ShortcutDefinition? = nil

  // MARK: - Model & Prompt Settings
  static let selectedTranscriptionModel = TranscriptionModel.gemini31FlashLite
  static let selectedPromptModel = PromptModel.gemini35Flash
  static let selectedChatModel = PromptModel.gemini35Flash
  static let chatCloseOnFocusLoss = true
  static let settingsCloseOnFocusLoss = true
  static let customPromptText = ""
  static let promptModeSystemPrompt = ""
  
  // MARK: - Read Aloud (Chat TTS)
  /// Voice used by the Read Aloud button. Per-model voice is derived from `TTSModel.defaultVoice`;
  /// this remains the Gemini default for any caller that still references it directly.
  static let readAloudVoice = "Charon"
  /// Default Read Aloud TTS model when the user hasn't picked one. User selection is persisted
  /// under `UserDefaultsKeys.selectedReadAloudModel` and read via `ReadAloudPreferences.model`.
  static let readAloudModel: TTSModel = .gemini31FlashTTS
  /// When true, the global Read Aloud shortcut first runs a "rewrite for speech" pass before TTS.
  static let readAloudSmartRewriteEnabled = true
  /// Playback rate applied locally during TTS playback. Pitch is preserved.
  static let readAloudSpeed: ReadAloudSpeed = .x100

  // MARK: - Whisper Language Settings
  static let whisperLanguage = WhisperLanguage.auto

  // MARK: - Notification Settings
  static let showPopupNotifications = true
  static let notificationPosition = NotificationPosition.leftTop
  static let notificationDuration = NotificationDuration.oneSecond
  static let errorNotificationDuration = NotificationDuration.thirtySeconds

  // MARK: - Recording Safeguards
  static let confirmAboveDuration = ConfirmAboveDuration.fiveMinutes

  // MARK: - Auto-Paste Settings
  static let autoPasteAfterDictation = true

  // MARK: - Screenshot Settings
  static let screenshotInPromptMode = true
  static let screenshotSaveEnabled = false

  // MARK: - Live Meeting Settings
  static let liveMeetingChunkInterval = LiveMeetingChunkInterval.thirtySeconds
  static let liveMeetingSafeguardDuration = MeetingSafeguardDuration.ninetyMinutes
  static let selectedMeetingSummaryModel = PromptModel.gemini35Flash

  /// Smart Improvement default model.
  static let defaultSmartImprovementModel = PromptModel.gemini31Pro
  static let selectedImprovementModel = PromptModel.gemini31Pro

  // proxyAPIBaseURL removed — no backend proxy; all requests go direct to Gemini API
  static var proxyAPIBaseURL: String { "" }

  // MARK: - UI State
  static let errorMessage = ""
  static let isLoading = false
  static let showAlert = false
}

// MARK: - Settings Data Models
struct SettingsData {
  // MARK: - Global Settings
  var googleAPIKey: String = SettingsDefaults.googleAPIKey
  var launchAtLogin: Bool = SettingsDefaults.launchAtLogin

  // MARK: - Toggle Shortcut Settings
  var toggleDictation: ShortcutDefinition? = SettingsDefaults.toggleDictation
  var togglePrompting: ShortcutDefinition? = SettingsDefaults.togglePrompting
  var openSettings: ShortcutDefinition? = SettingsDefaults.openSettings
  var openChat: ShortcutDefinition? = SettingsDefaults.openChat
  var screenshotCapture: ShortcutDefinition? = SettingsDefaults.screenshotCapture
  var readAloud: ShortcutDefinition? = SettingsDefaults.readAloud

  // MARK: - Read Aloud
  var readAloudSmartRewriteEnabled: Bool = SettingsDefaults.readAloudSmartRewriteEnabled
  var readAloudSpeed: ReadAloudSpeed = SettingsDefaults.readAloudSpeed

  // MARK: - Model & Prompt Settings
  var selectedTranscriptionModel: TranscriptionModel = SettingsDefaults.selectedTranscriptionModel
  var selectedPromptModel: PromptModel = SettingsDefaults.selectedPromptModel
  var selectedChatModel: PromptModel = SettingsDefaults.selectedChatModel
  var selectedImprovementModel: PromptModel = SettingsDefaults.selectedImprovementModel
  var selectedReadAloudModel: TTSModel = SettingsDefaults.readAloudModel
  var chatCloseOnFocusLoss: Bool = SettingsDefaults.chatCloseOnFocusLoss
  var settingsCloseOnFocusLoss: Bool = SettingsDefaults.settingsCloseOnFocusLoss
  var customPromptText: String = SettingsDefaults.customPromptText
  var promptModeSystemPrompt: String = SettingsDefaults.promptModeSystemPrompt

  // MARK: - Whisper Language Settings
  var whisperLanguage: WhisperLanguage = SettingsDefaults.whisperLanguage

  // MARK: - Notification Settings
  var showPopupNotifications: Bool = SettingsDefaults.showPopupNotifications
  var notificationPosition: NotificationPosition = SettingsDefaults.notificationPosition
  var notificationDuration: NotificationDuration = SettingsDefaults.notificationDuration
  var errorNotificationDuration: NotificationDuration = SettingsDefaults.errorNotificationDuration

  // MARK: - Recording Safeguards
  var confirmAboveDuration: ConfirmAboveDuration = SettingsDefaults.confirmAboveDuration

  // MARK: - Auto-Paste Settings
  var autoPasteAfterDictation: Bool = SettingsDefaults.autoPasteAfterDictation

  // MARK: - Screenshot Settings
  var screenshotInPromptMode: Bool = SettingsDefaults.screenshotInPromptMode
  var screenshotSaveEnabled: Bool = SettingsDefaults.screenshotSaveEnabled
  /// Display-only; the security-scoped bookmark itself is owned by ScreenshotSaveLocation.
  var screenshotSaveFolderDisplayPath: String = ""

  // MARK: - Live Meeting Settings
  var liveMeetingChunkInterval: LiveMeetingChunkInterval = SettingsDefaults.liveMeetingChunkInterval
  var liveMeetingSafeguardDuration: MeetingSafeguardDuration = SettingsDefaults.liveMeetingSafeguardDuration
  var selectedTranscriptionModelForMeetings: TranscriptionModel = SettingsDefaults.selectedTranscriptionModel
  var selectedMeetingSummaryModel: PromptModel = SettingsDefaults.selectedMeetingSummaryModel

  // MARK: - UI State
  var errorMessage: String = SettingsDefaults.errorMessage
  var isLoading: Bool = SettingsDefaults.isLoading
  var showAlert: Bool = SettingsDefaults.showAlert
  var appStoreLinkCopied: Bool = false
}

// MARK: - Focus States Enum
enum SettingsFocusField: Hashable {
  case googleAPIKey
  case toggleDictation
  case togglePrompting
  case toggleSettings
  case toggleChat
  case screenshotCapture
  case readAloudShortcut
  case customPrompt
  case promptModeSystemPrompt
}

// MARK: - Shortcut Conflict Descriptor
/// Returned by the recorder's conflict-detection callback when the captured
/// shortcut is already bound to another field. The recorder uses `field` to
/// know which slot to clear on reassign, and `label` to render the
/// "Currently used by …" caption + "Reassign from …" button text.
struct ShortcutConflict: Equatable {
  let field: SettingsFocusField
  let label: String
}

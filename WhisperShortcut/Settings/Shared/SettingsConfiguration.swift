import Foundation

// MARK: - Chat Model Provider
enum ChatModelProvider: String, CaseIterable {
  case gemini
  case grok
  case openai
  /// Anthropic Claude via the Messages API. Chat-only for the first slice (no Dictate Prompt /
  /// TTS path — Claude has no native audio STT/TTS in this app).
  case anthropic
  /// User-configured OpenAI-compatible chat proxy (OpenRouter, LiteLLM, …). Endpoint, model id,
  /// and optional API key are read from `OpenAIChatPreferences`. Selected explicitly in Chat.
  case customOpenAI
  /// Local OpenAI-compatible server (Ollama / LM Studio). No API key; endpoint + model id are
  /// read from UserDefaults via `LocalLLMPreferences`. Runs fully on the user's machine.
  case local

  /// Model selected when the user invokes the bare provider slash-command
  /// (`/gemini`, `/grok`, `/gpt`, `/claude`) with no qualifier, AND when `/model <provider>`
  /// is typed with no further narrowing keyword. Single source of truth so the
  /// autocomplete hint, the bare-command dispatch in `ChatView`, and the
  /// no-qualifier branch in `ChatModelCommandResolver` never drift apart —
  /// they all read `defaultChatModel` from here.
  var defaultChatModel: PromptModel {
    switch self {
    case .gemini: return .gemini36Flash
    case .grok:   return .grok43
    case .openai: return .openaiGPT56Sol
    case .anthropic: return .claudeSonnet5
    case .customOpenAI: return .customOpenAIEndpoint
    case .local:  return .localModel
    }
  }

  /// Slash-command alias for the bare provider command (without the leading "/"), e.g. `/gemini`.
  /// Named after the model brand for consistency: Gemini / Grok / GPT / Claude (not the company).
  /// `/openai` and `/anthropic` are silent aliases in `ChatView`; see `modelCommandLookup`.
  var commandAlias: String {
    switch self {
    case .gemini: return "gemini"
    case .grok:   return "grok"
    case .openai: return "gpt"
    case .anthropic: return "claude"
    case .customOpenAI: return "custom"
    case .local:  return "local"
    }
  }
}

// MARK: - Unified Prompt Model Enum (for Dictate Prompt) - Gemini multimodal models + Grok
// Current Gemini model IDs: https://ai.google.dev/gemini-api/docs/models (Gemini API, not Vertex AI).
// GA: gemini-3.1-flash-lite, gemini-3.5-flash-lite, gemini-3.5-flash, gemini-3.6-flash.
// Preview: gemini-3.1-pro-preview.
// Removed and forwarded via migrateLegacyPromptRawValue: gemini-3-pro-preview (shut down
// 2026-03-09) → gemini-3.1-pro-preview; the Gemini 2.5 family (gemini-2.5-flash / -flash-lite /
// -pro, shutdown 2026-10-16) → gemini-3.5-flash / gemini-3.1-flash-lite / gemini-3.1-pro-preview;
// gemini-3-flash-preview (deprecated-pending) → gemini-3.5-flash.
// Grok model IDs: https://docs.x.ai/docs/models (grok-4-1-fast-non-reasoning was retired 2026-05-15
// and silently redirects to grok-4.3; the case was removed — see migrateLegacyPromptRawValue).
// OpenAI model IDs: https://platform.openai.com/docs/models.
enum PromptModel: String, CaseIterable {
  // Gemini Models (multimodal, direct audio input)
  case gemini31Pro = "gemini-3.1-pro-preview"
  case gemini31FlashLite = "gemini-3.1-flash-lite"
  case gemini35FlashLite = "gemini-3.5-flash-lite"
  case gemini35Flash = "gemini-3.5-flash"
  case gemini36Flash = "gemini-3.6-flash"

  // Gemini native image generation/editing ("Nano Banana"). Prompt (+ optional input image) →
  // image out, via a dedicated non-streaming `:generateContent` call with `responseModalities`
  // IMAGE (see `GeminiAPIClient.generateImageContent` / `GeminiChatProvider`). Not a text-chat,
  // tools, grounding, or thinking model — selecting it turns the chat into an image generator.
  case geminiImage = "gemini-3.1-flash-image"
  // Premium tier of the same capability: studio quality, up to 4K, better text rendering.
  // No free tier (roughly $0.13–0.24 per image) — the user picks it deliberately for quality.
  case geminiImagePro = "gemini-3-pro-image"

  // Grok Models (xAI, OpenAI-compatible API, text + search for chat)
  case grok4 = "grok-4.20-0309-non-reasoning"
  case grok4Reasoning = "grok-4.20-0309-reasoning"
  case grok43 = "grok-4.3"
  /// xAI's current flagship: "the most intelligent and fastest model we've built"
  /// (https://docs.x.ai/docs/models). Does NOT supersede grok-4.3 — it costs $2.00/$6.00 per 1M
  /// against 4.3's $1.25/$2.50 and carries a 500k context where 4.3 has 1M, so both stay.
  case grok45 = "grok-4.5"

  // OpenAI Models (chat + Dictate Prompt via Chat Completions API)
  // The case identifiers keep their historical names while the rawValue tracks the current
  // vendor slug: `gpt-5` → `gpt-5.4` and `gpt-5-mini` → `gpt-5.4-mini` (newer GA generation,
  // 2026-03). Persisted `gpt-5`/`gpt-5-mini` selections forward via migrateLegacyPromptRawValue.
  case openaiGPT5 = "gpt-5.4"
  case openaiGPT5Mini = "gpt-5.4-mini"
  case openaiGPT55 = "gpt-5.5"
  // GPT-5.6 family (2026-07). Priced *identically* to the 5.5/5.4 tiers it mirrors — sol matches
  // gpt-5.5 at $5/$30 and terra matches gpt-5.4 at $2.50/$15 — which is what makes those two
  // Pareto-dominated (same price, newer generation). luna is a cheaper tier at $1/$6, above
  // gpt-5.4-mini ($0.75/$4.50), so mini stays on the frontier.
  // https://developers.openai.com/api/docs/pricing — verified live via scripts/test-openai-models.sh.
  case openaiGPT56Sol = "gpt-5.6-sol"
  case openaiGPT56Terra = "gpt-5.6-terra"
  case openaiGPT56Luna = "gpt-5.6-luna"
  /// Audio-input chat model (renamed by OpenAI from `gpt-4o-audio-preview` → `gpt-audio`).
  /// Accepts inline `input_audio` content parts, which makes it the counterpart to Gemini for
  /// Dictate Prompt (the model "hears" the audio directly).
  /// Reference: https://platform.openai.com/docs/guides/audio
  case openaiGPT4oAudio = "gpt-audio"

  // OpenAI-compatible chat proxy (OpenRouter, LiteLLM, self-hosted, …). The rawValue is a stable
  // sentinel — the actual model tag sent to the server is read from `OpenAIChatPreferences.modelID`.
  case customOpenAIEndpoint = "custom-openai-endpoint"

  // Anthropic Claude (Messages API). Chat-only — no Dictate Prompt / TTS wiring.
  // Model IDs: https://platform.claude.com/docs/en/about-claude/models/overview (verified 2026-07).
  case claudeSonnet5 = "claude-sonnet-5"
  case claudeOpus48 = "claude-opus-4-8"
  case claudeHaiku45 = "claude-haiku-4-5-20251001"
  /// Anthropic's most capable widely released model (GA since 2026-06-09), $10/$50 per 1M.
  case claudeFable5 = "claude-fable-5"

  // Local model served by an OpenAI-compatible server on the user's machine (Ollama / LM Studio).
  // The rawValue is a stable sentinel — the *actual* model tag sent to the server is configurable
  // and read from `LocalLLMPreferences.modelID`, so one enum case covers whatever the user pulled.
  case localModel = "local-llm"

  var displayName: String {
    switch self {
    case .gemini31Pro:
      return "Gemini 3.1 Pro"
    case .gemini31FlashLite:
      return "Gemini 3.1 Flash-Lite"
    case .gemini35FlashLite:
      return "Gemini 3.5 Flash-Lite"
    case .gemini35Flash:
      return "Gemini 3.5 Flash"
    case .gemini36Flash:
      return "Gemini 3.6 Flash"
    case .geminiImage:
      return "Gemini Image (Nano Banana 2)"
    case .geminiImagePro:
      return "Gemini Image Pro (Nano Banana Pro)"
    case .grok4:
      return "Grok 4.20"
    case .grok4Reasoning:
      return "Grok 4.20 Reasoning"
    case .grok43:
      return "Grok 4.3"
    case .grok45:
      return "Grok 4.5"
    case .openaiGPT5:
      return "OpenAI GPT-5.4"
    case .openaiGPT5Mini:
      return "OpenAI GPT-5.4 Mini"
    case .openaiGPT55:
      return "OpenAI GPT-5.5"
    case .openaiGPT56Sol:
      return "OpenAI GPT-5.6 Sol"
    case .openaiGPT56Terra:
      return "OpenAI GPT-5.6 Terra"
    case .openaiGPT56Luna:
      return "OpenAI GPT-5.6 Luna"
    case .openaiGPT4oAudio:
      return "OpenAI GPT Audio"
    case .claudeSonnet5:
      return "Claude Sonnet 5"
    case .claudeOpus48:
      return "Claude Opus 4.8"
    case .claudeHaiku45:
      return "Claude Haiku 4.5"
    case .claudeFable5:
      return "Claude Fable 5"
    case .customOpenAIEndpoint:
      return "Custom endpoint (OpenRouter / proxy)"
    case .localModel:
      return "Local (Ollama / LM Studio)"
    }
  }

  /// Slash-command alias (without the leading "/") for quick model switching in chat,
  /// e.g. `/gemini3flash`. Provider-prefixed and spelled out (NOT cryptic codes) so the whole
  /// family groups under the bare provider command — typing `/gemini` surfaces every Gemini
  /// variant in the suggestion list, then ↑/↓ + Enter picks one. `ChatViewModel.modelCommands`
  /// generates one command per chat model from this, so adding a model auto-adds its alias to
  /// autocomplete, tab-completion, dispatch, and the system-prompt command list.
  /// MUST stay unique across all cases and must not collide with non-model commands (/new, /pin, …).
  /// May extend a provider-default alias (gemini / grok / gpt) as a prefix — that's intended.
  var shortAlias: String {
    switch self {
    case .gemini31Pro:       return "gemini31pro"
    case .gemini31FlashLite: return "gemini31flashlite"
    case .gemini35FlashLite: return "gemini35flashlite"
    case .gemini35Flash:     return "gemini35flash"
    case .gemini36Flash:     return "gemini36flash"
    case .geminiImage:       return "geminiimage"
    case .geminiImagePro:    return "geminiimagepro"
    case .grok4:             return "grok4"
    case .grok4Reasoning:    return "grok4reasoning"
    case .grok43:            return "grok43"
    case .grok45:            return "grok45"
    case .openaiGPT5:        return "gpt54"
    case .openaiGPT5Mini:    return "gpt54mini"
    case .openaiGPT55:       return "gpt55"
    case .openaiGPT56Sol:    return "gpt56sol"
    case .openaiGPT56Terra:  return "gpt56terra"
    case .openaiGPT56Luna:   return "gpt56luna"
    case .openaiGPT4oAudio:  return "gptaudio" // audio-only; excluded from chatModels, never surfaced
    case .claudeSonnet5:     return "claudesonnet5"
    case .claudeOpus48:      return "claudeopus48"
    case .claudeHaiku45:     return "claudehaiku45"
    case .claudeFable5:      return "claudefable5"
    case .customOpenAIEndpoint: return "custom"
    case .localModel:        return "local"
    }
  }

  var description: String {
    switch self {
    case .gemini31Pro:
      return "Google's Gemini 3.1 Pro model • Complex reasoning and agentic workflows • Multimodal"
    case .gemini31FlashLite:
      return "Google's Gemini 3.1 Flash-Lite • Fastest, most cost-efficient 3-series • Multimodal"
    case .gemini35FlashLite:
      return "Google's Gemini 3.5 Flash-Lite • Fastest, most cost-effective 3.5 model • High throughput • Multimodal"
    case .gemini35Flash:
      return "Google's Gemini 3.5 Flash • Most intelligent Flash • Strong on agentic + coding tasks • Multimodal"
    case .gemini36Flash:
      return "Google's Gemini 3.6 Flash • Newest Flash • Balances speed with intelligence • Multimodal"
    case .geminiImage:
      return "Google's Gemini Image (Nano Banana 2) • Generates and edits images from a prompt + optional input image • Free tier • Requires Gemini API key"
    case .geminiImagePro:
      return "Google's Gemini Image Pro (Nano Banana Pro) • Studio-quality image generation/editing up to 4K • Best text rendering • Paid (no free tier) • Requires Gemini API key"
    case .grok4:
      return "xAI's Grok 4.20 • Frontier-class intelligence • Web + X search • Requires xAI API key"
    case .grok4Reasoning:
      return "xAI's Grok 4.20 Reasoning • Extended thinking for complex tasks • Web + X search • Requires xAI API key"
    case .grok45:
      return "xAI's Grok 4.5 • xAI's most intelligent and fastest model • 500k context • Needs an xAI API key"
    case .grok43:
      return "xAI's Grok 4.3 • Flagship • Leading non-hallucination + agentic tool use • 1M context • Web + X search • Requires xAI API key"
    case .openaiGPT5:
      return "OpenAI's GPT-5.4 • Flagship reasoning + tool use • Text + images • Requires OpenAI API key"
    case .openaiGPT5Mini:
      return "OpenAI's GPT-5.4 Mini • Cheaper, faster GPT-5.4 variant • Text + images • Requires OpenAI API key"
    case .openaiGPT55:
      return "OpenAI's GPT-5.5 • Newest flagship (April 2026) • Text + images • Requires OpenAI API key"
    case .openaiGPT56Sol:
      return "OpenAI's GPT-5.6 Sol • Flagship of the newest generation • Same price as GPT-5.5 • Needs an OpenAI API key"
    case .openaiGPT56Terra:
      return "OpenAI's GPT-5.6 Terra • Balanced tier of the newest generation • Half the price of Sol • Needs an OpenAI API key"
    case .openaiGPT56Luna:
      return "OpenAI's GPT-5.6 Luna • Cheapest of the newest generation • Fast everyday chat • Needs an OpenAI API key"
    case .openaiGPT4oAudio:
      return "OpenAI's GPT Audio • Accepts inline audio for voice-driven prompts • Requires OpenAI API key"
    case .claudeSonnet5:
      return "Anthropic's Claude Sonnet 5 • Best speed/intelligence balance • Text + images • Requires Anthropic API key"
    case .claudeOpus48:
      return "Anthropic's Claude Opus 4.8 • Flagship for complex agentic work • Text + images • Requires Anthropic API key"
    case .claudeFable5:
      return "Anthropic's Claude Fable 5 • Most capable Claude • Next-generation intelligence for long-running agents • Needs an Anthropic API key"
    case .claudeHaiku45:
      return "Anthropic's Claude Haiku 4.5 • Fastest, most cost-efficient Claude • Text + images • Requires Anthropic API key"
    case .customOpenAIEndpoint:
      return "Your own OpenAI-compatible chat server (OpenRouter, LiteLLM, …) • Configure URL + model in Settings → Chat • Uses /chat/completions only (no web search)"
    case .localModel:
      return "Runs fully on your Mac via a local OpenAI-compatible server (Ollama / LM Studio) • No API key, no cloud • Audio is transcribed locally first, then rewritten by the local model • Configure endpoint + model in Dictate Prompt settings"
    }
  }
  
  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.selectedPromptModel
  }
  
  var costLevel: String {
    switch self {
    case .gemini31FlashLite, .gemini35FlashLite, .gemini35Flash, .gemini36Flash, .geminiImage,
         .customOpenAIEndpoint, .localModel, .claudeHaiku45:
      return "Low"
    case .gemini31Pro, .geminiImagePro:
      return "Medium"
    case .grok4, .grok4Reasoning, .grok43, .grok45:
      return "Medium"
    case .openaiGPT5, .openaiGPT55, .openaiGPT56Sol, .openaiGPT56Terra, .openaiGPT4oAudio,
         .claudeSonnet5:
      return "Medium"
    case .openaiGPT5Mini, .openaiGPT56Luna:
      return "Low"
    case .claudeOpus48, .claudeFable5:
      return "High"
    }
  }

  var provider: ChatModelProvider {
    // Deliberately exhaustive, with no `default:` — a `default: return .gemini` used to mean a
    // newly added non-Gemini case silently claimed the Gemini credential and endpoint. Let the
    // compiler force the decision instead.
    switch self {
    case .gemini31Pro, .gemini31FlashLite, .gemini35FlashLite, .gemini35Flash, .gemini36Flash,
         .geminiImage, .geminiImagePro:
      return .gemini
    case .grok4, .grok4Reasoning, .grok43, .grok45:
      return .grok
    case .openaiGPT5, .openaiGPT5Mini, .openaiGPT55, .openaiGPT4oAudio,
         .openaiGPT56Sol, .openaiGPT56Terra, .openaiGPT56Luna:
      return .openai
    case .claudeSonnet5, .claudeOpus48, .claudeHaiku45, .claudeFable5:
      return .anthropic
    case .customOpenAIEndpoint:
      return .customOpenAI
    case .localModel:
      return .local
    }
  }

  /// Whether this model can power Dictate Prompt. Two paths qualify:
  ///   - models that accept audio directly (`supportsDirectAudioInput`), and
  ///   - local models, which can't hear audio but run a transcribe-first flow (offline STT →
  ///     local text rewrite). Drives `dictatePromptCapableModels` and the runtime guard in
  ///     `SpeechService.performPrompt`.
  var supportsDictatePrompt: Bool {
    supportsDirectAudioInput || provider == .local
  }

  /// True for the OpenAI audio-preview models that accept `input_audio` content parts in
  /// Chat Completions requests — i.e. the OpenAI counterpart to Gemini's native audio handling
  /// in Dictate Prompt.
  var supportsDirectAudioInput: Bool {
    // Any Gemini model handles audio natively; on OpenAI only the gpt-audio model does.
    // The image-generation model is the Gemini exception — it only produces images, not audio,
    // so it must never appear in `dictatePromptCapableModels`.
    (provider == .gemini && !generatesImages) || self == .openaiGPT4oAudio
  }

  /// True for native image-generation models (Gemini "Nano Banana"). These route through a
  /// dedicated non-streaming `:generateContent` call with `responseModalities: ["TEXT","IMAGE"]`
  /// (see `GeminiAPIClient.generateImageContent` / `GeminiChatProvider`) instead of the text chat
  /// stream, and don't support tools, grounding, thinking, or streaming. They still accept an
  /// input image (for editing), so `supportsImageInput` stays true.
  var generatesImages: Bool {
    switch self {
    case .geminiImage, .geminiImagePro:
      return true
    default:
      return false
    }
  }

  /// Whether the user has the API key this model's provider needs. Used to gate chat, meeting
  /// summary, Read Aloud smart rewrite, and Smart Improvement.
  var hasRequiredCredential: Bool {
    switch provider {
    case .gemini: return GeminiCredentialProvider.shared.hasCredential()
    case .openai: return KeychainManager.shared.hasValidOpenAIAPIKey()
    case .customOpenAI: return OpenAIChatPreferences.isConfigured
    case .grok: return KeychainManager.shared.hasValidXAIAPIKey()
    case .anthropic: return KeychainManager.shared.hasValidAnthropicAPIKey()
    // Local server needs no API key — reachability is checked at request time, not here.
    case .local: return true
    }
  }

  /// Stricter credential check for Dictate Prompt: OpenAI audio models still hit api.openai.com
  /// directly, so a proxy-only key is not enough.
  var hasRequiredCredentialForDictatePrompt: Bool {
    switch provider {
    case .openai: return KeychainManager.shared.hasValidOpenAIAPIKey()
    default: return hasRequiredCredential
    }
  }

  /// Actionable message when this model can't run Dictate Prompt for lack of a credential.
  var apiKeyRequiredMessageForDictatePrompt: String {
    switch provider {
    case .gemini: return "Add your Gemini API key in Settings (General tab) to use Dictate Prompt."
    case .openai: return "Add your OpenAI API key in Settings (General tab) to use Dictate Prompt."
    case .customOpenAI: return "Custom endpoint is for Chat only. Pick a Gemini, OpenAI GPT-Audio, or local model for Dictate Prompt."
    case .grok: return "Grok can't process audio directly. Pick a Gemini or OpenAI GPT-Audio model in Dictate Prompt settings."
    case .anthropic: return "Claude can't process audio directly. Pick a Gemini, OpenAI GPT-Audio, or local model for Dictate Prompt."
    case .local: return "Set your local server endpoint (Ollama / LM Studio) in Dictate Prompt settings, and make sure it is running."
    }
  }

  /// True for models whose chat endpoint accepts inline image content parts.
  /// OpenAI's gpt-4o-audio-preview is audio-only and rejects `image_url` parts with HTTP 400.
  var supportsImageInput: Bool {
    switch self {
    case .openaiGPT4oAudio:
      return false
    // Local text models in Phase 1 are text-only; no image parts are sent to the local server.
    case .localModel, .customOpenAIEndpoint:
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
    // Phase 1: the local model is wired for Dictate Prompt only. Keeping it out of the chat
    // model lists (chat window, meeting summary, Smart Improvement) until the chat tool-calling
    // path is validated separately. Flip to `true` to surface it in Chat.
    case .localModel:
      return false
    default:
      return true
    }
  }

  /// Chat-lineup pruning: the newer same-provider model that supersedes this one in every
  /// respect that matters for chat, or `nil` if this model is current. Superseded models stay
  /// in the enum because other features still use them (Dictate Prompt takes audio-capable
  /// Gemini models, `speakerConsolidationModel` wants the cheap tier), but every chat-facing
  /// list (chat window picker, Settings → Chat, meeting summary, Smart Improvement) hides
  /// them, and a persisted chat selection is rewritten to the replacement on load — staying
  /// with the same provider so a user with only that provider's key keeps working.
  /// The bar is *Pareto dominance*, not recency: a model is only listed here when a sibling
  /// beats it on every axis at once (quality AND speed AND price). A higher version number is
  /// not enough — Gemini 3.1 Flash-Lite has a 40% cheaper output rate than 3.5 Flash-Lite, and
  /// GPT-5.4 costs half of GPT-5.5, so all of them stay on the frontier and stay selectable.
  /// Verified against the published price tables (see the audit notes in `SettingsDefaults`).
  var chatReplacement: PromptModel? {
    switch self {
    // xAI: both 4.20 variants cost exactly what grok-4.3 costs ($1.25/$2.50 per 1M, same 1M
    // context) while xAI's own docs rank 4.3 above them — dominated on every axis.
    // https://docs.x.ai/docs/models
    case .grok4, .grok4Reasoning: return .grok43
    // OpenAI: gpt-5.6-sol costs exactly what gpt-5.5 costs ($5/$30 per 1M) and gpt-5.6-terra
    // exactly what gpt-5.4 costs ($2.50/$15) — same price, newer generation, so the 5.5/5.4
    // pair is dominated. gpt-5.4-mini is NOT: at $0.75/$4.50 it undercuts gpt-5.6-luna ($1/$6),
    // so it remains the cheapest OpenAI option and stays selectable.
    // https://developers.openai.com/api/docs/pricing
    case .openaiGPT55: return .openaiGPT56Sol
    case .openaiGPT5: return .openaiGPT56Terra
    default: return nil
    }
  }

  /// True when this model is offered in the chat-facing model lists: it must be able to power
  /// a text chat *and* not be superseded by a newer sibling.
  var isSelectableInChat: Bool {
    supportsTextChat && chatReplacement == nil
  }

  /// Gemini-only: the `thinkingConfig` dict to send on chat requests.
  ///
  /// Gemini 3.x models use `thinkingLevel` (`minimal`/`low`/`medium`/`high`). `thinkingBudget`
  /// is NOT honored on 3.x — passing it is silently accepted but can make the model leak its raw
  /// reasoning-channel delimiter tokens (e.g. `start_thought`) into the visible answer. Flash/Lite
  /// tiers use `minimal` (fast first token, streaming UX); Pro uses `high` (quality over latency).
  ///
  /// Gemini 2.5 models still use `thinkingBudget`: `0` disables thinking (Flash), `-1` enables
  /// dynamic thinking (Pro).
  ///
  /// Non-Gemini models return `nil` (the field is ignored by other providers).
  /// Docs: https://ai.google.dev/gemini-api/docs/thinking (3.x: thinkingLevel, not thinkingBudget).
  var geminiThinkingConfig: [String: Any]? {
    switch self {
    // Gemini 3.x — thinkingLevel
    case .gemini31Pro:
      return ["thinkingLevel": "high"]
    case .gemini31FlashLite, .gemini35FlashLite, .gemini35Flash, .gemini36Flash:
      return ["thinkingLevel": "minimal"]
    // Image-generation models — no thinking knob.
    case .geminiImage, .geminiImagePro:
      return nil
    // Non-Gemini — ignored by other providers
    case .grok4, .grok4Reasoning, .grok43, .grok45,
         .openaiGPT5, .openaiGPT5Mini, .openaiGPT55, .openaiGPT4oAudio,
         .openaiGPT56Sol, .openaiGPT56Terra, .openaiGPT56Luna,
         .claudeSonnet5, .claudeOpus48, .claudeHaiku45, .claudeFable5,
         .customOpenAIEndpoint, .localModel:
      return nil
    }
  }

  var isGemini: Bool {
    return provider == .gemini
  }

  /// Cheapest same-provider model for mechanical meeting post-processing (speaker-label
  /// consolidation). That pass only relabels speakers — it doesn't need the summary model's
  /// reasoning quality — yet it echoes the whole transcript back as output, where output-token
  /// price dominates. Staying on the same provider keeps the already-validated credential valid;
  /// providers without a clearly cheaper sibling fall back to `self`.
  var speakerConsolidationModel: PromptModel {
    switch provider {
    case .gemini: return .gemini31FlashLite
    case .openai: return .openaiGPT5Mini
    default: return self
    }
  }

  // Convert to TranscriptionModel for API endpoint access (for Gemini models)
  var asTranscriptionModel: TranscriptionModel? {
    switch self {
    case .gemini31Pro:
      return .gemini31Pro
    case .gemini31FlashLite:
      return .gemini31FlashLite
    case .gemini35FlashLite:
      return .gemini35FlashLite
    case .gemini35Flash:
      return .gemini35Flash
    case .gemini36Flash:
      return .gemini36Flash
    case .geminiImage, .geminiImagePro:
      return nil // image-generation models; not transcription models
    case .grok4, .grok4Reasoning, .grok43, .grok45:
      return nil // Grok models are text-only, no audio transcription
    case .openaiGPT5, .openaiGPT5Mini, .openaiGPT55, .openaiGPT4oAudio,
         .openaiGPT56Sol, .openaiGPT56Terra, .openaiGPT56Luna:
      return nil // OpenAI chat models don't piggy-back on the transcription endpoint here
    case .claudeSonnet5, .claudeOpus48, .claudeHaiku45, .claudeFable5:
      return nil // Claude is chat-only here; no audio transcription endpoint
    case .customOpenAIEndpoint, .localModel:
      return nil // proxy/local LLM is text-only; STT runs through the separate transcription pipeline
    }
  }

  /// Whether this model supports grounding/search.
  /// - Gemini: `google_search` + `url_context` tools on the standard endpoint.
  /// - Grok: `web_search` tool via the Responses API.
  /// - OpenAI text chat models: `web_search` tool via the Responses API (gpt-5.4, gpt-5.4-mini).
  /// - `gpt-4o-audio-preview` is audio-only and routes through Chat Completions only, so
  ///   the Responses API path doesn't apply.
  var supportsGrounding: Bool {
    switch self {
    case .openaiGPT4oAudio, .geminiImage, .geminiImagePro, .customOpenAIEndpoint, .localModel,
         .claudeSonnet5, .claudeOpus48, .claudeHaiku45, .claudeFable5:
      // Audio-only, image-generation, proxy, local, and Anthropic models have no web-search path
      // in this app (Claude web search would need a separate Anthropic tool wiring).
      return false
    default:
      return true
    }
  }

  /// All models available for the chat window (all providers). Excludes audio-only
  /// models such as `openaiGPT4oAudio`, which the OpenAI API rejects on text-only requests,
  /// and models superseded by a newer sibling (see `chatReplacement`).
  static var chatModels: [PromptModel] {
    return allCases.filter { $0.isSelectableInChat }
  }

  /// Chat models suitable for text-only tasks such as Smart Improvement: excludes
  /// image-generation models (Nano Banana), which return images rather than the text
  /// analysis these features need.
  static var textChatModels: [PromptModel] {
    return chatModels.filter { !$0.generatesImages }
  }

  /// Models eligible for Dictate Prompt: every model that can accept inline audio directly.
  /// Gemini handles audio natively across all variants; OpenAI's GPT-4o Audio Preview handles
  /// it via `input_audio` content parts. Grok and text-only OpenAI models are excluded.
  static var dictatePromptCapableModels: [PromptModel] {
    return allCases.filter { $0.supportsDictatePrompt }
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
    case "gpt-5":
      // Superseded by the gpt-5.4 generation (2026-03); forward to the current flagship case.
      return Self.openaiGPT5.rawValue
    case "gpt-5-mini":
      // Superseded by gpt-5.4-mini; forward to the current mini case.
      return Self.openaiGPT5Mini.rawValue
    case "gemini-3-pro-preview":
      // Shut down by Google 2026-03-09 (now returns 404); forward to the current Pro preview.
      return Self.gemini31Pro.rawValue
    case "gemini-2.5-flash":
      // Deprecated, shutdown 2026-10-16; Google's named replacement is gemini-3.5-flash.
      return Self.gemini35Flash.rawValue
    case "gemini-2.5-flash-lite":
      // Deprecated, shutdown 2026-10-16; replacement is the current Flash-Lite.
      return Self.gemini31FlashLite.rawValue
    case "gemini-2.5-pro":
      // Deprecated, shutdown 2026-10-16; replacement is the current Pro preview.
      return Self.gemini31Pro.rawValue
    case "gemini-3-flash-preview":
      // Deprecated-pending; Google says use gemini-3.5-flash.
      return Self.gemini35Flash.rawValue
    default:
      return raw
    }
  }

  /// Loads any UserDefaults slot that must hold a chat-capable model (chat window, meeting
  /// summary, Smart Improvement). On top of `loadPromptModel` it forwards a superseded
  /// selection to its replacement and persists that, so the value always appears in the
  /// pickers, which list `chatModels`.
  static func loadChatSlotModel(forKey key: String, default fallback: PromptModel) -> PromptModel {
    let loaded = loadPromptModel(forKey: key, default: fallback, validate: { $0.supportsTextChat })
    guard let replacement = loaded.chatReplacement else { return loaded }
    UserDefaults.standard.set(replacement.rawValue, forKey: key)
    return replacement
  }

  /// Loads the model selected for the chat window (Settings → Chat).
  static func loadSelectedChatModel() -> PromptModel {
    loadChatSlotModel(
      forKey: UserDefaultsKeys.selectedChatModel,
      default: SettingsDefaults.selectedChatModel
    )
  }

  /// Loads the model selected for meeting summary (rolling and final). Settings → Live Meeting → Summary Model.
  static func loadSelectedMeetingSummary() -> PromptModel {
    loadChatSlotModel(
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

  /// UserDefaults key under which this provider's selected Read Aloud voice is persisted.
  /// Voice is stored per provider (not per model) so switching providers and back keeps each
  /// provider's chosen voice.
  var voiceUserDefaultsKey: String {
    switch self {
    case .gemini: return UserDefaultsKeys.selectedReadAloudVoiceGemini
    case .openai: return UserDefaultsKeys.selectedReadAloudVoiceOpenAI
    case .xai: return UserDefaultsKeys.selectedReadAloudVoiceXAI
    }
  }

  /// The voice catalogue this provider's TTS API accepts, ordered male → female → neutral
  /// (stable within each group). Voice ids are provider-specific (a Gemini voice name is not
  /// valid for OpenAI/xAI and vice versa). Live-verified 2026-05-30 against each provider's docs.
  var voices: [TTSVoice] {
    let raw: [TTSVoice]
    switch self {
    case .gemini: raw = TTSVoice.geminiVoices
    case .openai: raw = TTSVoice.openAIVoices
    case .xai: raw = TTSVoice.xaiVoices
    }
    // Stable sort by gender: Swift's sort isn't guaranteed stable, so tie-break on original index.
    return raw.enumerated()
      .sorted { lhs, rhs in
        let lRank = TTSVoice.genderRank(lhs.element.gender)
        let rRank = TTSVoice.genderRank(rhs.element.gender)
        return lRank != rRank ? lRank < rRank : lhs.offset < rhs.offset
      }
      .map { $0.element }
  }
}

// MARK: - TTS Voice

/// A selectable Read Aloud voice for one provider. `id` is the value the provider's API expects
/// (Gemini `voiceName`, OpenAI `voice`, xAI `voice_id`); `gender` is a short m/w/neutral hint and
/// `descriptor` is a short style hint — both shown in the picker.
struct TTSVoice: Identifiable, Hashable {
  let id: String
  /// "m" / "w" / "neutral" (German: männlich/weiblich). Empty when unknown.
  let gender: String
  let descriptor: String

  /// Display ordering rank by gender: male first, then female, then neutral/unknown.
  static func genderRank(_ gender: String) -> Int {
    switch gender {
    case "m": return 0
    case "w": return 1
    default: return 2
    }
  }

  /// e.g. "Charon (m) — Informative" for the dropdown.
  var displayName: String {
    let genderPart = gender.isEmpty ? "" : " (\(gender))"
    let stylePart = descriptor.isEmpty ? "" : " — \(descriptor)"
    return "\(id.capitalized)\(genderPart)\(stylePart)"
  }

  // Gemini's 30 prebuilt voices (https://ai.google.dev/gemini-api/docs/speech-generation).
  // Charon first — it is the Gemini default (TTSModel.defaultVoice).
  // Gender per Google Cloud TTS docs (https://docs.cloud.google.com/text-to-speech/docs/gemini-tts):
  // 14 female (w) / 16 male (m), official.
  static let geminiVoices: [TTSVoice] = [
    TTSVoice(id: "Charon", gender: "m", descriptor: "Informative"),
    TTSVoice(id: "Zephyr", gender: "w", descriptor: "Bright"),
    TTSVoice(id: "Puck", gender: "m", descriptor: "Upbeat"),
    TTSVoice(id: "Kore", gender: "w", descriptor: "Firm"),
    TTSVoice(id: "Fenrir", gender: "m", descriptor: "Excitable"),
    TTSVoice(id: "Leda", gender: "w", descriptor: "Youthful"),
    TTSVoice(id: "Orus", gender: "m", descriptor: "Firm"),
    TTSVoice(id: "Aoede", gender: "w", descriptor: "Breezy"),
    TTSVoice(id: "Callirrhoe", gender: "w", descriptor: "Easy-going"),
    TTSVoice(id: "Autonoe", gender: "w", descriptor: "Bright"),
    TTSVoice(id: "Enceladus", gender: "m", descriptor: "Breathy"),
    TTSVoice(id: "Iapetus", gender: "m", descriptor: "Clear"),
    TTSVoice(id: "Umbriel", gender: "m", descriptor: "Easy-going"),
    TTSVoice(id: "Algieba", gender: "m", descriptor: "Smooth"),
    TTSVoice(id: "Despina", gender: "w", descriptor: "Smooth"),
    TTSVoice(id: "Erinome", gender: "w", descriptor: "Clear"),
    TTSVoice(id: "Algenib", gender: "m", descriptor: "Gravelly"),
    TTSVoice(id: "Rasalgethi", gender: "m", descriptor: "Informative"),
    TTSVoice(id: "Laomedeia", gender: "w", descriptor: "Upbeat"),
    TTSVoice(id: "Achernar", gender: "w", descriptor: "Soft"),
    TTSVoice(id: "Alnilam", gender: "m", descriptor: "Firm"),
    TTSVoice(id: "Schedar", gender: "m", descriptor: "Even"),
    TTSVoice(id: "Gacrux", gender: "w", descriptor: "Mature"),
    TTSVoice(id: "Pulcherrima", gender: "w", descriptor: "Forward"),
    TTSVoice(id: "Achird", gender: "m", descriptor: "Friendly"),
    TTSVoice(id: "Zubenelgenubi", gender: "m", descriptor: "Casual"),
    TTSVoice(id: "Vindemiatrix", gender: "w", descriptor: "Gentle"),
    TTSVoice(id: "Sadachbia", gender: "m", descriptor: "Lively"),
    TTSVoice(id: "Sadaltager", gender: "m", descriptor: "Knowledgeable"),
    TTSVoice(id: "Sulafat", gender: "w", descriptor: "Warm"),
  ]

  // OpenAI gpt-4o-mini-tts voices (https://platform.openai.com/docs/guides/text-to-speech).
  // alloy first — it is the OpenAI default (TTSModel.defaultVoice). marin/cedar are OpenAI's
  // recommended highest-quality voices for this model.
  // OpenAI does not publish a gender per voice; the m/w hints below follow the widely-reported
  // community perception (alloy is the intentionally neutral/androgynous voice).
  static let openAIVoices: [TTSVoice] = [
    TTSVoice(id: "alloy", gender: "neutral", descriptor: ""),
    TTSVoice(id: "ash", gender: "m", descriptor: ""),
    TTSVoice(id: "ballad", gender: "m", descriptor: ""),
    TTSVoice(id: "coral", gender: "w", descriptor: ""),
    TTSVoice(id: "echo", gender: "m", descriptor: ""),
    TTSVoice(id: "fable", gender: "m", descriptor: ""),
    TTSVoice(id: "nova", gender: "w", descriptor: ""),
    TTSVoice(id: "onyx", gender: "m", descriptor: ""),
    TTSVoice(id: "sage", gender: "w", descriptor: ""),
    TTSVoice(id: "shimmer", gender: "w", descriptor: ""),
    TTSVoice(id: "verse", gender: "m", descriptor: ""),
    TTSVoice(id: "marin", gender: "w", descriptor: "Recommended"),
    TTSVoice(id: "cedar", gender: "m", descriptor: "Recommended"),
  ]

  // xAI Grok Voice TTS voices (https://docs.x.ai/developers/model-capabilities/audio/text-to-speech).
  // xAI does not document a gender per voice; the m/w hints are best-effort by perceived voice.
  static let xaiVoices: [TTSVoice] = [
    TTSVoice(id: "eve", gender: "w", descriptor: "Energetic, upbeat"),
    TTSVoice(id: "ara", gender: "w", descriptor: "Warm, friendly"),
    TTSVoice(id: "rex", gender: "m", descriptor: "Confident, clear"),
    TTSVoice(id: "sal", gender: "m", descriptor: "Smooth, balanced"),
    TTSVoice(id: "leo", gender: "m", descriptor: "Authoritative, strong"),
  ]
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

  /// Default voice when the caller doesn't specify one. Each provider has its own voice
  /// catalogue, so "Charon" (Gemini) is not valid for OpenAI/xAI and vice versa.
  var defaultVoice: String {
    switch provider {
    case .gemini: return "Charon"
    case .openai: return "alloy"
    case .xai: return "eve"
    }
  }

  /// The voices selectable for this model's provider (for the Read Aloud voice picker).
  var availableVoices: [TTSVoice] { provider.voices }

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

  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.readAloudModel
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
    let storedRaw = UserDefaults.standard.string(forKey: key)
    let raw = storedRaw ?? fallback.rawValue
    let migratedRaw = migrateLegacyReadAloudRawValue(raw)
    if let storedRaw, migratedRaw != storedRaw {
      UserDefaults.standard.set(migratedRaw, forKey: key)
    }
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

  /// Loads the duration stored under `key`, falling back to `fallback` when unset or invalid.
  static func loadFromUserDefaults(forKey key: String, default fallback: NotificationDuration) -> NotificationDuration {
    let saved = UserDefaults.standard.double(forKey: key)
    guard saved > 0 else { return fallback }
    return NotificationDuration(rawValue: saved) ?? fallback
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
  case improvement = "Smart Improvement"
  case permissions = "Permissions"
  case about = "About"
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

  /// The voice the user picked for `model`'s provider, or that provider's default voice. Falls
  /// back to the default when the stored id is empty or no longer in the provider's catalogue
  /// (e.g. a voice the provider has since removed).
  static func voice(for model: TTSModel) -> String {
    let stored = (UserDefaults.standard.string(forKey: model.provider.voiceUserDefaultsKey) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !stored.isEmpty, model.availableVoices.contains(where: { $0.id == stored }) else {
      return model.defaultVoice
    }
    return stored
  }
}

// MARK: - Custom OpenAI-compatible Chat Preferences (UserDefaults + Keychain Accessors)
/// Settings for the explicit **Custom endpoint** chat model (`PromptModel.customOpenAIEndpoint`).
/// Regular OpenAI models (GPT-5, …) always use api.openai.com regardless of these values.
enum OpenAIChatPreferences {
  static let sentinelModelRawValue = PromptModel.customOpenAIEndpoint.rawValue

  /// Non-empty when the user configured a custom base URL in Settings → Chat.
  static var customEndpointBaseURL: String? {
    let trimmed = (UserDefaults.standard.string(forKey: UserDefaultsKeys.customOpenAIChatEndpointURL) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Model tag sent to the proxy (e.g. `openai/gpt-4o` on OpenRouter).
  static var modelID: String {
    let v = (UserDefaults.standard.string(forKey: UserDefaultsKeys.customOpenAIChatModelID) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? SettingsDefaults.customOpenAIChatModelID : v
  }

  /// API key for the custom endpoint: proxy-specific key if set, otherwise the standard OpenAI key.
  static var resolvedAPIKey: String? {
    let custom = KeychainManager.shared.getCustomOpenAIChatAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let custom, !custom.isEmpty { return custom }
    let standard = KeychainManager.shared.getOpenAIAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let standard, !standard.isEmpty { return standard }
    return nil
  }

  /// True when URL + any usable API key are set — required before the Custom endpoint model can run.
  static var isConfigured: Bool {
    customEndpointBaseURL != nil && resolvedAPIKey != nil
  }

  static func isCustomEndpointModel(_ model: String) -> Bool {
    model == sentinelModelRawValue
  }

  static func resolvedRequestModelID(for model: String) -> String {
    isCustomEndpointModel(model) ? modelID : model
  }

  /// Applies the [OpenInference](https://openinference.de/) URL + GLM 5.2 model preset.
  static func applyOpenInferencePreset() {
    UserDefaults.standard.set(SettingsDefaults.openInferenceEndpointURL, forKey: UserDefaultsKeys.customOpenAIChatEndpointURL)
    UserDefaults.standard.set(SettingsDefaults.openInferenceModelID, forKey: UserDefaultsKeys.customOpenAIChatModelID)
  }

  static var chatCompletionsURL: String {
    guard let base = customEndpointBaseURL else {
      return "https://invalid.local/missing-custom-openai-endpoint"
    }
    return appendPath("chat/completions", to: base)
  }

  private static func appendPath(_ pathSuffix: String, to base: String) -> String {
    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
    if trimmed.hasSuffix("/\(pathSuffix)") { return trimmed }
    return trimmed + "/\(pathSuffix)"
  }
}

// MARK: - Local LLM Preferences (UserDefaults Accessors)
/// Centralized read accessors for the local OpenAI-compatible server settings (Ollama / LM Studio),
/// so `SpeechService` / `LocalLLMChatProvider` don't each coalesce-with-default the same keys.
enum LocalLLMPreferences {
  /// Base URL up to `/v1` (no trailing `/chat/completions`). Falls back to the default endpoint.
  static var endpointBaseURL: String {
    let v = (UserDefaults.standard.string(forKey: UserDefaultsKeys.localPromptEndpointURL) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? SettingsDefaults.localEndpointURL : v
  }

  /// The model tag to request (e.g. an Ollama tag). Falls back to the default model id.
  static var modelID: String {
    let v = (UserDefaults.standard.string(forKey: UserDefaultsKeys.localPromptModelID) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? SettingsDefaults.localModelID : v
  }

  /// Full chat-completions URL, normalizing a trailing slash on the base URL.
  static var chatCompletionsURL: String {
    let base = endpointBaseURL
    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
    return trimmed + "/chat/completions"
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
  // Dictation runs on Flash-Lite: audio input dominates the bill (~32 tokens/s), and 3.5 Flash-Lite
  // charges $0.30/1M for audio vs $0.50/1M on 3.1 Flash-Lite — cheaper per dictated minute despite
  // the higher output rate. Chat/Dictate Prompt run on 3.6 Flash: same input price as 3.5 Flash
  // ($1.50/1M) but $7.50/1M output instead of $9.00. https://ai.google.dev/gemini-api/docs/pricing
  static let selectedTranscriptionModel = TranscriptionModel.gemini35FlashLite
  static let selectedPromptModel = PromptModel.gemini36Flash
  static let selectedChatModel = PromptModel.gemini36Flash
  static let chatCloseOnFocusLoss = true
  // Off by default: a Settings window that vanishes when you click elsewhere (e.g. to copy an
  // API key from a browser) is surprising. Users can opt back in via the Behavior section.
  static let settingsCloseOnFocusLoss = false

  // MARK: - Read Aloud (Chat TTS)
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
  /// Bottom-center so popups share one feedback spot with the recording indicator pill.
  static let notificationPosition = NotificationPosition.centerBottom
  static let notificationDuration = NotificationDuration.oneSecond
  static let errorNotificationDuration = NotificationDuration.thirtySeconds

  // MARK: - Recording Safeguards
  static let confirmAboveDuration = ConfirmAboveDuration.fiveMinutes

  // MARK: - Auto-Paste Settings
  // OFF by default: auto-paste is the only feature that needs the Accessibility
  // permission (it simulates a ⌘V keystroke). Keeping it opt-in means a fresh
  // install never requires Accessibility, which it must not for its core features
  // (App Store Guideline 2.4.5). Users enable it explicitly in Settings → General.
  static let autoPasteAfterDictation = false

  // MARK: - Fn Push-to-Talk
  // OFF by default for the same reason as auto-paste: observing the Fn key needs global
  // event monitors, which only work with the Accessibility permission — a fresh install
  // must not require it (App Store Guideline 2.4.5).
  static let holdFnToDictate = false

  // MARK: - Screenshot Settings
  static let screenshotInPromptMode = true
  static let screenshotSaveEnabled = false

  // MARK: - Live Meeting Settings
  // 60s (rather than 30s) halves the number of chunk-transcription API calls per meeting and
  // halves how often the diarization prompt is re-sent, at the cost of a slightly less live
  // transcript. Users who want faster updates can lower it in Chat settings.
  static let liveMeetingChunkInterval = LiveMeetingChunkInterval.sixtySeconds
  static let liveMeetingSafeguardDuration = MeetingSafeguardDuration.ninetyMinutes
  static let selectedMeetingSummaryModel = PromptModel.gemini36Flash

  static let selectedImprovementModel = PromptModel.gemini31Pro

  // MARK: - Local LLM (OpenAI-compatible server, e.g. Ollama / LM Studio)
  /// Base URL up to and including `/v1`. The provider appends `/chat/completions`. Ollama's
  /// default OpenAI-compatible endpoint is `http://localhost:11434/v1`.
  static let localEndpointURL = "http://localhost:11434/v1"
  /// Default model tag requested from the local server when the user hasn't set one.
  static let localModelID = "qwen3"
  /// Default model tag for the Custom endpoint chat model (OpenRouter-style slug).
  static let customOpenAIChatModelID = "openai/gpt-4o"
  /// [OpenInference](https://openinference.de/) preset — EU-hosted GLM 5.2, OpenAI-compatible.
  static let openInferenceEndpointURL = "https://openinference.de/api/v1"
  static let openInferenceModelID = "zai-org/GLM-5.2"

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
  /// Selected Read Aloud voice per provider. Persisted under the provider-specific keys; empty
  /// means "use the provider's default voice". Indexed via `readAloudVoice(for:)`.
  var readAloudVoiceGemini: String = ""
  var readAloudVoiceOpenAI: String = ""
  var readAloudVoiceXAI: String = ""

  /// The selected Read Aloud voice id for `provider` ("" → provider default).
  func readAloudVoice(for provider: TTSProvider) -> String {
    switch provider {
    case .gemini: return readAloudVoiceGemini
    case .openai: return readAloudVoiceOpenAI
    case .xai: return readAloudVoiceXAI
    }
  }

  mutating func setReadAloudVoice(_ id: String, for provider: TTSProvider) {
    switch provider {
    case .gemini: readAloudVoiceGemini = id
    case .openai: readAloudVoiceOpenAI = id
    case .xai: readAloudVoiceXAI = id
    }
  }

  // MARK: - Model & Prompt Settings
  var selectedTranscriptionModel: TranscriptionModel = SettingsDefaults.selectedTranscriptionModel
  var selectedPromptModel: PromptModel = SettingsDefaults.selectedPromptModel
  var selectedChatModel: PromptModel = SettingsDefaults.selectedChatModel
  var selectedImprovementModel: PromptModel = SettingsDefaults.selectedImprovementModel
  var selectedReadAloudModel: TTSModel = SettingsDefaults.readAloudModel
  var chatCloseOnFocusLoss: Bool = SettingsDefaults.chatCloseOnFocusLoss
  var settingsCloseOnFocusLoss: Bool = SettingsDefaults.settingsCloseOnFocusLoss

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

  // MARK: - Fn Push-to-Talk
  var holdFnToDictate: Bool = SettingsDefaults.holdFnToDictate

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

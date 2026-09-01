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
  /// In-process MLX LLM (no server). Model catalogue and downloads mirror offline Whisper.
  case localMLX

  /// Model selected when the user invokes the bare provider slash-command
  /// (`/gemini`, `/grok`, `/gpt`, `/claude`) with no qualifier, AND when `/model <provider>`
  /// is typed with no further narrowing keyword. Single source of truth so the
  /// autocomplete hint, the bare-command dispatch in `ChatView`, and the
  /// no-qualifier branch in `ChatModelCommandResolver` never drift apart —
  /// they all read `defaultChatModel` from here.
  var defaultChatModel: PromptModel {
    switch self {
    case .gemini: return .gemini37Flash
    case .grok:   return .grok43
    case .openai: return .openaiGPT56Sol
    case .anthropic: return .claudeSonnet5
    case .customOpenAI: return .customOpenAIEndpoint
    case .local:  return .localModel
    case .localMLX: return .localMLXQwen34BInstruct
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
    case .localMLX: return "mlx"
    }
  }
}

// MARK: - Unified Prompt Model Enum (for Dictate Prompt) - Gemini multimodal models + Grok
// Current Gemini model IDs: https://ai.google.dev/gemini-api/docs/models (Gemini API, not Vertex AI).
// GA: gemini-3.1-flash-lite, gemini-3.5-flash-lite, gemini-3.5-flash, gemini-3.6-flash,
// gemini-3.7-flash (shipped 2026-08-13; https://ai.google.dev/gemini-api/docs/models).
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
  case gemini37Flash = "gemini-3.7-flash"

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
  /// Previous flagship; same $2/$6 and 500k context as `grok-4.6`, which xAI now ranks above it —
  /// hidden from chat pickers via `chatReplacement`.
  case grok45 = "grok-4.5"
  /// xAI's current flagship: same price/context as 4.5 ($2.00/$6.00, 500k), newer and preferred
  /// per https://docs.x.ai/docs/models. Does NOT supersede grok-4.3 — that stays for the cheaper
  /// $1.25/$2.50 / 1M-context rung.
  case grok46 = "grok-4.6"

  // OpenAI Models (chat + Dictate Prompt via Chat Completions API)
  // The case identifiers keep their historical names while the rawValue tracks the current
  // vendor slug: `gpt-5` → `gpt-5.4` and `gpt-5-mini` → `gpt-5.4-mini` (newer GA generation,
  // 2026-03). Persisted `gpt-5`/`gpt-5-mini` selections forward via migrateLegacyPromptRawValue.
  case openaiGPT5 = "gpt-5.4"
  case openaiGPT5Mini = "gpt-5.4-mini"
  case openaiGPT55 = "gpt-5.5"
  // GPT-5.6 family (2026-07). sol matches gpt-5.5 at $5/$30; terra *undercuts* gpt-5.4 at
  // $2.00/$12 (vs $2.50/$15) — which is what makes those two Pareto-dominated (same price or
  // cheaper, newer generation). luna is the nano rung at $0.20/$1.20 with 1.05M context — see
  // `chatReplacement` for why gpt-5.4-mini survives it on tier positioning alone.
  // Prices verified 2026-08-03.
  // https://developers.openai.com/api/docs/pricing — verified live via scripts/test-openai-models.sh.
  case openaiGPT56Sol = "gpt-5.6-sol"
  case openaiGPT56Terra = "gpt-5.6-terra"
  case openaiGPT56Luna = "gpt-5.6-luna"
  /// Audio-input chat model. Accepts inline `input_audio` content parts, which makes it the
  /// counterpart to Gemini for Dictate Prompt (the model "hears" the audio directly).
  ///
  /// Slug history, both handled by `migrateLegacyPromptRawValue`:
  /// `gpt-4o-audio-preview` → `gpt-audio` (rename) → `gpt-audio-1.5` (deprecation: OpenAI retires
  /// `gpt-audio` on 2027-01-20 and names 1.5 as the replacement, at identical pricing —
  /// $32/$64 per 1M audio, $2.50/$10 text).
  /// Reference: https://developers.openai.com/api/docs/deprecations
  case openaiGPT4oAudio = "gpt-audio-1.5"

  // OpenAI-compatible chat proxy (OpenRouter, LiteLLM, self-hosted, …). The rawValue is a stable
  // sentinel — the actual model tag sent to the server is read from `OpenAIChatPreferences.modelID`.
  case customOpenAIEndpoint = "custom-openai-endpoint"

  // Anthropic Claude (Messages API). Chat-only — no Dictate Prompt / TTS wiring.
  // Model IDs: https://platform.claude.com/docs/en/about-claude/models/overview (verified 2026-07).
  case claudeSonnet5 = "claude-sonnet-5"
  /// Anthropic's current Opus. Same $5/$25 per 1M and same 1M context as 4.8, newer generation,
  /// knowledge cutoff May 2026 vs Jan 2026 — which is why 4.8 is hidden via `chatReplacement`.
  case claudeOpus5 = "claude-opus-5"
  /// Superseded by `claudeOpus5`; Anthropic lists it under "Legacy models". Kept as a case so
  /// persisted selections still resolve and forward.
  case claudeOpus48 = "claude-opus-4-8"
  case claudeHaiku45 = "claude-haiku-4-5-20251001"
  /// Anthropic's most capable widely released model (GA since 2026-06-09), $10/$50 per 1M.
  case claudeFable5 = "claude-fable-5"

  // Local model served by an OpenAI-compatible server on the user's machine (Ollama / LM Studio).
  // The rawValue is a stable sentinel — the *actual* model tag sent to the server is configurable
  // and read from `LocalLLMPreferences.modelID`, so one enum case covers whatever the user pulled.
  case localModel = "local-llm"

  // In-process MLX models (no server). One enum case per catalogue entry; weights download like
  // offline Whisper and route through `MLXChatProvider`.
  case localMLXQwen34BInstruct = "local-mlx-qwen3-4b-instruct-2507"
  case localMLXQwen38B = "local-mlx-qwen3-8b"

  /// Maps a catalogue entry to its picker / settings enum case.
  static func forLocalLLMModel(_ type: LocalLLMModelType) -> PromptModel {
    switch type {
    case .qwen34BInstruct2507: return .localMLXQwen34BInstruct
    case .qwen38B: return .localMLXQwen38B
    }
  }

  /// Inverse of `forLocalLLMModel`; nil for cloud / HTTP-local models.
  var localMLXModelType: LocalLLMModelType? {
    switch self {
    case .localMLXQwen34BInstruct: return .qwen34BInstruct2507
    case .localMLXQwen38B: return .qwen38B
    default: return nil
    }
  }

  /// Every in-process MLX model offered in Dictate Prompt / Chat pickers.
  static var localMLXModels: [PromptModel] {
    LocalLLMModelType.offerable.map(\.promptModel)
  }

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
    case .gemini37Flash:
      return "Gemini 3.7 Flash"
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
    case .grok46:
      return "Grok 4.6"
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
    case .claudeOpus5:
      return "Claude Opus 5"
    case .claudeOpus48:
      return "Claude Opus 4.8"
    case .claudeHaiku45:
      return "Claude Haiku 4.5"
    case .claudeFable5:
      return "Claude Fable 5"
    case .customOpenAIEndpoint:
      // Names the endpoint that is actually configured. "Custom endpoint (OpenRouter / proxy)" was
      // 36 characters in a chip that sits next to the composer's slash-command row — it squeezed
      // those buttons until they hyphenated mid-word ("/at-tach", "/scree-nshot"). Naming the real
      // target is both shorter and more useful than naming the mechanism.
      return OpenAIChatPreferences.isOpenRouterEndpoint ? "OpenRouter" : "Custom endpoint"
    case .localModel:
      return "Local Server (Ollama / LM Studio)"
    case .localMLXQwen34BInstruct:
      return "Qwen3 4B Instruct (Offline)"
    case .localMLXQwen38B:
      return "Qwen3 8B (Offline)"
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
    case .gemini37Flash:     return "gemini37flash"
    case .geminiImage:       return "geminiimage"
    case .geminiImagePro:    return "geminiimagepro"
    case .grok4:             return "grok4"
    case .grok4Reasoning:    return "grok4reasoning"
    case .grok43:            return "grok43"
    case .grok45:            return "grok45"
    case .grok46:            return "grok46"
    case .openaiGPT5:        return "gpt54"
    case .openaiGPT5Mini:    return "gpt54mini"
    case .openaiGPT55:       return "gpt55"
    case .openaiGPT56Sol:    return "gpt56sol"
    case .openaiGPT56Terra:  return "gpt56terra"
    case .openaiGPT56Luna:   return "gpt56luna"
    case .openaiGPT4oAudio:  return "gptaudio" // audio-only; excluded from chatModels, never surfaced
    case .claudeSonnet5:     return "claudesonnet5"
    case .claudeOpus5:       return "claudeopus5"
    case .claudeOpus48:      return "claudeopus48"
    case .claudeHaiku45:     return "claudehaiku45"
    case .claudeFable5:      return "claudefable5"
    case .customOpenAIEndpoint: return "custom"
    case .localModel:        return "local"
    case .localMLXQwen34BInstruct: return "mlx4b"
    case .localMLXQwen38B:   return "mlx8b"
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
      return "Google's Gemini 3.5 Flash • Legacy Flash • Strong on agentic + coding tasks • Multimodal"
    case .gemini36Flash:
      return "Google's Gemini 3.6 Flash • Previous-generation Flash • Balances speed with intelligence • Multimodal"
    case .gemini37Flash:
      return "Google's Gemini 3.7 Flash • Newest Flash • Most capable workhorse for coding and agents • Multimodal"
    case .geminiImage:
      return "Google's Gemini Image (Nano Banana 2) • Generates and edits images from a prompt + optional input image • Free tier • Requires Gemini API key"
    case .geminiImagePro:
      return "Google's Gemini Image Pro (Nano Banana Pro) • Studio-quality image generation/editing up to 4K • Best text rendering • Paid (no free tier) • Requires Gemini API key"
    case .grok4:
      return "xAI's Grok 4.20 • Frontier-class intelligence • Web + X search • Requires xAI API key"
    case .grok4Reasoning:
      return "xAI's Grok 4.20 Reasoning • Extended thinking for complex tasks • Web + X search • Requires xAI API key"
    case .grok45:
      return "xAI's Grok 4.5 • Previous flagship • 500k context • Needs an xAI API key"
    case .grok46:
      return "xAI's Grok 4.6 • xAI's most intelligent and fastest model • 500k context • Needs an xAI API key"
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
    case .claudeOpus5:
      return "Anthropic's Claude Opus 5 • For complex agentic coding and enterprise work • Text + images • Requires Anthropic API key"
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
    case .localMLXQwen34BInstruct:
      return "mlx-community/Qwen3-4B-Instruct-2507-4bit • Recommended offline LLM • In-process MLX, no server • ~2.3 GB • Offline"
    case .localMLXQwen38B:
      return "mlx-community/Qwen3-8B-4bit • Larger offline LLM • In-process MLX, no server • ~4.5 GB • Offline"
    }
  }
  
  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.selectedPromptModel
  }
  
  var costLevel: String {
    switch self {
    case .gemini31FlashLite, .gemini35FlashLite, .gemini35Flash, .gemini36Flash, .gemini37Flash,
         .geminiImage, .customOpenAIEndpoint, .localModel, .claudeHaiku45:
      return "Low"
    case .localMLXQwen34BInstruct, .localMLXQwen38B:
      return "Free (Offline)"
    case .gemini31Pro, .geminiImagePro:
      return "Medium"
    case .grok4, .grok4Reasoning, .grok43, .grok45, .grok46:
      return "Medium"
    case .openaiGPT5, .openaiGPT55, .openaiGPT56Sol, .openaiGPT56Terra, .openaiGPT4oAudio,
         .claudeSonnet5:
      return "Medium"
    case .openaiGPT5Mini, .openaiGPT56Luna:
      return "Low"
    case .claudeOpus5, .claudeOpus48, .claudeFable5:
      return "High"
    }
  }

  var provider: ChatModelProvider {
    // Deliberately exhaustive, with no `default:` — a `default: return .gemini` used to mean a
    // newly added non-Gemini case silently claimed the Gemini credential and endpoint. Let the
    // compiler force the decision instead.
    switch self {
    case .gemini31Pro, .gemini31FlashLite, .gemini35FlashLite, .gemini35Flash, .gemini36Flash,
         .gemini37Flash, .geminiImage, .geminiImagePro:
      return .gemini
    case .grok4, .grok4Reasoning, .grok43, .grok45, .grok46:
      return .grok
    case .openaiGPT5, .openaiGPT5Mini, .openaiGPT55, .openaiGPT4oAudio,
         .openaiGPT56Sol, .openaiGPT56Terra, .openaiGPT56Luna:
      return .openai
    case .claudeSonnet5, .claudeOpus5, .claudeOpus48, .claudeHaiku45, .claudeFable5:
      return .anthropic
    case .customOpenAIEndpoint:
      return .customOpenAI
    case .localModel:
      return .local
    case .localMLXQwen34BInstruct, .localMLXQwen38B:
      return .localMLX
    }
  }

  /// Whether this model can power Dictate Prompt. Two paths qualify:
  ///   - models that accept audio directly (`supportsDirectAudioInput`), and
  ///   - local models, which can't hear audio but run a transcribe-first flow (offline STT →
  ///     local text rewrite). Drives `dictatePromptCapableModels` and the runtime guard in
  ///     `SpeechService.performPrompt`.
  var supportsDictatePrompt: Bool {
    supportsDirectAudioInput || provider == .local || provider == .localMLX
  }

  /// Whether this model's Dictate Prompt selection is read from a screenshot rather than the
  /// clipboard.
  ///
  /// Build-wide in principle (`AppConstants.dictatePromptUsesScreenshotSelection`), but never for
  /// a local model: those are text-only, so a screenshot reaches them as nothing at all. That
  /// combination used to send the "edit the highlighted region" system prompt with no image *and*
  /// no clipboard — an instruction to read something the model was never given, which is why the
  /// App Store build's local Dictate Prompt answered with the instruction tidied up.
  ///
  /// Reading the pasteboard needs no Accessibility permission; only the synthetic ⌘C does. So the
  /// local path uses the clipboard in every build, and in the App Store build the user copies for
  /// themselves.
  var dictatePromptUsesScreenshotSelection: Bool {
    AppConstants.dictatePromptUsesScreenshotSelection && provider != .local && provider != .localMLX
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
    case .openai: return KeychainManager.shared.hasNonEmpty(.openAI)
    case .customOpenAI: return OpenAIChatPreferences.isConfigured
    case .grok: return KeychainManager.shared.hasNonEmpty(.xai)
    case .anthropic: return KeychainManager.shared.hasNonEmpty(.anthropic)
    // Local server and in-process MLX need no API key — reachability is checked at request time.
    case .local, .localMLX: return true
    }
  }

  /// Stricter credential check for Dictate Prompt: OpenAI audio models still hit api.openai.com
  /// directly, so a proxy-only key is not enough.
  var hasRequiredCredentialForDictatePrompt: Bool {
    switch provider {
    case .openai: return KeychainManager.shared.hasNonEmpty(.openAI)
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
    case .localMLX: return "Select an offline MLX model above. It downloads automatically when you pick it or dictate with it."
    }
  }

  /// True for models whose chat endpoint accepts inline image content parts.
  /// OpenAI's gpt-4o-audio-preview is audio-only and rejects `image_url` parts with HTTP 400.
  var supportsImageInput: Bool {
    switch self {
    case .openaiGPT4oAudio:
      return false
    // Local text models in Phase 1 are text-only; no image parts are sent to the local server.
    case .localModel, .customOpenAIEndpoint, .localMLXQwen34BInstruct, .localMLXQwen38B:
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
    // In-process MLX models power Dictate Prompt and Chat. The HTTP local server stays
    // Dictate-Prompt-only until its chat tool-calling path is validated separately.
    case .localModel:
      return false
    case .localMLXQwen34BInstruct, .localMLXQwen38B:
      return true
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
    // Same $2/$6 and 500k context as 4.5; xAI ranks 4.6 as the current flagship → dominate 4.5.
    case .grok45: return .grok46
    // OpenAI: gpt-5.6-sol costs exactly what gpt-5.5 costs ($5/$30 per 1M), and gpt-5.6-terra
    // ($2.00/$12) now *undercuts* gpt-5.4 ($2.50/$15) — newer generation at the same price or
    // less, so the 5.5/5.4 pair is dominated.
    //
    // gpt-5.4-mini is NOT dominated, but the reason has changed and is worth stating precisely:
    // gpt-5.6-luna is now $0.20/$1.20 with a 1.05M context, i.e. cheaper on BOTH axes than
    // gpt-5.4-mini ($0.75/$4.50, 400k) and larger. The only axis 5.4-mini still wins is quality
    // tier — OpenAI places luna at the *nano* rung ("roughly corresponds to the nano model tier
    // used in earlier GPT-5 families") while 5.4-mini is the *mini* rung ("our strongest mini
    // model yet"). Different rungs of one price ladder are all frontier points, so both stay.
    // Prices re-verified 2026-08-02: https://developers.openai.com/api/docs/pricing
    case .openaiGPT55: return .openaiGPT56Sol
    case .openaiGPT5: return .openaiGPT56Terra
    // Anthropic: claude-opus-5 and claude-opus-4-8 are both $5/$25 per 1M with a 1M context and
    // 128k max output. Identical on every price and capacity axis, newer generation, later
    // knowledge cutoff (May 2026 vs Jan 2026) — and Anthropic itself files 4.8 under
    // "Legacy models". Dominated.
    // https://platform.claude.com/docs/en/about-claude/models/overview
    case .claudeOpus48: return .claudeOpus5
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
    case .gemini37Flash:
      // Live-verified 2026-08-23: gemini-3.7-flash rejects thinkingLevel MINIMAL
      // ("Thinking level MINIMAL is not supported for this model"). `low` is the floor.
      return ["thinkingLevel": "low"]
    case .gemini31FlashLite, .gemini35FlashLite, .gemini35Flash, .gemini36Flash:
      return ["thinkingLevel": "minimal"]
    // Image-generation models — no thinking knob.
    case .geminiImage, .geminiImagePro:
      return nil
    // Non-Gemini — ignored by other providers
    case .grok4, .grok4Reasoning, .grok43, .grok45, .grok46,
         .openaiGPT5, .openaiGPT5Mini, .openaiGPT55, .openaiGPT4oAudio,
         .openaiGPT56Sol, .openaiGPT56Terra, .openaiGPT56Luna,
         .claudeSonnet5, .claudeOpus5, .claudeOpus48, .claudeHaiku45, .claudeFable5,
         .customOpenAIEndpoint, .localModel, .localMLXQwen34BInstruct, .localMLXQwen38B:
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
    case .gemini37Flash:
      return .gemini37Flash
    case .geminiImage, .geminiImagePro:
      return nil // image-generation models; not transcription models
    case .grok4, .grok4Reasoning, .grok43, .grok45, .grok46:
      return nil // Grok models are text-only, no audio transcription
    case .openaiGPT5, .openaiGPT5Mini, .openaiGPT55, .openaiGPT4oAudio,
         .openaiGPT56Sol, .openaiGPT56Terra, .openaiGPT56Luna:
      return nil // OpenAI chat models don't piggy-back on the transcription endpoint here
    case .claudeSonnet5, .claudeOpus5, .claudeOpus48, .claudeHaiku45, .claudeFable5:
      return nil // Claude is chat-only here; no audio transcription endpoint
    case .customOpenAIEndpoint, .localModel, .localMLXQwen34BInstruct, .localMLXQwen38B:
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
         .localMLXQwen34BInstruct, .localMLXQwen38B,
         .claudeSonnet5, .claudeOpus5, .claudeOpus48, .claudeHaiku45, .claudeFable5:
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
    return allCases.filter { $0.supportsDictatePrompt }.filter(\.isSelectableUnderOfflineMode)
  }

  /// Whether this model may be offered for Dictate Prompt while Offline Mode is on: only the ones
  /// that talk to a server the user runs. The custom OpenAI-compatible endpoint qualifies
  /// conditionally — its URL is whatever the user typed, so the same host rule the network guard
  /// uses decides.
  ///
  /// Applied to Dictate Prompt only. Chat and Smart Improvement follow `supportsTextChat`.
  /// When Offline Mode is on, only on-device providers qualify.
  var isSelectableUnderOfflineMode: Bool {
    guard OfflineMode.isEnabled else { return true }
    switch provider {
    case .local, .localMLX:
      return true
    case .customOpenAI:
      guard let base = OpenAIChatPreferences.customEndpointBaseURL else { return false }
      return OfflineMode.allows(URL(string: base))
    case .gemini, .openai, .grok, .anthropic:
      return false
    }
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
    case "gpt-4o-audio-preview", "gpt-audio":
      // Two hops on the same case: OpenAI renamed `gpt-4o-audio-preview` → `gpt-audio`, then
      // deprecated `gpt-audio` (shutdown 2027-01-20) in favour of `gpt-audio-1.5`, which is what
      // the case's rawValue is now. Both old slugs forward here.
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

  /// True when the live Gemini API rejects `thinkingLevel: minimal` with HTTP 400.
  /// Verified for 3.1 Pro (2026-07) and 3.7 Flash (2026-08-23:
  /// "Thinking level MINIMAL is not supported for this model").
  var geminiRejectsMinimalThinking: Bool {
    switch self {
    case .gemini31Pro, .gemini37Flash: return true
    default: return false
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

  /// API endpoint for this model's provider. For Gemini the model id is in the path; for OpenAI it
  /// is passed in the request body. **xAI takes no model id at all** — `SpeechService`
  /// `synthesizeXAITTS` selects the voice with `voice_id` and omits `model`; see the note there.
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
    case .openai: return KeychainManager.shared.hasNonEmpty(.openAI)
    case .xai: return KeychainManager.shared.hasNonEmpty(.xai)
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
  // The raw value is both the sidebar label and the persisted selection; a stored "Permissions"
  // from an older build simply falls back to General once (`SettingsTab(rawValue:) ?? .general`).
  case permissions = "Privacy & Permissions"
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

  /// True when the configured base URL points at OpenRouter rather than a generic proxy.
  ///
  /// Load-bearing for credential sharing: OpenRouter is one account, so connecting it in Dictate
  /// must also authorize chat. Keying that off the URL keeps LiteLLM/OpenInference/self-hosted
  /// setups on their own key — they are different accounts and must not silently inherit one.
  static var isOpenRouterEndpoint: Bool {
    guard let host = customEndpointBaseURL.flatMap({ URL(string: $0) })?.host?.lowercased() else {
      return false
    }
    return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
  }

  /// Which stored credential the custom endpoint ends up using. Surfaced in Settings → Chat so the
  /// answer to "which key is this actually sending?" is visible instead of inferred.
  enum ResolvedCredential {
    case openRouterAccount
    case proxyKey
    case openAIKey

    var description: String {
      switch self {
      case .openRouterAccount: return "your connected OpenRouter account"
      case .proxyKey: return "the endpoint-specific key below"
      case .openAIKey: return "your OpenAI API key from Settings → General"
      }
    }
  }

  /// Decides which credential a custom endpoint should use.
  ///
  /// The ordering is not obvious and got this wrong once, with a symptom that read like a bug in
  /// the sign-in: `customOpenAIChatAPIKey` is **one** slot shared by every custom endpoint
  /// (OpenInference, LiteLLM, a self-hosted proxy, OpenRouter), but the base URL it belongs to can
  /// change underneath it. Someone who had configured OpenInference and then switched the URL to
  /// OpenRouter kept sending their `sk-oi-…` key to openrouter.ai and got "API key is invalid".
  ///
  /// So when the endpoint *is* OpenRouter, the OpenRouter credential wins: it is the specific one,
  /// and the shared slot is by definition holding a key for some *other* endpoint. The shared slot
  /// still applies as a fallback, for anyone who pasted an OpenRouter key there before this flow
  /// existed. Pure so the ordering is pinned by tests rather than by clicking through.
  static func resolveCredential(
    isOpenRouterEndpoint: Bool,
    proxyKey: String?,
    openRouterKey: String?,
    openAIKey: String?
  ) -> (key: String, source: ResolvedCredential)? {
    func usable(_ value: String?) -> String? {
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    if isOpenRouterEndpoint {
      if let key = usable(openRouterKey) { return (key, .openRouterAccount) }
      if let key = usable(proxyKey) { return (key, .proxyKey) }
      // Deliberately no OpenAI fallback here: an OpenAI key is never valid at openrouter.ai, and
      // returning one only turns a clear "not configured" into a confusing 401.
      return nil
    }

    if let key = usable(proxyKey) { return (key, .proxyKey) }
    if let key = usable(openAIKey) { return (key, .openAIKey) }
    return nil
  }

  /// The credential and where it came from, resolved against the Keychain.
  static var resolvedCredential: (key: String, source: ResolvedCredential)? {
    resolveCredential(
      isOpenRouterEndpoint: isOpenRouterEndpoint,
      proxyKey: KeychainManager.shared.get(.customOpenAIChatAPIKey),
      openRouterKey: KeychainManager.shared.get(.openRouter),
      openAIKey: KeychainManager.shared.get(.openAI))
  }

  static var resolvedAPIKey: String? { resolvedCredential?.key }

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

  /// Points chat at OpenRouter. Pairs with the Connect button in Settings → Dictate: once both are
  /// done there is no key to type anywhere.
  static func applyOpenRouterPreset() {
    UserDefaults.standard.set(SettingsDefaults.openRouterChatEndpointURL, forKey: UserDefaultsKeys.customOpenAIChatEndpointURL)
    UserDefaults.standard.set(SettingsDefaults.openRouterChatModelID, forKey: UserDefaultsKeys.customOpenAIChatModelID)
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

  /// Migrates the Slice 1 hidden `useInProcessMLX` flag to an explicit picker selection.
  static func migrateHiddenMLXFlagIfNeeded() {
    guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.useInProcessMLX) else { return }
    UserDefaults.standard.set(
      PromptModel.localMLXQwen34BInstruct.rawValue,
      forKey: UserDefaultsKeys.selectedPromptModel)
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.useInProcessMLX)
    DebugLogger.log(
      "LOCAL-LLM: Migrated hidden useInProcessMLX → \(PromptModel.localMLXQwen34BInstruct.rawValue)")
  }

  /// The model tag to request (e.g. an Ollama tag). Falls back to the default model id.
  static var modelID: String {
    let v = (UserDefaults.standard.string(forKey: UserDefaultsKeys.localPromptModelID) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? SettingsDefaults.localModelID : v
  }

  /// Full chat-completions URL for the configured endpoint.
  static var chatCompletionsURL: String { chatCompletionsURL(forBase: endpointBaseURL) }

  /// Normalizes a trailing slash and appends the path only when it isn't already there.
  ///
  /// Idempotent on purpose: Ollama's own docs print the full `/v1/chat/completions` URL, so users
  /// paste that into the endpoint field as often as the bare base. Appending unconditionally
  /// produced `.../chat/completions/chat/completions`, and that 404 was then reported to the user
  /// as "model not pulled" — sending them to `ollama pull` for a URL problem.
  static func chatCompletionsURL(forBase base: String) -> String {
    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
    if trimmed.hasSuffix("/chat/completions") { return trimmed }
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

/// Sampling temperature for transcription requests.
///
/// Until this existed the app sent no temperature at all, so every Gemini transcription ran at the
/// model default of `1.0` (confirmed via `GET /v1beta/models/{id}`: `temperature: 1, maxTemperature: 2`)
/// — full sampling for a task whose entire job is to reproduce what was said. That is the most likely
/// mechanical cause of the "invented word" reports, which until now were fought with prompt wording
/// and plausibility gates alone.
enum TranscriptionTemperature: String, CaseIterable {
  case verbatim = "0.0"
  case low = "0.2"
  case balanced = "0.5"
  case modelDefault = "1.0"

  var value: Double { Double(rawValue) ?? 0 }

  /// Plain values only. `1.0` used to be labelled "model default", which read as "this is the
  /// setting's default" right next to a control whose actual default is 0.0 — two meanings of the
  /// word in one picker. The distinction now lives in the explanatory text instead.
  var displayName: String {
    switch self {
    case .verbatim: return "0.0 · verbatim"
    case .low: return "0.2"
    case .balanced: return "0.5"
    case .modelDefault: return "1.0"
    }
  }
}

/// How much the model may think before transcribing (`generationConfig.thinkingConfig.thinkingLevel`).
///
/// Verified against the live API with real audio (2026-07): every Flash / Flash-Lite tier through
/// 3.6 accepts all four levels with audio input. Pro and 3.7 Flash accept everything except
/// `minimal` (HTTP 400, "Thinking level MINIMAL is not supported for this model") —
/// `geminiTranscriptionGenerationConfig` clamps those cases. Measured latency on a 1.2 s clip:
/// Flash-Lite is flat across levels (~1.2–1.5 s), Flash costs a few hundred ms, Pro goes from
/// 3 s to ~5 s at `high`.
enum TranscriptionThinkingEffort: String, CaseIterable {
  case minimal
  case low
  case medium
  case high

  /// Value sent as `thinkingLevel`.
  var geminiValue: String { rawValue }

  var displayName: String {
    switch self {
    case .minimal: return "Minimal"
    case .low: return "Low"
    case .medium: return "Medium"
    case .high: return "High"
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
  static let voiceFeedback: ShortcutDefinition? = nil
  static let meetingMarker: ShortcutDefinition? = nil
  static let addToGlossary: ShortcutDefinition? = nil

  // MARK: - Model & Prompt Settings
  // Chat defaults to 3.7 Flash — the current Gemini workhorse (GA 2026-08-13). Dictate Prompt
  // and meeting summary stay on 3.5 Flash-Lite because those run more often and Flash is
  // roughly 3× the output price of Flash-Lite.
  // https://ai.google.dev/gemini-api/docs/pricing
  //
  // Dictation is the exception: it defaults to *3.1* Flash-Lite, not 3.5, even though 3.5 is the
  // cheaper audio tier ($0.30/1M vs $0.50/1M, and audio input dominates that bill at ~32 tokens/s).
  // Measured 2026-08-03 against the live app container (36 glossary terms, 3 runs/case, 10
  // interleaved latency rounds): 3.1 reproduces glossary terms better (94% vs 85%), invents fewer
  // transcripts from silence (3/9 vs 7/9 leaks), and is faster at every audio length
  // (1.3 s: 1626 vs 2079 ms · 8.2 s: 1213 vs 2872 ms · 21.3 s: 1591 vs 4961 ms).
  // Caveat worth keeping in view: 3.1 is *not* leak-free, and every OpenAI/xAI transcription model
  // measured 0/9 — `discardingImplausibleTranscript` is still load-bearing here.
  // Numbers: plans/model-audits/2026-08-03-audit.md. Note 3.1 Flash-Lite shuts down 2027-05-07;
  // Google's named replacement (3.5 Flash-Lite) is the model it beats on every axis above, so the
  // migration waits for a better Flash-Lite rather than following the pointer.
  static let selectedTranscriptionModel = TranscriptionModel.gemini31FlashLite
  /// Verbatim by default: transcription should reproduce speech, not sample alternatives.
  static let transcriptionTemperature = TranscriptionTemperature.verbatim
  /// Unchanged from what the app has always sent — raising it costs latency on every dictation,
  /// so it stays the user's call.
  static let transcriptionThinkingEffort = TranscriptionThinkingEffort.minimal
  /// Cheapest audio-capable model on OpenRouter's own pricing list (2026-07).
  static let openRouterTranscriptionModelID = "google/gemini-3.5-flash-lite"
  static let selectedPromptModel = PromptModel.gemini35FlashLite
  static let selectedChatModel = PromptModel.gemini37Flash
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

  /// OFF by default: with auto-paste on, the text is already at the cursor, but some users
  /// still reach for ⌘V afterwards (pasting the same dictation into a second window). Putting
  /// the old clipboard back would break that, so restoring stays a deliberate choice.
  static let restoreClipboardAfterPaste = false

  // MARK: - Fn Key Dictation
  // OFF by default for the same reason as auto-paste: observing the Fn key needs global
  // event monitors, which only work with the Accessibility permission — a fresh install
  // must not require it (App Store Guideline 2.4.5).
  static let fnKeyDictation = false

  // MARK: - Screenshot Settings
  static let screenshotInPromptMode = true
  static let screenshotSaveEnabled = false

  // MARK: - Live Meeting Settings
  // 60s (rather than 30s) halves the number of chunk-transcription API calls per meeting and
  // halves how often the diarization prompt is re-sent, at the cost of a slightly less live
  // transcript. Users who want faster updates can lower it in Chat settings.
  static let liveMeetingChunkInterval = LiveMeetingChunkInterval.sixtySeconds
  static let liveMeetingSafeguardDuration = MeetingSafeguardDuration.ninetyMinutes
  static let selectedMeetingSummaryModel = PromptModel.gemini35FlashLite

  /// Smart Improvement runs at most once a week in the background, so its per-run cost barely
  /// registers — but it does analysis over a whole corpus, which Flash-Lite is weak at. 3.7 Flash
  /// is the current workhorse (GA 2026-08-13): more capable than 3.6 and cheaper through 2026
  /// ($0.75/$3.75 per 1M intro vs 3.6's $1.50/$7.50). https://ai.google.dev/gemini-api/docs/models
  static let selectedImprovementModel = PromptModel.gemini37Flash

  // MARK: - Local LLM (OpenAI-compatible server, e.g. Ollama / LM Studio)
  /// Base URL up to and including `/v1`. The provider appends `/chat/completions`. Ollama's
  /// default OpenAI-compatible endpoint is `http://localhost:11434/v1`.
  static let localEndpointURL = "http://localhost:11434/v1"
  /// Default model tag requested from the local server when the user hasn't set one.
  ///
  /// A non-reasoning instruct model on purpose: Dictate Prompt rewrites text, and a hybrid model
  /// like `qwen3` spends its first seconds thinking before the first token appears — the one thing
  /// the user is waiting on. Small enough to stay resident on an 8 GB Mac.
  static let localModelID = "llama3.2"
  /// Default model tag for the Custom endpoint chat model (OpenRouter-style slug).
  static let customOpenAIChatModelID = "openai/gpt-4o"
  /// [OpenInference](https://openinference.de/) preset — EU-hosted GLM 5.2, OpenAI-compatible.
  static let openInferenceEndpointURL = "https://openinference.de/api/v1"
  static let openInferenceModelID = "zai-org/GLM-5.2"
  /// OpenRouter preset — the same account the Dictate tab connects, reused for chat.
  static let openRouterChatEndpointURL = "https://openrouter.ai/api/v1"
  static let openRouterChatModelID = "openai/gpt-4o"

  // MARK: - UI State
  static let errorMessage = ""
  static let isLoading = false
  static let showAlert = false
}

// MARK: - Settings Data Models
/// `Equatable` so the settings round-trip test can assert that saving and re-loading the whole
/// struct is the identity — comparing field by field would silently skip a newly added setting.
struct SettingsData: Equatable {
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
  var voiceFeedback: ShortcutDefinition? = SettingsDefaults.voiceFeedback
  var meetingMarker: ShortcutDefinition? = SettingsDefaults.meetingMarker
  var addToGlossary: ShortcutDefinition? = SettingsDefaults.addToGlossary

  // MARK: - Transcription tuning
  var transcriptionTemperature: TranscriptionTemperature = SettingsDefaults.transcriptionTemperature
  var transcriptionThinkingEffort: TranscriptionThinkingEffort = SettingsDefaults.transcriptionThinkingEffort
  var openRouterTranscriptionModelID: String = SettingsDefaults.openRouterTranscriptionModelID

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
  var restoreClipboardAfterPaste: Bool = SettingsDefaults.restoreClipboardAfterPaste

  // MARK: - Fn Key Dictation
  var fnKeyDictation: Bool = SettingsDefaults.fnKeyDictation

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
  case voiceFeedbackShortcut
  case addToGlossaryShortcut
  case meetingMarkerShortcut
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

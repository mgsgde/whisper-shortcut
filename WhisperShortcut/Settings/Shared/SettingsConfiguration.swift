import Foundation

// MARK: - Chat Model Provider
enum ChatModelProvider: String, CaseIterable {
  case gemini
  case grok
  case openai
  /// Anthropic Claude via the Messages API. Chat-only for the first slice (no Dictate Prompt /
  /// TTS path — Claude has no native audio STT/TTS in this app).
  case anthropic
  /// User-configured OpenAI-compatible server (OpenInference, Azure OpenAI, Vertex AI, LiteLLM, self-hosted).
  /// Endpoint, model id, and optional API key are read from `OpenAIChatPreferences`. Selected explicitly in Chat.
  case customOpenAI
  /// OpenRouter on the user's OpenRouter account (the key from Settings → Accounts). The model
  /// slug is read from `OpenRouterChatPreferences`.
  case openRouter
  /// The user's ChatGPT Plus/Pro plan via "Sign in with ChatGPT" (Responses API, no API key).
  /// Direct-download build only; the model slug is read from `ChatGPTPlanPreferences`.
  case chatGPTPlan
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
    case .gemini: return .gemini38Flash
    case .grok:   return .grok47
    case .openai: return .openaiGPT6Sol
    case .anthropic: return .claudeSonnet55
    case .customOpenAI: return .customOpenAIEndpoint
    case .openRouter: return .openRouterChat
    case .chatGPTPlan: return .chatGPTPlanChat
    case .local:  return .localModel
    case .localMLX: return .localMLXQwen34BInstruct
    }
  }

  /// Section title in the chat's model picker. Brand names, not company names (GPT, not OpenAI).
  var pickerSectionTitle: String {
    switch self {
    case .gemini: return "Gemini"
    case .grok: return "Grok"
    case .openai: return "GPT"
    case .anthropic: return "Claude"
    case .customOpenAI: return String(localized: "Own server")
    case .openRouter: return "OpenRouter"
    case .chatGPTPlan: return String(localized: "ChatGPT plan")
    case .local: return String(localized: "Local server")
    case .localMLX: return String(localized: "On this Mac")
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
    case .openRouter: return "openrouter"
    case .chatGPTPlan: return "chatgpt"
    case .local:  return "local"
    case .localMLX: return "mlx"
    }
  }
}

// MARK: - Unified Prompt Model Enum (for Dictate Prompt) - Gemini multimodal models + Grok
// Current Gemini model IDs: https://ai.google.dev/gemini-api/docs/models (Gemini API, not Vertex AI).
// GA: gemini-3.1-flash-lite, gemini-3.5-flash-lite, gemini-3.8-flash (shipped 2026-09-02),
// gemini-4-argon (stable flagship reasoning; paid tier only;
// https://ai.google.dev/gemini-api/docs/models/gemini-4-argon).
// Preview: gemini-3.1-pro-preview.
// Removed and forwarded via migrateLegacyPromptRawValue: gemini-3-pro-preview (shut down
// 2026-03-09) → gemini-3.1-pro-preview; the Gemini 2.5 family (gemini-2.5-flash / -flash-lite /
// -pro, shutdown 2026-10-16) → gemini-3.8-flash / gemini-3.1-flash-lite / gemini-3.1-pro-preview;
// gemini-3-flash-preview (deprecated-pending) → gemini-3.8-flash; offline local-mlx-qwen3-8b
// (removed 2026-09-30) → local-mlx-qwen3-4b-instruct-2507; gemini-3.6-flash (removed 2026-10-19,
// dominated by 3.7 on price, tier and speed) and gemini-3.5-flash (removed 2026-10-19, dominated by 3.7
// on price and tier) → gemini-3.8-flash; gemini-3.7-flash (removed 2026-10-21 because Google
// routes every request to gemini-3.8-flash, same price) → gemini-3.8-flash.
// Superseded chat models removed 2026-10-19 (each was Pareto-dominated: a newer same-provider
// sibling beats it on price/context/tier) and forwarded to their replacement — see the arms in
// migrateLegacyPromptRawValue for the reasoning and prices: grok-4.20-0309-* → grok-4.3,
// grok-4.5 / grok-4.6 → grok-4.7, gpt-5.4 / 5.5 / 5.6-sol / 5.6-terra → gpt-6-sol,
// gpt-5.6-luna → gpt-6-luna, claude-opus-4-8 / claude-opus-5 / claude-fable-5 → claude-opus-5-5,
// claude-sonnet-5 → claude-sonnet-5-5.
// Grok model IDs: https://docs.x.ai/docs/models (grok-4-1-fast-non-reasoning was retired 2026-05-15
// and silently redirects to grok-4.3; the case was removed — see migrateLegacyPromptRawValue).
// OpenAI model IDs: https://platform.openai.com/docs/models.
enum PromptModel: String, CaseIterable {
  // Gemini Models (multimodal, direct audio input)
  case gemini4Argon = "gemini-4-argon"
  case gemini31Pro = "gemini-3.1-pro-preview"
  case gemini31FlashLite = "gemini-3.1-flash-lite"
  case gemini35FlashLite = "gemini-3.5-flash-lite"
  case gemini38Flash = "gemini-3.8-flash"

  // Gemini native image generation/editing ("Nano Banana"). Prompt (+ optional input image) →
  // image out, via a dedicated non-streaming `:generateContent` call with `responseModalities`
  // IMAGE (see `GeminiAPIClient.generateImageContent` / `GeminiChatProvider`). Not a text-chat,
  // tools, grounding, or thinking model — selecting it turns the chat into an image generator.
  // 2026-10-12: gemini-nano-banana-2.1 replaced gemini-3.1-flash-image — GA ("New Stable"),
  // better quality/typography, cheaper per image (~$0.034 vs ~$0.067 at 1K, $0.050 vs $0.101 at
  // 2K; image output $30 vs $60 per 1M). Input price is higher ($1.50 vs $0.50 per 1M) but
  // negligible for prompt-sized inputs. https://ai.google.dev/gemini-api/docs/pricing
  case geminiImage = "gemini-nano-banana-2.1"
  // Premium tier of the same capability: studio quality, up to 4K, better text rendering.
  // No free tier (roughly $0.13–0.24 per image) — the user picks it deliberately for quality.
  case geminiImagePro = "gemini-3-pro-image"

  // Grok Models (xAI, OpenAI-compatible API, text + search for chat)
  case grok43 = "grok-4.3"
  /// xAI's current flagship: same price/context as the removed 4.5/4.6 ($2.00/$6.00, 500k),
  /// newer and preferred per https://docs.x.ai/docs/models (verified 2026-09-29). Does NOT supersede
  /// grok-4.3 — that stays for the cheaper $1.25/$2.50 / 1M-context rung.
  case grok47 = "grok-4.7"

  // OpenAI Models (chat + Dictate Prompt via Chat Completions API)
  // Persisted `gpt-5-mini` forwards to gpt-5.4-mini; `gpt-5` / `gpt-5.4` and the rest of the
  // removed 5.x flagships forward to GPT-6 Sol (see migrateLegacyPromptRawValue).
  //
  // gpt-5.4-mini is NOT dominated by GPT-6 Luna on tier positioning: gpt-5.6-luna (removed) was
  // $0.20/$1.20 with a 1.05M context, i.e. cheaper on BOTH axes than gpt-5.4-mini ($0.75/$4.50,
  // 400k) and larger. The only axis 5.4-mini still wins is quality tier — OpenAI places luna at
  // the *nano* rung ("roughly corresponds to the nano model tier used in earlier GPT-5
  // families") while 5.4-mini is the *mini* rung ("our strongest mini model yet"). Different
  // rungs of one price ladder are all frontier points, so it stays.
  // Prices re-verified 2026-08-02: https://developers.openai.com/api/docs/pricing
  case openaiGPT5Mini = "gpt-5.4-mini"
  // GPT-6 family (GA, 1.05M context), prices verified 2026-09-29 at
  // https://developers.openai.com/api/docs/pricing: sol $2/$10, luna $0.10/$0.50 per 1M. Both
  // undercut their 5.6 counterparts at a newer generation, so the whole 5.x family was removed.
  // gpt-6-astra ($10/$50, "the hardest end-to-end work") is deliberately NOT
  // offered: chat here is used for research and questions, not coding, and Astra's price buys
  // nothing for that — pick models by research price-performance, not by top capability.
  // gpt-6.1-sol (same $2/$10) is NOT a replacement: it rejects `reasoning_effort: "none"`, which
  // `/think minimal` sends, and is slower (median ~3.1 s vs ~1.9 s, re-probed 2026-10-12; see
  // plans/model-audits/2026-10-03-audit.md). Revisit when OpenAI deprecates gpt-6-sol — the
  // migration must then map minimal → low.
  case openaiGPT6Sol = "gpt-6-sol"
  case openaiGPT6Luna = "gpt-6-luna"
  /// Audio-input chat model. Accepts inline `input_audio` content parts, which makes it the
  /// counterpart to Gemini for Dictate Prompt (the model "hears" the audio directly).
  ///
  /// Slug history, both handled by `migrateLegacyPromptRawValue`:
  /// `gpt-4o-audio-preview` → `gpt-audio` (rename) → `gpt-audio-1.5` (deprecation: OpenAI retires
  /// `gpt-audio` on 2027-01-20 and names 1.5 as the replacement, at identical pricing —
  /// $32/$64 per 1M audio, $2.50/$10 text).
  /// Reference: https://developers.openai.com/api/docs/deprecations
  case openaiGPT4oAudio = "gpt-audio-1.5"

  // OpenAI-compatible server (OpenInference, Azure, Vertex, LiteLLM, self-hosted). The rawValue is a stable
  // sentinel — the actual model tag sent to the server is read from `OpenAIChatPreferences.modelID`.
  case customOpenAIEndpoint = "custom-openai-endpoint"
  // Stable sentinel — the slug sent to OpenRouter is read from `OpenRouterChatPreferences.modelID`.
  case openRouterChat = "openrouter-chat"
  // Stable sentinel — the slug sent to the Responses API is read from `ChatGPTPlanPreferences.modelID`.
  // Direct-download build only (see `ChatGPTPlanPreferences.isAvailableInThisBuild`).
  case chatGPTPlanChat = "chatgpt-plan-chat"

  // Anthropic Claude (Messages API). Chat-only — no Dictate Prompt / TTS wiring.
  // Model IDs: https://platform.claude.com/docs/en/about-claude/models/overview (verified 2026-07).
  /// Replaced Haiku 4.5 (`claude-haiku-4-5-20251001`) on 2026-10-12: $0.10/$0.50 per 1M
  /// (≤100k-token prompts; $0.50/$2.50 above), 1M context, 128k output, adaptive thinking
  /// (default effort medium), Jun 2026 cutoff — strictly dominates Haiku 4.5's $1/$5 at a
  /// smaller context. Verified 2026-10-12: https://platform.claude.com/docs/en/about-claude/models/overview
  case claudeHaiku55 = "claude-haiku-5-5"
  /// 5.5 generation (prices verified 2026-09-29, https://platform.claude.com/docs/en/about-claude/pricing):
  /// Sonnet 5.5 $2/$10 = the removed Sonnet 5's price, Opus 5.5 $4/$20 undercuts the removed
  /// Opus 5's $5/$25; same 1M context and 128k output. Both think on every request and reject
  /// forced `tool_choice` — see `AnthropicChatProvider` for the thinking round-trip and
  /// structured-output path.
  case claudeSonnet55 = "claude-sonnet-5-5"
  case claudeOpus55 = "claude-opus-5-5"

  // Local model served by an OpenAI-compatible server on the user's machine (Ollama / LM Studio).
  // The rawValue is a stable sentinel — the *actual* model tag sent to the server is configurable
  // and read from `LocalLLMPreferences.modelID`, so one enum case covers whatever the user pulled.
  case localModel = "local-llm"

  // In-process MLX models (no server). One enum case per catalogue entry; weights download like
  // offline Whisper and route through `MLXChatProvider`.
  case localMLXQwen34BInstruct = "local-mlx-qwen3-4b-instruct-2507"
  case localMLXQwen359B = "local-mlx-qwen3.5-9b"

  /// Maps a catalogue entry to its picker / settings enum case.
  static func forLocalLLMModel(_ type: LocalLLMModelType) -> PromptModel {
    switch type {
    case .qwen34BInstruct2507: return .localMLXQwen34BInstruct
    case .qwen359B: return .localMLXQwen359B
    }
  }

  /// Inverse of `forLocalLLMModel`; nil for cloud / HTTP-local models.
  var localMLXModelType: LocalLLMModelType? {
    switch self {
    case .localMLXQwen34BInstruct: return .qwen34BInstruct2507
    case .localMLXQwen359B: return .qwen359B
    default: return nil
    }
  }

  /// Every in-process MLX model offered on this Mac (Chat; Dictate Prompt narrows it via `supportsDictatePrompt`).
  static var localMLXModels: [PromptModel] {
    LocalLLMModelType.offerable.map(\.promptModel)
  }

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
    case .geminiImage:
      return "Gemini Image (Nano Banana 2.1)"
    case .geminiImagePro:
      return "Gemini Image Pro (Nano Banana Pro)"
    case .grok43:
      return "Grok 4.3"
    case .grok47:
      return "Grok 4.7"
    case .openaiGPT5Mini:
      return "GPT-5.4 Mini"
    case .openaiGPT6Sol:
      return "GPT-6 Sol"
    case .openaiGPT6Luna:
      return "GPT-6 Luna"
    case .openaiGPT4oAudio:
      return "GPT Audio"
    case .claudeHaiku55:
      return "Claude Haiku 5.5"
    case .claudeSonnet55:
      return "Claude Sonnet 5.5"
    case .claudeOpus55:
      return "Claude Opus 5.5"
    case .customOpenAIEndpoint:
      // Short on purpose: this is a chip next to the composer's slash-command row, and a long
      // name squeezed those buttons until they hyphenated mid-word ("/at-tach").
      return String(localized: "Own server")
    case .openRouterChat:
      return OpenRouterChatPreferences.shortModelName
    case .chatGPTPlanChat:
      return ChatGPTPlanPreferences.displayName
    case .localModel:
      return String(localized: "Local Server (Ollama / LM Studio)")
    case .localMLXQwen34BInstruct:
      return String(localized: "Qwen3 4B Instruct (Offline)")
    case .localMLXQwen359B:
      return String(localized: "Qwen3.5 9B (Offline)")
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
    case .gemini4Argon:      return "gemini4argon"
    case .gemini31Pro:       return "gemini31pro"
    case .gemini31FlashLite: return "gemini31flashlite"
    case .gemini35FlashLite: return "gemini35flashlite"
    case .gemini38Flash:     return "gemini38flash"
    case .geminiImage:       return "geminiimage"
    case .geminiImagePro:    return "geminiimagepro"
    case .grok43:            return "grok43"
    case .grok47:            return "grok47"
    case .openaiGPT5Mini:    return "gpt54mini"
    case .openaiGPT6Sol:     return "gpt6sol"
    case .openaiGPT6Luna:    return "gpt6luna"
    case .openaiGPT4oAudio:  return "gptaudio" // audio-only; excluded from chatModels, never surfaced
    case .claudeHaiku55:     return "claudehaiku55"
    case .claudeSonnet55:    return "claudesonnet55"
    case .claudeOpus55:      return "claudeopus55"
    case .customOpenAIEndpoint: return "custom"
    case .openRouterChat:    return "openrouter"
    case .chatGPTPlanChat:   return "chatgpt"
    case .localModel:        return "local"
    case .localMLXQwen34BInstruct: return "mlx4b"
    case .localMLXQwen359B: return "mlx9b"
    }
  }

  var description: String {
    switch self {
    case .gemini4Argon:
      return String(localized: "Google's Gemini 4 Argon • Flagship reasoning for hard research questions • Paid (no free tier) • Multimodal")
    case .gemini31Pro:
      return String(localized: "Google's Gemini 3.1 Pro model • Complex reasoning and agentic workflows • Multimodal")
    case .gemini31FlashLite:
      return String(localized: "Google's Gemini 3.1 Flash-Lite • Fastest, most cost-efficient 3-series • Multimodal")
    case .gemini35FlashLite:
      return String(localized: "Google's Gemini 3.5 Flash-Lite • Fastest, most cost-effective 3.5 model • High throughput • Multimodal")
    case .gemini38Flash:
      return String(localized: "Google's Gemini 3.8 Flash • Most intelligent Flash • Most capable workhorse for coding and agents • Multimodal")
    case .geminiImage:
      return String(localized: "Google's Gemini Image (Nano Banana 2.1) • Generates and edits images from a prompt + optional input image • Free tier • Requires Gemini API key")
    case .geminiImagePro:
      return String(localized: "Google's Gemini Image Pro (Nano Banana Pro) • Studio-quality image generation/editing up to 4K • Best text rendering • Paid (no free tier) • Requires Gemini API key")
    case .grok47:
      return String(localized: "xAI's Grok 4.7 • Flagship • Most intelligent and fastest model • 500k context • Needs an xAI API key")
    case .grok43:
      return String(localized: "xAI's Grok 4.3 • Cheaper 1M-context option • Leading non-hallucination + agentic tool use • Web + X search • Requires xAI API key")
    case .openaiGPT5Mini:
      return String(localized: "OpenAI's GPT-5.4 Mini • Cheaper, faster GPT-5.4 variant • Text + images • Requires OpenAI API key")
    case .openaiGPT6Sol:
      return String(localized: "OpenAI's GPT-6 Sol • Strong reasoning for research and demanding questions • Web search • 1M context • Needs an OpenAI API key")
    case .openaiGPT6Luna:
      return String(localized: "OpenAI's GPT-6 Luna • Cheapest GPT-6 • Fast everyday questions • Web search • 1M context • Needs an OpenAI API key")
    case .openaiGPT4oAudio:
      return String(localized: "OpenAI's GPT Audio • Accepts inline audio for voice-driven prompts • Requires OpenAI API key")
    case .claudeSonnet55:
      return String(localized: "Anthropic's Claude Sonnet 5.5 • Best speed/intelligence balance • Text + images • 1M context • Needs an Anthropic API key")
    case .claudeOpus55:
      return String(localized: "Anthropic's Claude Opus 5.5 • Deeper reasoning for hard questions • Text + images • 1M context • Needs an Anthropic API key")
    case .claudeHaiku55:
      return String(localized: "Anthropic's Claude Haiku 5.5 • Fastest, cheapest Claude • Text + images • 1M context • Requires Anthropic API key")
    case .customOpenAIEndpoint:
      return String(localized: "Your own OpenAI-compatible server (LiteLLM, Azure OpenAI, Vertex AI, OpenInference, self-hosted) • Set up once below, shared by Dictate, Dictate Prompt and Chat • No web search")
    case .openRouterChat:
      return String(localized: "Any chat model OpenRouter routes to, on your OpenRouter account • Pick the model in Settings → Chat • Connect the account in Settings → Accounts • No web search")
    case .chatGPTPlanChat:
      return String(localized: "Chat on your ChatGPT Plus or Pro plan, no API key • Sign in under Settings → Accounts • Text + images • No web search or tools yet")
    case .localModel:
      return String(localized: "Runs fully on your Mac via a local OpenAI-compatible server (Ollama / LM Studio) • No API key, no cloud • Audio is transcribed locally first, then rewritten by the local model • Configure endpoint + model in Dictate Prompt settings")
    case .localMLXQwen34BInstruct:
      return String(localized: "mlx-community/Qwen3-4B-Instruct-2507-4bit • In-process MLX, no server to install • ~2.3 GB • Offline")
    case .localMLXQwen359B:
      return String(localized: "mlx-community/Qwen3.5-9B-MLX-4bit • In-process MLX, no server to install • ~5.6 GB • Offline • Chat only, needs 16 GB RAM")
    }
  }
  
  var costLevel: CostLevel {
    switch self {
    case .gemini31FlashLite, .gemini35FlashLite,
         .gemini38Flash, .geminiImage, .customOpenAIEndpoint, .openRouterChat, .chatGPTPlanChat, .localModel, .claudeHaiku55:
      return .low
    case .localMLXQwen34BInstruct, .localMLXQwen359B:
      return .freeOffline
    case .gemini31Pro, .geminiImagePro:
      return .medium
    case .grok43, .grok47:
      return .medium
    case .openaiGPT4oAudio, .openaiGPT6Sol, .claudeSonnet55:
      return .medium
    case .openaiGPT5Mini, .openaiGPT6Luna:
      return .low
    case .gemini4Argon, .claudeOpus55:
      return .high
    }
  }

  var provider: ChatModelProvider {
    // Deliberately exhaustive, with no `default:` — a `default: return .gemini` used to mean a
    // newly added non-Gemini case silently claimed the Gemini credential and endpoint. Let the
    // compiler force the decision instead.
    switch self {
    case .gemini4Argon, .gemini31Pro, .gemini31FlashLite, .gemini35FlashLite,
         .gemini38Flash, .geminiImage, .geminiImagePro:
      return .gemini
    case .grok43, .grok47:
      return .grok
    case .openaiGPT5Mini, .openaiGPT4oAudio, .openaiGPT6Sol, .openaiGPT6Luna:
      return .openai
    case .claudeHaiku55, .claudeSonnet55, .claudeOpus55:
      return .anthropic
    case .customOpenAIEndpoint:
      return .customOpenAI
    case .openRouterChat:
      return .openRouter
    case .chatGPTPlanChat:
      return .chatGPTPlan
    case .localModel:
      return .local
    case .localMLXQwen34BInstruct, .localMLXQwen359B:
      return .localMLX
    }
  }

  /// Whether this model can power Dictate Prompt. Three paths qualify:
  ///   - models that accept audio directly (`supportsDirectAudioInput`),
  ///   - local models, which can't hear audio but run a transcribe-first flow (offline STT →
  ///     local text rewrite), and
  ///   - the custom OpenAI-compatible endpoint, which uses that same transcribe-first flow
  ///     against the shared server. Drives `dictatePromptCapableModels` and the runtime guard in
  ///     `SpeechService.performPrompt`.
  var supportsDictatePrompt: Bool {
    if provider == .localMLX { return localMLXModelType?.supportsDictatePrompt == true }
    return supportsDirectAudioInput || provider == .local || provider == .customOpenAI
  }

  /// Whether this model's Dictate Prompt selection is read from a screenshot rather than the
  /// clipboard.
  ///
  /// Build-wide in principle (`AppConstants.dictatePromptUsesScreenshotSelection`), but never for
  /// a local model or the custom endpoint: those are text-only, so a screenshot reaches them as
  /// nothing at all. That combination used to send the "edit the highlighted region" system prompt
  /// with no image *and* no clipboard — an instruction to read something the model was never given,
  /// which is why the App Store build's local Dictate Prompt answered with the instruction tidied up.
  ///
  /// Reading the pasteboard needs no Accessibility permission; only the synthetic ⌘C does. So the
  /// local path uses the clipboard in every build, and in the App Store build the user copies for
  /// themselves.
  var dictatePromptUsesScreenshotSelection: Bool {
    AppConstants.dictatePromptUsesScreenshotSelection
      && provider != .local && provider != .localMLX && provider != .customOpenAI
  }

  /// Permission Dictate Prompt needs before it can read a selection, or nil when the runtime
  /// reads the clipboard the user already copied.
  ///
  /// The onboarding Done step used the build-wide `AppConstants.dictatePromptUsesScreenshotSelection`
  /// flag, so a local model — which never screenshots, and in the App Store build never synthesizes
  /// ⌘C — still asked for Screen Recording or Accessibility. This matches
  /// `MenuBarController.prepareDictatePromptSelection`: screenshot → Screen Recording; App Store
  /// local → none; direct build → Accessibility for the synthetic ⌘C.
  var dictatePromptSelectionPermission: PermissionKind? {
    if dictatePromptUsesScreenshotSelection { return .screenRecording }
    if AppConstants.dictatePromptUsesScreenshotSelection { return nil }
    return .accessibility
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

  /// Whether the user has what this model's provider needs. Used to gate chat, meeting
  /// summary, Read Aloud smart rewrite, and Smart Improvement.
  ///
  /// Forwards to `ChatModelProvider.hasCredential` — the one switch that trims. The copy here
  /// called `hasNonEmpty`, so a whitespace-only key looked configured in the picker and missing
  /// in `ProviderCredentials.verifyConfigured`.
  var hasRequiredCredential: Bool {
    provider.hasCredential
  }

  /// Stricter credential check for Dictate Prompt: OpenAI audio models still hit api.openai.com
  /// directly, so a proxy-only key is not enough. Same trim as `hasRequiredCredential`.
  var hasRequiredCredentialForDictatePrompt: Bool {
    switch provider {
    case .openai: return ProviderCredentials.hasKey(.openAI)
    case .customOpenAI: return OpenAIChatPreferences.isConfigured
    default: return hasRequiredCredential
    }
  }

  /// Actionable message when this model can't run Dictate Prompt for lack of a credential.
  var apiKeyRequiredMessageForDictatePrompt: String {
    switch provider {
    case .gemini: return String(localized: "Add your Gemini API key in Settings → Accounts to use Dictate Prompt.")
    case .openai: return String(localized: "Add your OpenAI API key in Settings → Accounts to use Dictate Prompt.")
    case .customOpenAI: return String(localized: "Add your own server's base URL and key in Settings → Dictate Prompt.")
    case .openRouter: return String(localized: "OpenRouter chat models are for Chat only. Pick a Gemini, OpenAI GPT-Audio, or local model for Dictate Prompt.")
    case .chatGPTPlan: return String(localized: "ChatGPT plan models are for Chat only for now. Pick a Gemini, OpenAI GPT-Audio, or local model for Dictate Prompt.")
    case .grok: return String(localized: "Grok can't process audio directly. Pick a Gemini or OpenAI GPT-Audio model in Dictate Prompt settings.")
    case .anthropic: return String(localized: "Claude can't process audio directly. Pick a Gemini, OpenAI GPT-Audio, or local model for Dictate Prompt.")
    case .local: return String(localized: "Set your local server endpoint (Ollama / LM Studio) in Dictate Prompt settings, and make sure it is running.")
    case .localMLX: return String(localized: "Select an offline MLX model above. It downloads automatically when you pick it or dictate with it.")
    }
  }

  /// True for models whose chat endpoint accepts inline image content parts.
  /// OpenAI's gpt-4o-audio-preview is audio-only and rejects `image_url` parts with HTTP 400.
  var supportsImageInput: Bool {
    switch self {
    case .openaiGPT4oAudio:
      return false
    // Local text models in Phase 1 are text-only; no image parts are sent to the local server.
    case .localModel, .customOpenAIEndpoint, .openRouterChat, .localMLXQwen34BInstruct, .localMLXQwen359B:
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
    case .localMLXQwen34BInstruct, .localMLXQwen359B:
      return true
    // Not offered at all in the App Store build (OpenAI approval pending).
    case .chatGPTPlanChat:
      return ChatGPTPlanPreferences.isAvailableInThisBuild
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
  /// not enough — Gemini 3.1 Flash-Lite has a 40% cheaper output rate than 3.5 Flash-Lite, so
  /// both stay on the frontier and stay selectable.
  /// Verified against the published price tables (see the audit notes in `SettingsDefaults`).
  var chatReplacement: PromptModel? {
    // No model is currently superseded: dominated models are removed outright and their saved
    // selections forwarded in `migrateLegacyPromptRawValue`.
    nil
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
    // Gemini 3.x / 4 — thinkingLevel
    case .gemini4Argon:
      // Argon documents thinkingLevel low/medium/high only (no minimal).
      return ["thinkingLevel": "high"]
    case .gemini31Pro:
      return ["thinkingLevel": "high"]
    case .gemini38Flash:
      // Same floor as 3.7, live-verified 2026-09-06: `thinkingLevel: minimal` returns HTTP 400
      // ("Thinking level MINIMAL is not supported for this model"), `low` returns 200. Matches
      // the documented LOW/MEDIUM/HIGH set.
      return ["thinkingLevel": "low"]
    case .gemini31FlashLite, .gemini35FlashLite:
      return ["thinkingLevel": "minimal"]
    // Image-generation models — no thinking knob.
    case .geminiImage, .geminiImagePro:
      return nil
    // Non-Gemini — ignored by other providers
    case .grok43, .grok47,
         .openaiGPT5Mini, .openaiGPT4oAudio, .openaiGPT6Sol, .openaiGPT6Luna,
         .claudeHaiku55, .claudeSonnet55, .claudeOpus55,
         .customOpenAIEndpoint, .openRouterChat, .chatGPTPlanChat, .localModel, .localMLXQwen34BInstruct, .localMLXQwen359B:
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
    case .gemini4Argon:
      return .gemini4Argon
    case .gemini31Pro:
      return .gemini31Pro
    case .gemini31FlashLite:
      return .gemini31FlashLite
    case .gemini35FlashLite:
      return .gemini35FlashLite
    case .gemini38Flash:
      return .gemini38Flash
    case .geminiImage, .geminiImagePro:
      return nil // image-generation models; not transcription models
    case .grok43, .grok47:
      return nil // Grok models are text-only, no audio transcription
    case .openaiGPT5Mini, .openaiGPT4oAudio, .openaiGPT6Sol, .openaiGPT6Luna:
      return nil // OpenAI chat models don't piggy-back on the transcription endpoint here
    case .claudeHaiku55, .claudeSonnet55, .claudeOpus55:
      return nil // Claude is chat-only here; no audio transcription endpoint
    case .customOpenAIEndpoint, .openRouterChat, .chatGPTPlanChat, .localModel, .localMLXQwen34BInstruct, .localMLXQwen359B:
      return nil // proxy/local LLM is text-only; STT runs through the separate transcription pipeline
    }
  }

  /// Whether this model supports grounding/search.
  /// - Gemini: `google_search` + `url_context` tools on the standard endpoint.
  /// - Grok: `web_search` tool via the Responses API.
  /// - OpenAI text chat models: `web_search` tool via the Responses API (gpt-5.4, gpt-5.4-mini).
  /// - Claude: Anthropic's server-side `web_search` tool (`AnthropicChatProvider.webSearchTool`).
  /// - `gpt-4o-audio-preview` is audio-only and routes through Chat Completions only, so
  ///   the Responses API path doesn't apply.
  var supportsGrounding: Bool {
    switch self {
    case .openaiGPT4oAudio, .geminiImage, .geminiImagePro, .customOpenAIEndpoint, .openRouterChat, .chatGPTPlanChat, .localModel,
         .localMLXQwen34BInstruct, .localMLXQwen359B:
      // Audio-only, image-generation, proxy, and local models have no web-search path in this app.
      return false
    default:
      return true
    }
  }

  /// All models available for the chat window (all providers). Excludes audio-only
  /// models such as `openaiGPT4oAudio`, which the OpenAI API rejects on text-only requests,
  /// models superseded by a newer sibling (see `chatReplacement`), models this Mac cannot
  /// run (see `isOfferableOnThisMac`), and cloud models while Offline Mode is on.
  static var chatModels: [PromptModel] {
    return allCases.filter { $0.isSelectableInChat }.filter(\.isOfferableOnThisMac)
      .filter(\.isSelectableUnderOfflineMode)
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
    return allCases.filter { $0.supportsDictatePrompt }.filter(\.isOfferableOnThisMac)
      .filter(\.isSelectableUnderOfflineMode)
  }

  /// False for an MLX catalogue entry this Mac cannot run (Intel, or 8B on a machine with
  /// too little RAM). Cloud / HTTP-local models are always offerable at this layer.
  var isOfferableOnThisMac: Bool {
    localMLXModelType?.isOfferable ?? true
  }

  /// Whether this model may be offered while Offline Mode is on: only the ones that talk to a
  /// server the user runs. The custom OpenAI-compatible endpoint qualifies conditionally — its
  /// URL is whatever the user typed, so the same host rule the network guard uses decides.
  ///
  /// Applied to Chat and Dictate Prompt pickers alike. When Offline Mode is on, only on-device
  /// providers qualify.
  var isSelectableUnderOfflineMode: Bool {
    guard OfflineMode.isEnabled else { return true }
    switch provider {
    case .local, .localMLX:
      return true
    case .customOpenAI:
      guard let base = OpenAIChatPreferences.customEndpointBaseURL else { return false }
      return OfflineMode.allows(URL(string: base))
    case .gemini, .openai, .grok, .anthropic, .openRouter, .chatGPTPlan:
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
      // gpt-5 → gpt-5.4 (2026-03) → removed 2026-10-19; go straight to GPT-6 Sol.
      return Self.openaiGPT6Sol.rawValue
    case "gpt-5-mini":
      // Superseded by gpt-5.4-mini; forward to the current mini case.
      return Self.openaiGPT5Mini.rawValue
    case "gemini-3-pro-preview":
      // Shut down by Google 2026-03-09 (now returns 404); forward to the current Pro preview.
      return Self.gemini31Pro.rawValue
    case "gemini-2.5-flash":
      // Deprecated, shutdown 2026-10-16. 3.7 was removed 2026-10-21; forward to 3.8.
      return Self.gemini38Flash.rawValue
    case "gemini-2.5-flash-lite":
      // Deprecated, shutdown 2026-10-16; replacement is the current Flash-Lite.
      return Self.gemini31FlashLite.rawValue
    case "gemini-2.5-pro":
      // Deprecated, shutdown 2026-10-16; replacement is the current Pro preview.
      return Self.gemini31Pro.rawValue
    // Removed 2026-10-19 (Pareto-dominated chat models; they used to be hidden via chatReplacement).
    // xAI: both 4.20 variants cost exactly what grok-4.3 costs ($1.25/$2.50 per 1M, same 1M
    // context) while xAI's own docs rank 4.3 above them — dominated on every axis.
    // https://docs.x.ai/docs/models
    case "grok-4.20-0309-non-reasoning", "grok-4.20-0309-reasoning":
      return Self.grok43.rawValue
    // Same $2/$6 and 500k context as 4.7; xAI ranks 4.7 as the current flagship → both
    // dominated. Prices verified 2026-09-29: https://docs.x.ai/docs/models
    case "grok-4.5", "grok-4.6":
      return Self.grok47.rawValue
    // OpenAI: gpt-5.6-sol costs exactly what gpt-5.5 costs ($5/$30 per 1M), and gpt-5.6-terra
    // ($2.00/$12) undercut gpt-5.4 ($2.50/$15) — newer generation at the same price or less.
    // 2026-09-29: the GPT-6 family undercuts all of 5.6 at a newer generation — luna $0.10/$0.50
    // vs $0.20/$1.20 (same rung), sol $2/$10 vs terra $2/$12. 5.6 Sol ($4/$20) was removed by
    // owner decision: no published quality comparison against 6 Sol, but at half the price 6 Sol
    // is the better research model, and research — not coding — is what chat is used for.
    // Prices: https://developers.openai.com/api/docs/pricing
    case "gpt-5.4", "gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra":
      return Self.openaiGPT6Sol.rawValue
    case "gpt-5.6-luna":
      return Self.openaiGPT6Luna.rawValue
    // Anthropic: claude-opus-5 and claude-opus-4-8 were both $5/$25 per 1M with a 1M context and
    // 128k max output — identical on every price and capacity axis, with a later knowledge
    // cutoff for opus-5 (May 2026 vs Jan 2026); Anthropic itself filed 4.8 under "Legacy models".
    // https://platform.claude.com/docs/en/about-claude/models/overview
    // 2026-09-29: Opus 5.5 ($4/$20) undercuts Opus 5 / 4.8 ($5/$25) at the same 1M/128k, newer
    // generation; Sonnet 5.5 costs exactly what Sonnet 5 cost. Fable 5 ($10/$50) was dropped by
    // owner decision — chat is for research, where Fable's agentic depth isn't worth 2.5× Opus
    // (Fable 5.1 is deliberately not added).
    case "claude-opus-4-8", "claude-opus-5", "claude-fable-5":
      return Self.claudeOpus55.rawValue
    case "claude-sonnet-5":
      return Self.claudeSonnet55.rawValue
    case "gemini-3.6-flash":
      // Removed 2026-10-19: dominated by 3.7 on price, tier and speed. 3.7 itself was removed
      // 2026-10-21 (Google routes it to 3.8), so this lands on 3.8.
      return Self.gemini38Flash.rawValue
    case "gemini-3.5-flash":
      // Removed 2026-10-19: dominated by 3.7 on price and tier. Forwards to 3.8 with 3.7.
      return Self.gemini38Flash.rawValue
    case "gemini-3.7-flash":
      // Removed 2026-10-21: Google routes every request to gemini-3.8-flash (dead alias, same price).
      return Self.gemini38Flash.rawValue
    case "gemini-3-flash-preview":
      // Deprecated-pending. Forward to 3.8.
      return Self.gemini38Flash.rawValue
    case "local-mlx-qwen3-8b":
      // Offline Qwen3 8B removed 2026-09-30 (see `LocalLLMModelType`): the 4B Instruct default
      // beat it on rule compliance and latency. Stays offline — never forward to a cloud model.
      return Self.localMLXQwen34BInstruct.rawValue
    case "claude-haiku-4-5-20251001":
      // Superseded 2026-10-12 by claude-haiku-5-5: cheaper, larger context, strictly dominates.
      return Self.claudeHaiku55.rawValue
    case "gemini-3.1-flash-image":
      // Superseded 2026-10-12 by gemini-nano-banana-2.1: GA, cheaper per image, better quality.
      return Self.geminiImage.rawValue
    default:
      return raw
    }
  }

  /// True when the live Gemini API rejects `thinkingLevel: minimal` with HTTP 400.
  /// Verified for 3.1 Pro (2026-07) and 3.8 Flash (2026-09-06), both with
  /// "Thinking level MINIMAL is not supported for this model". 3.7 Flash did too (2026-08-23)
  /// before it was removed. Argon documents low/medium/high only.
  var geminiRejectsMinimalThinking: Bool {
    switch self {
    case .gemini4Argon, .gemini31Pro, .gemini38Flash: return true
    default: return false
    }
  }

  /// Loads any UserDefaults slot that must hold a chat-capable model (chat window, meeting
  /// summary, Smart Improvement). On top of `loadPromptModel` it forwards a superseded
  /// selection to its replacement and persists that, so the value always appears in the
  /// pickers, which list `chatModels`.
  /// What `loadChatSlotModel` would hand back for `raw`, computed WITHOUT touching UserDefaults.
  ///
  /// Launch-time migrations run before any slot is loaded, so they see the raw stored string —
  /// not the model the user will actually end up on. Anything that wants to reason about "which
  /// model is this slot effectively tracking" has to replay the same three steps the loader does:
  /// legacy raw-value forwarding, deprecation mapping, then supersession. Returns nil when the
  /// string does not name a model at all (the loader falls back in that case).
  static func resolvedChatSlotModel(forRawValue raw: String) -> PromptModel? {
    guard let parsed = PromptModel(rawValue: migrateLegacyPromptRawValue(raw)) else { return nil }
    let current = migrateIfDeprecated(parsed)
    return current.chatReplacement ?? current
  }

  static func loadChatSlotModel(forKey key: String, default fallback: PromptModel) -> PromptModel {
    let loaded = loadPromptModel(forKey: key, default: fallback, validate: { $0.supportsTextChat })
    guard let replacement = loaded.chatReplacement else { return loaded }
    DebugLogger.log("MODEL-LINEUP: \(key) \(loaded.rawValue) → \(replacement.rawValue) (superseded)")
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

  /// Loads the model selected for meeting summary (rolling and final). Settings → Meetings → Meeting Summary Model.
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
/// Which backend a `TTSModel` talks to. Cloud providers use a different endpoint, auth, and
/// request/response shape, but all (including on-device `.system`) return raw PCM (s16le,
/// 24 kHz, mono) so the shared playback path (`AudioMerger` / `playTTSAudio`) stays
/// provider-agnostic.
enum TTSProvider {
  case gemini
  case openai
  case xai
  /// On-device `AVSpeechSynthesizer`. No key, no network.
  case system

  var displayName: String {
    switch self {
    case .gemini: return "Google Gemini"
    case .openai: return "OpenAI"
    case .xai: return "xAI (Grok)"
    case .system: return "macOS"
    }
  }

  /// Whether Read Aloud can use this provider. Maps onto `ChatModelProvider.hasCredential` so
  /// the picker and the reconciler share its trim: Gemini through the `.gemini` requirement,
  /// OpenAI and xAI through their key kinds, on-device macOS with nothing to configure.
  /// A second switch here called `hasNonEmpty` and treated a whitespace-only key as present.
  var hasCredential: Bool {
    switch self {
    case .gemini: return ChatModelProvider.gemini.hasCredential
    case .openai: return ChatModelProvider.openai.hasCredential
    case .xai: return ChatModelProvider.grok.hasCredential
    case .system: return true
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
    case .system: return UserDefaultsKeys.selectedReadAloudVoiceSystem
    }
  }

  /// The voice catalogue this provider's TTS API accepts, ordered male → female → neutral
  /// (stable within each group). Voice ids are provider-specific (a Gemini voice name is not
  /// valid for OpenAI/xAI and vice versa). Live-verified 2026-05-30 against each provider's docs.
  /// `.system` voices come from `AVSpeechSynthesisVoice.speechVoices()` at call time.
  var voices: [TTSVoice] {
    let raw: [TTSVoice]
    switch self {
    case .gemini: raw = TTSVoice.geminiVoices
    case .openai: raw = TTSVoice.openAIVoices
    case .xai: raw = TTSVoice.xaiVoices
    case .system: return SystemTTSService.voices
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
  /// Human-readable name when `id` is an opaque identifier (macOS voice identifiers).
  var displayLabel: String? = nil

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
    let base = displayLabel ?? id.capitalized
    let genderPart = gender.isEmpty ? "" : " (\(gender))"
    let stylePart = descriptor.isEmpty ? "" : " — \(descriptor)"
    return "\(base)\(genderPart)\(stylePart)"
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
  // Gemini 3.8 TTS (Stable), prices verified 2026-09-29 at https://ai.google.dev/gemini-api/docs/pricing:
  // Flash-Lite $0.50 text / $6 audio, Flash $0.50 / $9 per 1M — vs $1 / $20 for the replaced
  // gemini-3.1-flash-tts-preview. Measured the same day (Charon, German, streaming): Flash-Lite
  // first audio 0.6–0.75 s at ~6.5× realtime, Flash 1.1–1.5 s at ~2.7×; neither paused on a
  // 397-char chunk. Flash-Lite dominates 3.1 on price, speed and stability → default. Persisted
  // 3.1 / 2.5 selections forward via migrateLegacyReadAloudRawValue.
  case gemini38FlashLiteTTS = "gemini-3.8-flash-lite-tts"
  case gemini38FlashTTS = "gemini-3.8-flash-tts"
  case openAIGpt4oMiniTTS = "gpt-4o-mini-tts"
  case grokVoiceTTS = "grok-voice-tts-1.0"
  /// On-device macOS voices (`AVSpeechSynthesizer`). Automatic Offline Mode choice.
  case systemMacOS = "system-macos"

  var provider: TTSProvider {
    switch self {
    case .gemini38FlashLiteTTS, .gemini38FlashTTS: return .gemini
    case .openAIGpt4oMiniTTS: return .openai
    case .grokVoiceTTS: return .xai
    case .systemMacOS: return .system
    }
  }

  var displayName: String {
    switch self {
    case .gemini38FlashLiteTTS: return "Gemini 3.8 Flash-Lite TTS"
    case .gemini38FlashTTS: return "Gemini 3.8 Flash TTS"
    case .openAIGpt4oMiniTTS: return "GPT-4o mini TTS"
    case .grokVoiceTTS: return "Grok Voice TTS"
    case .systemMacOS: return String(localized: "macOS (On-Device)")
    }
  }

  var description: String {
    switch self {
    case .gemini38FlashLiteTTS:
      return String(localized: "Google's Gemini 3.8 Flash-Lite TTS • Fastest start, lowest cost • 100+ languages • Recommended")
    case .gemini38FlashTTS:
      return String(localized: "Google's Gemini 3.8 Flash TTS • Highest voice quality • Slower to start than Flash-Lite")
    case .openAIGpt4oMiniTTS:
      return String(localized: "OpenAI's GPT-4o mini TTS • Natural, steerable speech • Needs an OpenAI API key")
    case .grokVoiceTTS:
      return String(localized: "xAI's Grok Voice TTS • Expressive multilingual speech • Needs an xAI API key")
    case .systemMacOS:
      return String(localized: "On-device macOS voices • No internet, no API key • Automatic choice in Offline Mode")
    }
  }

  /// API endpoint for this model's provider. For Gemini the model id is in the path and the
  /// request is the streaming variant (`streamGenerateContent?alt=sse`): the TTS models emit
  /// their audio as a series of SSE objects with base64 PCM slices, which `SpeechService`
  /// `synthesizeGeminiTTSChunk` hands to playback as they arrive (verified 2026-09-18 against
  /// `gemini-3.1-flash-tts-preview` with the same request body as the non-streaming call).
  /// For OpenAI the model id is passed in the request body. **xAI takes no model id at all** —
  /// `SpeechService` `synthesizeXAITTS` selects the voice with `voice_id` and omits `model`; see
  /// the note there. `.system` has no network endpoint.
  var apiEndpoint: String {
    switch provider {
    case .gemini:
      return "https://generativelanguage.googleapis.com/v1beta/models/\(rawValue):streamGenerateContent?alt=sse"
    case .openai:
      return AppConstants.openAISpeechEndpoint
    case .xai:
      return AppConstants.xaiTTSEndpoint
    case .system:
      return ""
    }
  }

  /// Default voice when the caller doesn't specify one. Each provider has its own voice
  /// catalogue, so "Charon" (Gemini) is not valid for OpenAI/xAI and vice versa.
  var defaultVoice: String {
    switch provider {
    case .gemini: return "Charon"
    case .openai: return "alloy"
    case .xai: return "eve"
    case .system: return SystemTTSService.defaultVoiceIdentifier
    }
  }

  /// The voices selectable for this model's provider (for the Read Aloud voice picker).
  var availableVoices: [TTSVoice] { provider.voices }

  /// Whether the user has the API key this TTS model's provider needs. Gates Read Aloud so a
  /// single provider key is enough. See `TTSProvider.hasCredential` for why this is not its own switch.
  var hasRequiredCredential: Bool {
    provider.hasCredential
  }

  /// Actionable message when this TTS model can't run Read Aloud for lack of a credential.
  var apiKeyRequiredMessage: String {
    switch provider {
    case .gemini: return String(localized: "Add your Gemini API key in Settings → Accounts or sign in with Google to use Read Aloud.")
    case .openai: return String(localized: "Add your OpenAI API key in Settings → Accounts to use Read Aloud, or pick a different voice model.")
    case .xai: return String(localized: "Add your xAI API key in Settings → Accounts to use Read Aloud, or pick a different voice model.")
    case .system: return String(localized: "On-device macOS voices need no API key.")
    }
  }

  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.readAloudModel
  }

  var costLevel: CostLevel {
    switch provider {
    case .system: return .free
    case .gemini, .openai, .xai: return .low
    }
  }

  /// Whether this TTS model may be offered while Offline Mode is on.
  var isSelectableUnderOfflineMode: Bool {
    guard OfflineMode.isEnabled else { return true }
    return provider == .system
  }

  /// Models grouped for display in the Read Aloud picker (on-device first, then cloud).
  static var readAloudModels: [TTSModel] {
    [.systemMacOS, .gemini38FlashLiteTTS, .gemini38FlashTTS, .openAIGpt4oMiniTTS, .grokVoiceTTS]
      .filter(\.isSelectableUnderOfflineMode)
  }

  /// Maps removed/renamed persisted raw values onto current cases.
  static func migrateLegacyReadAloudRawValue(_ raw: String) -> String {
    switch raw {
    case "gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts", "gemini-3.1-flash-tts-preview":
      // 2.5 previews shut down 2026-10-16; 3.1 preview replaced 2026-09-29 by the cheaper, faster,
      // stable 3.8 Flash-Lite TTS (see the TTSModel note).
      return TTSModel.gemini38FlashLiteTTS.rawValue
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
      return String(localized: "Left bottom")
    case .rightBottom:
      return String(localized: "Right bottom")
    case .leftTop:
      return String(localized: "Left top")
    case .rightTop:
      return String(localized: "Right top")
    case .centerTop:
      return String(localized: "Center top")
    case .centerBottom:
      return String(localized: "Center bottom")
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
      return String(localized: "1 second")
    case .twoSeconds:
      return String(localized: "2 seconds")
    case .threeSeconds:
      return String(localized: "3 seconds")
    case .fiveSeconds:
      return String(localized: "5 seconds")
    case .sevenSeconds:
      return String(localized: "7 seconds")
    case .tenSeconds:
      return String(localized: "10 seconds")
    case .fifteenSeconds:
      return String(localized: "15 seconds")
    case .thirtySeconds:
      return String(localized: "30 seconds")
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
    case .never: return String(localized: "Never")
    case .oneMinute: return String(localized: "1 minute")
    case .twoMinutes: return String(localized: "2 minutes")
    case .fiveMinutes: return String(localized: "5 minutes")
    case .tenMinutes: return String(localized: "10 minutes")
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
    case .never: return String(localized: "Never")
    case .sixtyMinutes: return String(localized: "60 minutes")
    case .ninetyMinutes: return String(localized: "90 minutes")
    case .twoHours: return String(localized: "2 hours")
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
    case .off: return String(localized: "Off")
    case .every3Days: return String(localized: "Every 3 days")
    case .every7Days: return String(localized: "Every 7 days")
    case .every14Days: return String(localized: "Every 14 days")
    case .every30Days: return String(localized: "Every 30 days")
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
      return String(localized: "Auto-detect")
    case .en:
      return String(localized: "English")
    case .de:
      return String(localized: "German")
    case .fr:
      return String(localized: "French")
    case .es:
      return String(localized: "Spanish")
    case .it:
      return String(localized: "Italian")
    case .pt:
      return String(localized: "Portuguese")
    case .ru:
      return String(localized: "Russian")
    case .ja:
      return String(localized: "Japanese")
    case .ko:
      return String(localized: "Korean")
    case .zh:
      return String(localized: "Chinese")
    case .nl:
      return String(localized: "Dutch")
    case .pl:
      return String(localized: "Polish")
    case .tr:
      return String(localized: "Turkish")
    case .sv:
      return String(localized: "Swedish")
    case .da:
      return String(localized: "Danish")
    case .no:
      return String(localized: "Norwegian")
    case .fi:
      return String(localized: "Finnish")
    case .cs:
      return String(localized: "Czech")
    case .hu:
      return String(localized: "Hungarian")
    case .ro:
      return String(localized: "Romanian")
    case .el:
      return String(localized: "Greek")
    case .ar:
      return String(localized: "Arabic")
    case .hi:
      return String(localized: "Hindi")
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
  case accounts = "Accounts"
  case speechToText = "Dictate"
  case speechToPrompt = "Dictate Prompt"
  case screenshot = "Screenshot"
  case readAloud = "Read Aloud"
  case chat = "Chat"
  case meetings = "Meetings"
  case improvement = "Smart Improvement"
  case aiApps = "Claude & AI Apps"
  // The raw value is both the sidebar label and the persisted selection; a stored "Permissions"
  // from an older build simply falls back to General once (`SettingsTab(rawValue:) ?? .general`).
  case permissions = "Privacy & Permissions"
  case about = "About"

  /// What the sidebar shows. The raw value is the persisted identity and stays English.
  var displayName: LocalizedStringResource {
    switch self {
    case .general: return "General"
    case .accounts: return "Accounts"
    case .speechToText: return "Dictate"
    case .speechToPrompt: return "Dictate Prompt"
    case .screenshot: return "Screenshot"
    case .readAloud: return "Read Aloud"
    case .chat: return "Chat"
    case .meetings: return "Meetings"
    case .improvement: return "Smart Improvement"
    case .aiApps: return "Claude & AI Apps"
    case .permissions: return "Privacy & Permissions"
    case .about: return "About"
    }
  }
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

  /// The next step up, wrapping from 2× back to 0.75× — what the Read Aloud pill's speed
  /// button cycles through.
  var next: ReadAloudSpeed {
    let all = Self.allCases
    let index = all.firstIndex(of: self) ?? 0
    return all[(index + 1) % all.count]
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

// MARK: - ChatGPT Plan Preferences
/// Settings for the **ChatGPT plan** chat model (`PromptModel.chatGPTPlanChat`): chat on the user's
/// ChatGPT Plus/Pro plan via the Responses API. "Configured" means signed in *and* the plan scope
/// was granted; there is no API key. Direct-download build only — under `APP_STORE` nothing here
/// ever reports configured, so no picker, offer or reconciler can reach the model.
enum ChatGPTPlanPreferences {
  static let sentinelModelRawValue = PromptModel.chatGPTPlanChat.rawValue

  /// Fallback slug until the account's model catalog has been fetched.
  static let fallbackModelID = "gpt-6-sol"

  /// False in the App Store build: OpenAI requires approval before a paid app may offer this.
  static var isAvailableInThisBuild: Bool {
    #if APP_STORE
      return false
    #else
      return true
    #endif
  }

  static func isChatGPTPlanModel(_ model: String) -> Bool {
    model == sentinelModelRawValue
  }

  /// Slug sent to the Responses API: the saved choice, else the first catalog entry, else
  /// `fallbackModelID`.
  static var modelID: String { modelID(defaults: .standard) }

  /// Same as `modelID`, reading through an injected `UserDefaults` — `MCPSettingsCatalog` needs
  /// this so its `chat.chatgpt_plan_model_id` entry never touches the real UserDefaults.standard
  /// in tests.
  static func modelID(defaults: UserDefaults) -> String {
    let saved = (defaults.string(forKey: UserDefaultsKeys.chatGPTPlanModelID) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !saved.isEmpty { return saved }
    return ChatGPTPlanModelCatalog.cachedModels().first?.slug ?? fallbackModelID
  }

  static func setModelID(_ slug: String) { setModelID(slug, defaults: .standard) }

  static func setModelID(_ slug: String, defaults: UserDefaults) {
    defaults.set(slug, forKey: UserDefaultsKeys.chatGPTPlanModelID)
  }

  /// Name of the selected model for the composer chip and pickers: the catalog's `display_name`,
  /// the slug when the catalog has no entry for it.
  static var displayName: String {
    let id = modelID
    return ChatGPTPlanModelCatalog.cachedModels().first(where: { $0.slug == id })?.displayName ?? id
  }

  /// Signed in AND the `chatgpt.tokens.use.direct` scope was granted. Reads the Keychain record
  /// (memoized by `KeychainManager`), so it is cheap enough for view bodies.
  static var isConfigured: Bool {
    guard isAvailableInThisBuild else { return false }
    return isConfigured(for: ChatGPTPlanCredentials.load())
  }

  /// Tokens too: sign-out and terminal refresh errors keep the scopes but drop the tokens.
  static func isConfigured(for credentials: ChatGPTPlanCredentials?) -> Bool {
    guard let credentials else { return false }
    return credentials.planEnabled && credentials.hasTokens
  }
}

// MARK: - OpenRouter Chat Preferences (UserDefaults + Keychain Accessors)
/// Settings for the **OpenRouter** chat model (`PromptModel.openRouterChat`). The credential is
/// only the OpenRouter account key (Settings → Accounts); the custom endpoint knows nothing about it.
enum OpenRouterChatPreferences {
  static let sentinelModelRawValue = PromptModel.openRouterChat.rawValue

  static func isOpenRouterModel(_ model: String) -> Bool {
    model == sentinelModelRawValue
  }

  /// Slug sent to OpenRouter (e.g. `openai/gpt-4o`).
  static var modelID: String { modelID(defaults: .standard) }

  /// Same as `modelID`, reading through an injected `UserDefaults` — `MCPSettingsCatalog` needs
  /// this so its `chat.openrouter_model_id` entry never touches the real UserDefaults.standard
  /// in tests.
  static func modelID(defaults: UserDefaults) -> String {
    let v = (defaults.string(forKey: UserDefaultsKeys.openRouterChatModelID) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? SettingsDefaults.openRouterChatModelID : v
  }

  static func setModelID(_ slug: String) { setModelID(slug, defaults: .standard) }

  static func setModelID(_ slug: String, defaults: UserDefaults) {
    defaults.set(slug, forKey: UserDefaultsKeys.openRouterChatModelID)
  }

  /// The part of `modelID` after the last "/" (the whole slug when there is none) — short enough
  /// for the composer's model chip.
  static var shortModelName: String {
    let id = modelID
    guard let slash = id.lastIndex(of: "/") else { return id }
    return String(id[id.index(after: slash)...])
  }

  /// The OpenRouter account key, trimmed; nil when none is stored.
  static var apiKey: String? {
    let trimmed = KeychainManager.shared.get(.openRouter)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty == false) ? trimmed : nil
  }

  static var isConfigured: Bool { apiKey != nil }

  static let chatCompletionsURL = AppConstants.openRouterChatCompletionsEndpoint

  // MARK: Migration from the custom endpoint

  /// What to carry over when the custom endpoint used to point at openrouter.ai.
  struct CustomEndpointMigration: Equatable {
    let modelID: String?
    let keyToAdopt: String?
  }

  /// Pure planning half of the migration. nil unless the custom endpoint's host is `openrouter.ai`
  /// or a subdomain of it. A key typed for an openrouter.ai URL is adopted only when no account
  /// key exists yet, so it keeps working.
  static func customEndpointMigration(
    customEndpointURL: String?, customModelID: String?, proxyKey: String?, openRouterKey: String?
  ) -> CustomEndpointMigration? {
    let urlText = (customEndpointURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let host = URL(string: urlText)?.host?.lowercased(),
      host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
    else { return nil }
    func trimmed(_ value: String?) -> String {
      (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let model = trimmed(customModelID)
    let proxy = trimmed(proxyKey)
    let hasAccountKey = !trimmed(openRouterKey).isEmpty
    return CustomEndpointMigration(
      modelID: model.isEmpty ? nil : model,
      keyToAdopt: (!hasAccountKey && !proxy.isEmpty) ? proxy : nil)
  }

  /// One-time move of an OpenRouter-pointed custom endpoint onto the OpenRouter provider. Idempotent:
  /// once the custom URL is cleared the plan is nil.
  @MainActor
  static func migrateCustomEndpointIfNeeded() {
    let defaults = UserDefaults.standard
    guard
      let plan = customEndpointMigration(
        customEndpointURL: defaults.string(forKey: UserDefaultsKeys.customOpenAIChatEndpointURL),
        customModelID: defaults.string(forKey: UserDefaultsKeys.customOpenAIChatModelID),
        proxyKey: KeychainManager.shared.get(.customOpenAIChatAPIKey),
        openRouterKey: KeychainManager.shared.get(.openRouter))
    else { return }

    if let key = plan.keyToAdopt, !KeychainManager.shared.save(key, for: .openRouter) {
      DebugLogger.logWarning("OPENROUTER-CHAT: could not save adopted key to Keychain; migration postponed")
      return
    }
    if let modelID = plan.modelID { setModelID(modelID) }
    defaults.removeObject(forKey: UserDefaultsKeys.customOpenAIChatEndpointURL)
    defaults.removeObject(forKey: UserDefaultsKeys.customOpenAIChatModelID)
    KeychainManager.shared.delete(.customOpenAIChatAPIKey)

    let old = PromptModel.customOpenAIEndpoint.rawValue
    let new = PromptModel.openRouterChat.rawValue
    let selectionKeys = [
      UserDefaultsKeys.selectedChatModel,
      UserDefaultsKeys.selectedPromptModel,
      UserDefaultsKeys.selectedImprovementModel,
      UserDefaultsKeys.selectedMeetingSummaryModel,
      UserDefaultsKeys.selectedReadAloudModel,
    ]
    for key in selectionKeys where defaults.string(forKey: key) == old {
      defaults.set(new, forKey: key)
    }
    // The pre-Offline-Mode snapshot restores these same slots later; rewrite it too.
    if var snapshot = defaults.dictionary(forKey: UserDefaultsKeys.offlineModePreOfflineSelections) {
      var changed = false
      for (key, value) in snapshot where (value as? String) == old {
        snapshot[key] = new
        changed = true
      }
      if changed { defaults.set(snapshot, forKey: UserDefaultsKeys.offlineModePreOfflineSelections) }
    }
    DebugLogger.log(
      "OPENROUTER-CHAT: migrated custom endpoint → OpenRouter provider (model=\(plan.modelID ?? modelID))")
  }
}

// MARK: - Custom OpenAI-compatible Chat Preferences (UserDefaults + Keychain Accessors)
/// Settings for the explicit **Custom endpoint** chat model (`PromptModel.customOpenAIEndpoint`):
/// a server the user runs or rents (OpenInference, Azure OpenAI, Vertex AI, LiteLLM, self-hosted).
/// Regular OpenAI models (GPT-5, …) always use api.openai.com regardless of these values.
enum OpenAIChatPreferences {
  static let sentinelModelRawValue = PromptModel.customOpenAIEndpoint.rawValue

  /// Non-empty when the user configured a custom base URL in Settings → Chat.
  static var customEndpointBaseURL: String? {
    let trimmed = (UserDefaults.standard.string(forKey: UserDefaultsKeys.customOpenAIChatEndpointURL) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Model tag sent to the server (e.g. `zai-org/GLM-5.2`).
  static var modelID: String {
    let v = (UserDefaults.standard.string(forKey: UserDefaultsKeys.customOpenAIChatModelID) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? SettingsDefaults.customOpenAIChatModelID : v
  }

  /// Which stored credential the custom endpoint ends up using. Surfaced in Settings → Chat so the
  /// answer to "which key is this actually sending?" is visible instead of inferred.
  enum ResolvedCredential {
    case proxyKey
    case openAIKey

    var description: String {
      switch self {
      case .proxyKey: return String(localized: "the key entered above for this server")
      case .openAIKey: return String(localized: "your OpenAI API key from Settings → Accounts")
      }
    }
  }

  /// Decides which credential a custom endpoint should use.
  ///
  /// `customOpenAIChatAPIKey` is **one** slot shared by every custom endpoint, and the base URL it
  /// belongs to can change underneath it: the key field belongs to whatever server the URL names
  /// right now. It wins when present; the OpenAI key from Settings → Accounts is the fallback, for
  /// proxies that forward to api.openai.com on the caller's key. Pure so the ordering is pinned by
  /// tests rather than by clicking through.
  ///
  /// `allowsOpenAIKeyFallback` is false for a customer's own tenant (Azure, Vertex). The OpenAI
  /// fallback exists for proxies that forward to api.openai.com; at a tenant endpoint that key
  /// cannot work, and sending it there would hand the user's OpenAI credential to an unrelated
  /// third party in exchange for a 401.
  static func resolveCredential(
    proxyKey: String?,
    openAIKey: String?,
    allowsOpenAIKeyFallback: Bool = true
  ) -> (key: String, source: ResolvedCredential)? {
    func usable(_ value: String?) -> String? {
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    if let key = usable(proxyKey) { return (key, .proxyKey) }
    if allowsOpenAIKeyFallback, let key = usable(openAIKey) { return (key, .openAIKey) }
    return nil
  }

  /// The credential and where it came from, resolved against the Keychain.
  static var resolvedCredential: (key: String, source: ResolvedCredential)? {
    resolveCredential(
      proxyKey: KeychainManager.shared.get(.customOpenAIChatAPIKey),
      openAIKey: KeychainManager.shared.get(.openAI),
      allowsOpenAIKeyFallback: CustomEndpointAuth.acceptsOpenAIAPIKey(
        baseURL: customEndpointBaseURL ?? ""))
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

  static var chatCompletionsURL: String {
    guard let base = customEndpointBaseURL,
          let url = CustomEndpointAuth.endpointURL(appending: "chat/completions", to: base)
    else {
      return "https://invalid.local/missing-custom-openai-endpoint"
    }
    return url
  }

  /// Auth headers for the configured endpoint — `api-key` on Azure, `Authorization: Bearer`
  /// everywhere else. See `CustomEndpointAuth`.
  static func authHeaders(apiKey: String) -> [String: String] {
    CustomEndpointAuth.headers(baseURL: customEndpointBaseURL ?? "", apiKey: apiKey)
  }

  /// True when the configured base URL is an Azure OpenAI / Foundry tenant.
  static var isAzureEndpoint: Bool {
    guard let base = customEndpointBaseURL else { return false }
    return CustomEndpointAuth.flavor(forBaseURL: base) == .azure
  }

  /// Points chat at an Azure OpenAI / Microsoft Foundry tenant. The user still fills in their
  /// resource name and deployment — this only fixes the URL shape, which is the part that is
  /// easy to get wrong.
  static func applyAzureOpenAIPreset() {
    UserDefaults.standard.set(SettingsDefaults.azureOpenAIEndpointURL, forKey: UserDefaultsKeys.customOpenAIChatEndpointURL)
    UserDefaults.standard.set(SettingsDefaults.azureOpenAIModelID, forKey: UserDefaultsKeys.customOpenAIChatModelID)
  }

  /// Points chat at Vertex AI's OpenAI-compatible surface. Vertex takes a short-lived `gcloud`
  /// access token as the key — see the Settings copy, which says so plainly.
  static func applyVertexAIPreset() {
    UserDefaults.standard.set(SettingsDefaults.vertexAIEndpointURL, forKey: UserDefaultsKeys.customOpenAIChatEndpointURL)
    UserDefaults.standard.set(SettingsDefaults.vertexAIModelID, forKey: UserDefaultsKeys.customOpenAIChatModelID)
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
    case .fifteenSeconds: return String(localized: "15 seconds")
    case .thirtySeconds: return String(localized: "30 seconds")
    case .fortyFiveSeconds: return String(localized: "45 seconds")
    case .sixtySeconds: return String(localized: "60 seconds")
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
    case .verbatim: return String(localized: "0.0 · verbatim")
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
    case .minimal: return String(localized: "Minimal")
    case .low: return String(localized: "Low")
    case .medium: return String(localized: "Medium")
    case .high: return String(localized: "High")
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
  static let addToGlossary: ShortcutDefinition? = nil

  // MARK: - Model & Prompt Settings
  // Chat defaults to 3.8 Flash — the current Gemini workhorse (GA 2026-09-02), same
  // introductory price as 3.7 ($0.75/$3.75 per 1M through 2026). Dictate Prompt
  // and meeting summary stay on 3.5 Flash-Lite because those run more often and Flash is
  // roughly 3× the output price of Flash-Lite.
  // https://ai.google.dev/gemini-api/docs/pricing
  //
  // Dictation defaults to OpenAI's `gpt-transcribe`, not a Gemini tier. Measured 2026-09-03 against
  // the live app container (17 glossary terms, 3 runs/case, 10 interleaved latency rounds), it
  // beat the previous default `gemini-3.1-flash-lite` on every axis: 0/9 vs 3/9 transcripts
  // invented from silence, 76% vs 71% glossary, and faster at every audio length
  // (1.3 s: 735 vs 1010 ms · 8.2 s: 864 vs 1165 ms · 21.3 s: 1295 vs 1478 ms).
  // Numbers: plans/model-audits/2026-09-03-audit.md. It costs $0.0045/min vs roughly a third of
  // that for Flash-Lite — negligible for dictation. It ignores the Dictation prompt (the glossary
  // still goes as keyword hints). A user without an OpenAI key is moved to their own provider's
  // model by `ModelSelectionReconciler.transcriptionReplacement` — Gemini users keep 3.1 Flash-Lite.
  static let selectedTranscriptionModel = TranscriptionModel.openAIGPTTranscribe
  /// Verbatim by default: transcription should reproduce speech, not sample alternatives.
  static let transcriptionTemperature = TranscriptionTemperature.verbatim
  /// Unchanged from what the app has always sent — raising it costs latency on every dictation,
  /// so it stays the user's call.
  static let transcriptionThinkingEffort = TranscriptionThinkingEffort.minimal
  /// Cheapest audio-capable model on OpenRouter's own pricing list (2026-07).
  static let openRouterTranscriptionModelID = "google/gemini-3.5-flash-lite"
  static let selectedPromptModel = PromptModel.gemini38Flash
  static let selectedChatModel = PromptModel.gemini38Flash
  static let chatCloseOnFocusLoss = true
  // Off by default: a Settings window that vanishes when you click elsewhere (e.g. to copy an
  // API key from a browser) is surprising. Users can opt back in via the Behavior section.
  static let settingsCloseOnFocusLoss = false

  // MARK: - Read Aloud (Chat TTS)
  /// Default Read Aloud TTS model when the user hasn't picked one. User selection is persisted
  /// under `UserDefaultsKeys.selectedReadAloudModel` and read via `ReadAloudPreferences.model`.
  static let readAloudModel: TTSModel = .gemini38FlashLiteTTS
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
  /// 3 s: long enough to read a short transcript; 1 s vanished before it could be read.
  static let notificationDuration = NotificationDuration.threeSeconds
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
  /// registers — but it does analysis over a whole corpus, which Flash-Lite is weak at. 3.8 Flash
  /// is the current workhorse (GA 2026-09-02): same introductory price as 3.7 ($0.75/$3.75 per 1M
  /// through 2026). 3.7 stays selectable — the audit's probe had 3.8 ~12% slower, so it is not
  /// hidden. https://ai.google.dev/gemini-api/docs/models
  static let selectedImprovementModel = PromptModel.gemini38Flash

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
  /// Default model tag for the Custom endpoint chat model.
  static let customOpenAIChatModelID = "openai/gpt-4o"
  /// Model id sent to the shared custom endpoint for transcription. The self-hosted path
  /// hardcoded this before the id was stored.
  static let customTranscriptionModelID = "whisper-1"
  /// [OpenInference](https://openinference.de/) preset — EU-hosted GLM 5.2, OpenAI-compatible.
  static let openInferenceEndpointURL = "https://openinference.de/api/v1"
  static let openInferenceModelID = "zai-org/GLM-5.2"
  /// Default slug for the OpenRouter chat model.
  static let openRouterChatModelID = "openai/gpt-4o"

  // MARK: - Bring-your-own-tenant presets (Azure / Vertex)
  /// Azure OpenAI / Microsoft Foundry preset. The `/openai/v1` surface needs no `api-version`
  /// and takes the **deployment name** as the model. `<resource>` is a placeholder the user
  /// replaces; the region their resource sits in is what decides where inference runs.
  /// https://learn.microsoft.com/azure/ai-foundry/openai/api-version-lifecycle
  static let azureOpenAIEndpointURL = "https://<resource>.openai.azure.com/openai/v1"
  /// Azure addresses a model by *deployment* name, which the customer chose — this is only a
  /// plausible default, not a model id that exists in every tenant.
  static let azureOpenAIModelID = "gpt-5-mini"
  /// Vertex AI's OpenAI-compatible surface. Regional on purpose: `europe-west4` keeps inference
  /// in the EU, which is the whole point of pointing at your own project.
  /// https://docs.cloud.google.com/vertex-ai/generative-ai/docs/start/openai
  static let vertexAIEndpointURL =
    "https://europe-west4-aiplatform.googleapis.com/v1/projects/<project>/locations/europe-west4/endpoints/openapi"
  /// Vertex requires the publisher prefix on the model id.
  static let vertexAIModelID = "google/gemini-2.5-flash"

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
  var readAloudVoiceSystem: String = ""

  /// The selected Read Aloud voice id for `provider` ("" → provider default).
  func readAloudVoice(for provider: TTSProvider) -> String {
    switch provider {
    case .gemini: return readAloudVoiceGemini
    case .openai: return readAloudVoiceOpenAI
    case .xai: return readAloudVoiceXAI
    case .system: return readAloudVoiceSystem
    }
  }

  mutating func setReadAloudVoice(_ id: String, for provider: TTSProvider) {
    switch provider {
    case .gemini: readAloudVoiceGemini = id
    case .openai: readAloudVoiceOpenAI = id
    case .xai: readAloudVoiceXAI = id
    case .system: readAloudVoiceSystem = id
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
  case addToGlossaryShortcut
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

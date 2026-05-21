---
name: llm-model-docs
description: Look up current official documentation AND current model lineups for OpenAI, Google Gemini, and xAI (Grok). Use BEFORE adding/changing model IDs, before answering model-capability questions (e.g. "does gpt-4o-transcribe accept a system prompt?"), AND proactively whenever you touch chat/transcription/TTS code paths (provider files, SettingsConfiguration, TranscriptionModels, ChatModelCommandResolver, SpeechService) — compare our current defaults to what each provider has shipped recently, and surface upgrade suggestions to the user if newer GA models exist. AI moves fast — always check live docs first.
---

# LLM & Speech Model Documentation

Use this skill **before** doing any of the following:

- Adding, renaming, or changing model IDs in [SettingsConfiguration.swift](WhisperShortcut/Settings/Shared/SettingsConfiguration.swift), [TranscriptionModels.swift](WhisperShortcut/TranscriptionModels.swift), [AppConstants.swift](WhisperShortcut/AppConstants.swift), or anywhere else a model ID is hardcoded.
- Answering user questions about what a model supports (parameters, modalities, context window, pricing tier, GA vs Preview).
- Choosing between model variants for a new feature.
- Verifying whether an old assumption about a model still holds (e.g. token limits, supported parameters, deprecations).

**Also use proactively** whenever you are working in any of these areas, even if the user did not ask about models:

- Chat providers — [GeminiChatProvider.swift](WhisperShortcut/GeminiChatProvider.swift), [OpenAIChatProvider.swift](WhisperShortcut/OpenAIChatProvider.swift), [GrokChatProvider.swift](WhisperShortcut/GrokChatProvider.swift), [LLMChatProvider.swift](WhisperShortcut/LLMChatProvider.swift), [ChatModelCommandResolver.swift](WhisperShortcut/ChatModelCommandResolver.swift).
- Speech and TTS — [SpeechService.swift](WhisperShortcut/SpeechService.swift), [TranscriptionModels.swift](WhisperShortcut/TranscriptionModels.swift).
- Settings UI / defaults — [SettingsConfiguration.swift](WhisperShortcut/Settings/Shared/SettingsConfiguration.swift), [ChatSettingsTab.swift](WhisperShortcut/Settings/Tabs/ChatSettingsTab.swift), [SpeechToTextSettingsTab.swift](WhisperShortcut/Settings/Tabs/SpeechToTextSettingsTab.swift), [SpeechToPromptSettingsTab.swift](WhisperShortcut/Settings/Tabs/SpeechToPromptSettingsTab.swift).

In those areas, do the **lineup check** (next section) before finishing the task and proactively tell the user if anything looks outdated. The user wants to hear about new GA models from this skill — not from X.com or coincidence.

**Rule of thumb:** training data is stale. If you find yourself about to say "model X supports Y" or "the prompt field is limited to N tokens", **fetch the doc first**. Cite the URL in your answer.

## Lineup check (proactive model-currency review)

When you touch one of the code areas listed above, run this short check before finishing:

1. **Enumerate what we use today.** In [SettingsConfiguration.swift](WhisperShortcut/Settings/Shared/SettingsConfiguration.swift), the `SettingsDefaults` struct is the single source of truth for default selections (e.g. `selectedTranscriptionModel`, `selectedPromptModel`, `selectedChatModel`, `selectedMeetingSummaryModel`, `defaultSmartImprovementModel`, `readAloudModel`). The full per-provider enum is in [SettingsConfiguration.swift](WhisperShortcut/Settings/Shared/SettingsConfiguration.swift) (`PromptModel`) and [TranscriptionModels.swift](WhisperShortcut/TranscriptionModels.swift) (`TranscriptionModel`, `TTSModel`).
2. **Fetch the current model index** for each provider whose model appears in defaults or in the enum (see URLs below).
3. **Compare**: for each role (transcription, dictate-prompt, chat, meeting-summary, smart-improvement, TTS), is the default still the best current GA model? Are any enum cases pointing at deprecated/retired IDs?
4. **Surface findings to the user.** Format: "We default to X for role Y. Provider has shipped newer GA model Z — recommended switch / cosmetic update / no change needed." Don't just silently migrate — let the user decide. The user explicitly said: *"ich möchte, dass du ab und zu mal schaust, was für neuere Models es gibt … und dann entsprechend Vorschläge machst, falls wir veraltete Models verwenden"*.

When deciding between "Flash"/"mini"/"lite" variants and the flagship variant, pick by **role intent**:

- **Transcription default** → cheap-fast Flash/Lite tier (it runs on every dictation). Flagship is overkill.
- **Dictate Prompt / Chat default** → Flash tier (price-performance balance, the role most users interact with).
- **Meeting summary / Smart Improvement** → Flash or Pro tier depending on context length and reasoning needs (long meetings benefit from Pro; quick summaries don't).
- **TTS** → whichever variant is documented as TTS-capable in current docs.

For each suggestion, name the **exact replacement model ID**, link the doc URL where you confirmed it, and call out GA vs Preview clearly.

## Workflow

1. Open the relevant docs URL(s) below with `WebFetch`. Ask a specific question (parameter list, GA status, token limits, supported features).
2. If `WebFetch` returns 403 or the page is JS-rendered, fall back to `WebSearch` with the provider name + topic + the current year.
3. Quote the exact wording from the docs when it matters (parameter behavior, limits, model lifecycle).
4. **Cross-check with the provider's status/forum** if something contradicts what code does or what the user reports — see "Forums & status" below.

## Provider-specific docs

### OpenAI (Chat, Transcription, TTS)

The app uses these OpenAI endpoints today: `/v1/chat/completions`, `/v1/audio/transcriptions`, `/v1/audio/speech`.

- **API reference (all endpoints)**: <https://platform.openai.com/docs/api-reference>
  - Audio / transcription: <https://platform.openai.com/docs/api-reference/audio/createTranscription>
  - Chat completions: <https://platform.openai.com/docs/api-reference/chat>
  - TTS: <https://platform.openai.com/docs/api-reference/audio/createSpeech>
- **Guides**:
  - Speech-to-text: <https://developers.openai.com/api/docs/guides/speech-to-text>
  - Text-to-speech: <https://platform.openai.com/docs/guides/text-to-speech>
- **Model index** (capabilities, deprecation dates, context windows): <https://platform.openai.com/docs/models>
- **Per-model pages** (price, modalities, rate limits, supported parameters):
  - `gpt-4o-transcribe`: <https://developers.openai.com/api/docs/models/gpt-4o-transcribe>
  - `gpt-4o-mini-transcribe`: <https://developers.openai.com/api/docs/models/gpt-4o-mini-transcribe>
  - `gpt-4o-transcribe-diarize`: <https://developers.openai.com/api/docs/models/gpt-4o-transcribe-diarize>
  - General chat/4o family: navigate from <https://platform.openai.com/docs/models>
- **Pricing**: <https://openai.com/api/pricing/>

**Gotchas worth verifying live before relying on them:**

- `whisper-1` `prompt` field is capped at **224 tokens** (vocabulary hint only).
- `gpt-4o-transcribe` / `gpt-4o-mini-transcribe` `prompt` field accepts **GPT-4o-style instructions** (no separate `system`/`instructions` field), no documented 224-token cap.
- `temperature` is **not** supported on `gpt-4o-transcribe` family; `stream` **is**.
- No separate `system` field on the transcription endpoint — instructions go into `prompt`.

### Google Gemini API

For Gemini-specific deep dives (Files API, TTS voices, IDs, GA vs Preview), see the dedicated skill **gemini-model-docs**. Headline URLs:

- **Models overview**: <https://ai.google.dev/gemini-api/docs/models>
- **API reference**: <https://ai.google.dev/api/models>
- **Speech generation (TTS)**: <https://ai.google.dev/gemini-api/docs/speech-generation>
- **Programmatic model list**: `GET https://generativelanguage.googleapis.com/v1beta/models`
- **Forum** (deprecation notices, outages): <https://discuss.ai.google.dev/c/gemini-api/4>

The app uses the **Gemini API** (`generativelanguage.googleapis.com`), **not** Vertex AI — when reading Google docs, make sure you're on the `ai.google.dev` site, not `cloud.google.com/vertex-ai`.

### xAI (Grok)

The app uses Grok via the OpenAI-compatible chat completions interface — see [GrokChatProvider.swift](WhisperShortcut/GrokChatProvider.swift).

- **Docs home**: <https://docs.x.ai/>
- **API reference**: <https://docs.x.ai/api>
  - Chat completions: <https://docs.x.ai/docs/api-reference#chat-completions>
- **Model index** (IDs, context windows, modalities, pricing): <https://docs.x.ai/docs/models>
- **Pricing**: <https://docs.x.ai/docs/models#models-and-pricing>
- **Changelog / model lifecycle**: <https://docs.x.ai/docs/release-notes>
- **Status page**: <https://status.x.ai/>

**Gotchas worth verifying live before relying on them:**

- Grok model IDs change quickly (e.g. `grok-4`, `grok-4-fast`, `grok-code-fast-1`). Confirm the exact ID is still listed on the models page before committing.
- The OpenAI-compatible endpoint may not support every OpenAI parameter — check the API reference if a feature behaves differently.

## Forums & status (use when docs disagree with reality)

When a model returns unexpected errors, or you suspect a deprecation/rename, check these BEFORE assuming the bug is in our code:

- **OpenAI status**: <https://status.openai.com/>
- **OpenAI developer forum**: <https://community.openai.com/c/api/7>
- **Gemini forum**: <https://discuss.ai.google.dev/c/gemini-api/4>
- **Google AI status**: <https://status.cloud.google.com/>
- **xAI status**: <https://status.x.ai/>

## How to use in this repo

1. **Before changing a model ID**: open the provider's model index, confirm the new ID exists and its GA/Preview status, then update raw values in [SettingsConfiguration.swift](WhisperShortcut/Settings/Shared/SettingsConfiguration.swift), [TranscriptionModels.swift](WhisperShortcut/TranscriptionModels.swift), or [AppConstants.swift](WhisperShortcut/AppConstants.swift). Keep or add a comment pointing at the doc URL you used.
2. **Before answering "does model X support Y?"**: WebFetch the per-model or guide page, quote the exact wording, and link the URL in your response.
3. **After changes**: rebuild and restart the app (see the `rebuild-after-change` skill).

## Anti-patterns

- Don't answer model-capability questions from memory alone — recall is unreliable for fast-moving model details.
- Don't propagate stale assumptions from old code comments without re-checking the doc.
- Don't conflate Gemini API (`ai.google.dev`) with Vertex AI (`cloud.google.com/vertex-ai`) — they document different model surfaces.
- Don't trust unofficial mirrors (third-party API doc sites) over the provider's own pages.

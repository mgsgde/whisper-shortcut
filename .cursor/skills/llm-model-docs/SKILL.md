---
name: llm-model-docs
description: Look up current official documentation AND current model lineups for OpenAI, Google Gemini, xAI (Grok), and Anthropic (Claude). Use BEFORE adding/changing model IDs, before answering model-capability questions (e.g. "does gpt-4o-transcribe accept a system prompt?"), AND proactively whenever you touch chat/transcription/TTS code paths (provider files, SettingsConfiguration, TranscriptionModels, ChatModelCommandResolver, SpeechService) — compare our current defaults to what each provider has shipped recently, and surface upgrade suggestions to the user if newer GA models exist. AI moves fast — always check live docs first.
---

# LLM & Speech Model Documentation

Use this skill **before** doing any of the following:

- Adding, renaming, or changing model IDs in `SettingsConfiguration.swift`, `TranscriptionModels.swift`, `AppConstants.swift`, or anywhere else a model ID is hardcoded.
- Answering user questions about what a model supports (parameters, modalities, context window, pricing tier, GA vs Preview).
- Choosing between model variants for a new feature.
- Verifying whether an old assumption about a model still holds (e.g. token limits, supported parameters, deprecations).

**Also use proactively** whenever you are working in any of these areas, even if the user did not ask about models:

- Chat providers — `GeminiChatProvider.swift`, `OpenAIChatProvider.swift`, `GrokChatProvider.swift`, `LLMChatProvider.swift`, `ChatModelCommandResolver.swift`.
- Speech and TTS — `SpeechService.swift`, `TranscriptionModels.swift`.
- Settings UI / defaults — `SettingsConfiguration.swift`, `ChatSettingsTab.swift`, `SpeechToTextSettingsTab.swift`, `SpeechToPromptSettingsTab.swift`.

In those areas, do the **lineup check** (next section) before finishing the task and proactively tell the user if anything looks outdated. The user wants to hear about new GA models from this skill — not from X.com or coincidence.

**Rule of thumb:** training data is stale. If you find yourself about to say "model X supports Y" or "the prompt field is limited to N tokens", **fetch the doc first**. Cite the URL in your answer.

## Lineup check (proactive model-currency review)

When you touch one of the code areas listed above, run this short check before finishing:

1. **Enumerate what we use today.** In `SettingsConfiguration.swift`, the `SettingsDefaults` struct is the single source of truth for default selections (e.g. `selectedTranscriptionModel`, `selectedPromptModel`, `selectedChatModel`, `selectedMeetingSummaryModel`, `selectedImprovementModel`, `readAloudModel`). The full per-provider enum is in `SettingsConfiguration.swift` (`PromptModel`, `TTSModel`) and `TranscriptionModels.swift` (`TranscriptionModel`).
2. **Fetch the current model index** for each provider whose model appears in defaults or in the enum (see URLs below).
3. **Compare**: for each role (transcription, dictate-prompt, chat, meeting-summary, smart-improvement, TTS), is the default still the best current GA model? Are any enum cases pointing at deprecated/retired IDs?
4. **Surface findings to the user.** Format: "We default to X for role Y. Provider has shipped newer GA model Z — recommended switch / cosmetic update / no change needed." Don't just silently migrate — let the user decide. The user explicitly said: *"ich möchte, dass du ab und zu mal schaust, was für neuere Models es gibt … und dann entsprechend Vorschläge machst, falls wir veraltete Models verwenden"*.

5. **Apply the Pareto rule in both directions — prune AND keep.** See the section below. Adding without pruning rots the picker into a list of dead models; pruning by version number alone silently deletes the cheap end of the lineup, which is worse.

## The Pareto rule (the user's standing requirement)

> Every model we offer must sit on the price/performance frontier. No model may be **dominated**: another model of the same provider being *better in every respect at the same or lower price*.

Domination is an **AND across all axes** — quality, speed, price (input *and* output rates), context window. A model is dominated only when a sibling wins or ties on all of them and wins on at least one. Consequences that are easy to get wrong:

- **A higher version number is NOT domination.** Gemini 3.1 Flash-Lite has a 40% cheaper output rate than 3.5 Flash-Lite ($1.50 vs $2.50 per 1M) and 3.5 Flash-Lite is cheaper on *audio* input — they cross, so both stay. Google positions 3.5 Flash as "most intelligent" while 3.6 Flash is cheaper on output — they cross too.
- **A price ladder is not redundancy.** Flagship / mid / mini tiers of one generation are all frontier points. Deleting the cheap tiers leaves single-key users of that provider with only the most expensive option — the opposite of what the rule is for.
- **Same price + newer generation IS domination.** This is the pattern that actually justifies pruning: gpt-5.6-sol is priced exactly like gpt-5.5 ($5/$30) and gpt-5.6-terra exactly like gpt-5.4 ($2.50/$15), so 5.5 and 5.4 are dominated. Likewise grok-4.20-* cost exactly what grok-4.3 costs at the same 1M context.
- **A model missing from our lineup is also a violation** — a frontier point we simply never added (grok-4.5, claude-fable-5, the gpt-5.6 family were all found this way).

Mechanically: set `chatReplacement` on the dominated case in `PromptModel` (SettingsConfiguration.swift). That one property removes it from every chat-facing list — chat-window picker, Settings → Chat, meeting summary, Smart Improvement — and forwards persisted selections to the replacement, same provider. Keep the enum case if a non-chat role still uses it (Dictate Prompt audio, `speakerConsolidationModel`); delete it only when nothing references it.

**You cannot do this from memory.** Domination is a claim about *current* prices — fetch the provider's pricing page every time, and quote the numbers in the reasoning. Anything you didn't just read is a guess.

### Adding a model — definition of done

Adding a `PromptModel` case is not done until all of these are handled (the compiler catches the exhaustive `switch`es; the rest is on you):

- `displayName`, `shortAlias` (unique), `description`
- `geminiThinkingConfig` / provider-specific request knobs — verify the tier's accepted values against live docs, don't copy a neighbouring tier blindly
- `asTranscriptionModel` + a matching `TranscriptionModel` case if the model should be selectable for dictation/meetings
- `chatReplacement` set on the model this one supersedes (step 5 above)
- `SettingsDefaults` — should the new model become the default for chat / dictate prompt / meeting summary / improvement?
- `ChatModelCommandResolver` — the `/model` version branches (`"3.6"`, `"3.5"`, …) and the `isFlash`/`isFlashLite`/`isPro` helpers
- `migrateLegacyPromptRawValue` — forward any raw value that the provider retired or renamed

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

This is the canonical Gemini reference for the repo, covering chat, transcription, and TTS.

- **Models overview** (IDs, GA vs Preview, capabilities): <https://ai.google.dev/gemini-api/docs/models>
- **Deprecations / shutdown schedule**: <https://ai.google.dev/gemini-api/docs/deprecations>
- **API reference**: <https://ai.google.dev/api/models>
- **Speech generation (TTS)**: <https://ai.google.dev/gemini-api/docs/speech-generation> — the TTS voice catalogue and the `gemini-3.1-flash-tts-preview` style IDs live here.
- **Programmatic model list**: `GET https://generativelanguage.googleapis.com/v1beta/models` — verify IDs/capabilities at runtime when docs feel ambiguous.
- **Forum** (deprecation notices, outages): <https://discuss.ai.google.dev/c/gemini-api/4>

Pick stable/GA IDs over dated preview IDs (e.g. prefer `gemini-3.5-flash` over a dated `gemini-3.5-flash-preview-*` variant) when both are listed. Endpoints in code: `TranscriptionModel.apiEndpoint`, `TTSModel.apiEndpoint`; base is `https://generativelanguage.googleapis.com/v1beta/models/{model-id}:generateContent`.

The app uses the **Gemini API** (`generativelanguage.googleapis.com`), **not** Vertex AI — when reading Google docs, make sure you're on the `ai.google.dev` site, not `cloud.google.com/vertex-ai`. Cloud Text-to-Speech (`cloud.google.com/text-to-speech/docs/gemini-tts`) documents the same/similar TTS models for Cloud/Vertex; use it only as a cross-check.

### xAI (Grok)

The app uses Grok via the OpenAI-compatible chat completions interface — see `GrokChatProvider.swift`.

- **Docs home**: <https://docs.x.ai/>
- **API reference**: <https://docs.x.ai/api>
  - Chat completions: <https://docs.x.ai/docs/api-reference#chat-completions>
- **Model index** (IDs, context windows, modalities, pricing): <https://docs.x.ai/docs/models>
- **Pricing**: <https://docs.x.ai/docs/models#models-and-pricing>
- **Changelog / model lifecycle**: <https://docs.x.ai/docs/release-notes>
- **Status page**: <https://status.x.ai/>

**Gotchas worth verifying live before relying on them:**

- Grok model IDs change quickly and xAI retires slugs without notice (the app currently ships `grok-4.20-0309-non-reasoning`, `grok-4.20-0309-reasoning`, `grok-4.3`; `grok-4.5` is live upstream). Confirm the exact ID is still listed on the models page before committing.
- The OpenAI-compatible endpoint may not support every OpenAI parameter — check the API reference if a feature behaves differently.

### Anthropic (Claude) — chat only

The app exposes Claude in the chat window via the Messages API (`AnthropicChatProvider.swift`).
There is **no** Dictate Prompt or TTS wiring — Anthropic ships no speech models, so those
coverage gaps cannot be closed with a model ID.

- **Model overview** (IDs, GA status, context windows): <https://platform.claude.com/docs/en/about-claude/models/overview>
- **Messages API reference**: <https://platform.claude.com/docs/en/api/messages>
- **Deprecations**: <https://platform.claude.com/docs/en/about-claude/model-deprecations>
- **Status**: <https://status.claude.com/>

**No test script exists yet.** `scripts/` has Gemini/OpenAI/Grok scripts only, and `.env` carries
no `ANTHROPIC_API_KEY`, so Claude IDs in `PromptModel` are currently unguarded by the audit loop.
Verify by hand before changing them:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" -H 'anthropic-version: 2023-06-01' \
  -H 'content-type: application/json' \
  -d '{"model":"claude-sonnet-5","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'
```

## Forums & status (use when docs disagree with reality)

When a model returns unexpected errors, or you suspect a deprecation/rename, check these BEFORE assuming the bug is in our code:

- **OpenAI status**: <https://status.openai.com/>
- **OpenAI developer forum**: <https://community.openai.com/c/api/7>
- **Gemini forum**: <https://discuss.ai.google.dev/c/gemini-api/4>
- **Google AI status**: <https://status.cloud.google.com/>
- **xAI status**: <https://status.x.ai/>

## How to use in this repo

1. **Before changing a model ID**: open the provider's model index, confirm the new ID exists and its GA/Preview status, then update raw values in `SettingsConfiguration.swift`, `TranscriptionModels.swift`, or `AppConstants.swift`. Keep or add a comment pointing at the doc URL you used.
2. **Before answering "does model X support Y?"**: WebFetch the per-model or guide page, quote the exact wording, and link the URL in your response.
3. **Verify with the live API, not just the docs.** Docs lag behind retirements and silent renames. Use the test scripts in `scripts/`:
   - `scripts/test-gemini-models.sh`
   - `scripts/test-openai-models.sh`
   - `scripts/test-grok-models.sh`
   They read keys from `.env` at the repo root (mode 600, gitignored). Each script tests three buckets: `current` (must 200), `legacy` (Gemini/Grok: must still serve via redirect; OpenAI: must 404 to confirm retirement), and `candidate` (exploratory). Add a model to the right bucket whenever you make an enum change so future runs catch regressions.
4. **Watch for silent redirects.** xAI redirects retired slugs to current ones with HTTP 200 but a different `model` field in the response. The Grok test script (`scripts/test-grok-models.sh`) compares response.model vs requested model — if they differ, it prints "redirected → X". When you see a redirect, the enum case is dead weight: remove it and add a `migrateLegacyPromptRawValue` mapping.
5. **After code changes**: rebuild and restart via `bash scripts/rebuild-and-restart.sh` (per the always-applied rule in `.cursor/rules/index.mdc`).
6. **If one provider's script fails uniformly, diagnose credentials first.** When every line for that provider shares the same HTTP code (e.g. all Gemini `400`), run one probe `curl` and read `error.message` before blaming model IDs. Common Gemini cases: `API key expired` / `API_KEY_INVALID` (renew in AI Studio, update `.env`) vs per-model `404` (retired slug — see [deprecations](https://ai.google.dev/gemini-api/docs/deprecations)). Report OpenAI, Grok, and Gemini pass/fail **separately** so the user does not think all providers failed.

## Anti-patterns

- Don't answer model-capability questions from memory alone — recall is unreliable for fast-moving model details.
- Don't propagate stale assumptions from old code comments without re-checking the doc.
- Don't conflate Gemini API (`ai.google.dev`) with Vertex AI (`cloud.google.com/vertex-ai`) — they document different model surfaces.
- Don't trust unofficial mirrors (third-party API doc sites) over the provider's own pages.

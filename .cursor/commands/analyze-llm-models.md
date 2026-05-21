# Analyze LLM Models

Survey the current model lineups at OpenAI, Google Gemini, and xAI (Grok), compare them against what this repo uses today, and recommend concrete migrations — then **prove the recommendations work** by running the local test scripts. Use this when the user asks "are we on the latest models?", "what's new in LLMs?", "should we switch to X?", or simply runs `/analyze-llm-models`.

The dual purpose: stay current (the user heard about Grok 4.3 from X.com instead of from us — don't let that happen again) and stay honest (training data is stale, so the recommendation MUST be verified against the live API before it ships).

## Workflow

1. **Read the current code state.** Enumerate every model ID this app references — do not assume from memory.
   - [WhisperShortcut/TranscriptionModels.swift](WhisperShortcut/TranscriptionModels.swift) — `TranscriptionModel` cases (Gemini + OpenAI transcription + offline Whisper + self-hosted).
   - [WhisperShortcut/Settings/Shared/SettingsConfiguration.swift](WhisperShortcut/Settings/Shared/SettingsConfiguration.swift) — `PromptModel` cases (Gemini + Grok + OpenAI chat), `TTSModel` cases, and `SettingsDefaults` (the *default* selections per role: transcription, dictate prompt, chat, meeting summary, smart improvement, TTS).
   - Migration tables — `PromptModel.migrateLegacyPromptRawValue` and `TranscriptionModel.migrateLegacyTranscriptionRawValue`.

2. **Pull the current model index from each provider.** Use WebFetch first; if it returns 403 / hallucinates / is JS-rendered, fall back to WebSearch with the current year. URLs are documented in the **llm-model-docs** skill — read that skill if you have not already in this session.
   - **OpenAI**: <https://platform.openai.com/docs/models> + per-model pages on developers.openai.com. Also list available IDs programmatically: `GET https://api.openai.com/v1/models` with `Authorization: Bearer $OPENAI_API_KEY`.
   - **Gemini**: <https://ai.google.dev/gemini-api/docs/models> + programmatic list `GET https://generativelanguage.googleapis.com/v1beta/models?key=$GEMINI_API_KEY`.
   - **xAI**: <https://docs.x.ai/docs/models> + release notes <https://docs.x.ai/docs/release-notes> + retirement notices.
   - Cross-reference with provider status pages and forums if anything looks off.

3. **Build a comparison matrix.** For each role in the app, list:
   - Current default (from `SettingsDefaults`).
   - Provider's newest GA model that fits the role's intent (cheap-fast for transcription, balanced Flash tier for chat/prompt, Pro tier for smart improvement, TTS-capable for read aloud).
   - Whether any enum case points at a retired/renamed slug.

   Decide role-fit using the heuristic from the `llm-model-docs` skill:
   - Transcription default → cheap-fast Flash/Lite tier.
   - Dictate Prompt / Chat / Meeting Summary → Flash tier (price-performance).
   - Smart Improvement → Pro or larger Flash with strong reasoning.
   - TTS → whichever variant is documented as TTS-capable.

4. **Verify with the live API.** Before recommending any model, run the relevant test script — these read `.env` at the repo root (mode 600, gitignored).
   ```
   ./scripts/test-gemini-models.sh
   ./scripts/test-openai-models.sh
   ./scripts/test-grok-models.sh
   ```
   Each prints `OK` / `FAIL` for three buckets: `current` (must serve), `legacy` (migration safety net — Gemini/Grok must still redirect with 200; OpenAI legacy must 404 to prove retirement), `candidate` (exploratory). If a model you want to recommend isn't in `candidate` yet, **add it there first**, re-run the script, and only recommend it if the script reports OK. Watch for xAI's silent redirects: `grok-test.sh` compares response.model vs requested model and prints `redirected → X` when they differ — that's a signal the slug is dead weight.

5. **Make the recommendations.** Each one must include the exact replacement model ID, the doc URL where you confirmed it, the test-script line that proves it works against the user's API key, and what code change implements it.

## Constraints

- **Never recommend a model you haven't verified live.** Recall is unreliable for model IDs and behavior. If a script can't be run (no key in `.env`), say so and stop — don't fabricate confidence.
- **No code changes in the analysis pass.** This command produces a report. Apply changes only if the user follows up with "migrate", "apply", "do it", "alles", etc.
- **Don't conflate Gemini API with Vertex AI.** This app uses `generativelanguage.googleapis.com` (ai.google.dev), not Vertex.
- **Don't propagate stale code comments.** If a model file's header comment lists IDs that have since changed, flag it in the report — don't trust it as a source.

## Output format

### Provider snapshot (live)

For each provider, a short table of currently advertised GA + relevant Preview models with IDs and one-line capability summary. Quote the doc URL you fetched.

### What we use today

For each role, the current `SettingsDefaults` selection + every enum case across `TranscriptionModel`, `PromptModel`, `TTSModel`. Flag any retired / renamed slug (live API said 404 or redirected).

### Recommended migrations

For each suggestion: **From → To**, role affected, doc URL, test-script proof line, and the file(s) that would change. Group by risk:

- **Risk-free** — same model, different slug (e.g. a `-preview` slug that's now GA).
- **Behavioral upgrade** — newer model, similar role, may produce slightly different output.
- **Cleanup** — remove enum cases that point at retired slugs (their `migrateLegacyXyzRawValue` mapping handles persisted selections).

### Test-script confirmation

Paste the relevant test-script output lines proving each recommended ID returns OK. If any returns FAIL, downgrade it from "recommended" to "investigate further" and explain.

### Open questions

Anything you couldn't decide alone — e.g. "GPT-5.5 Pro pricing is 6× GPT-5.5; do we want that price tier as a default for Smart Improvement?".

## When the user follows up with "migrate" / "apply" / "alles"

Actually apply the recommended migrations:

1. Update enum raw values, add new cases, remove retired cases.
2. Update default selections in `SettingsDefaults`.
3. Extend the relevant `migrateLegacy*RawValue` table so existing UserDefaults selections still resolve.
4. Make sure all exhaustive `switch` statements that enumerate cases (displayName, description, costLevel, provider, asymmetryClass, etc.) handle the additions and removals.
5. Update the test scripts: move new IDs from `candidate` → `current`, removed IDs from `current` → `legacy` with the right assertion (`must serve via redirect` vs `must 404`).
6. Build (`xcodebuild -scheme WhisperShortcut -configuration Debug build`).
7. Re-run all three test scripts and confirm exit 0 for each (the multi-agent xAI slug is a known false-positive — exclude it from candidates).
8. Do **not** commit unless the user explicitly asks.

## Related

- **`llm-model-docs` skill** — the canonical curated list of where each provider documents their models, gotchas (whisper-1 224-token limit etc.), and the proactive-lineup-check workflow. Read it before this command does anything.
- **`gemini-model-docs` skill** — Gemini-specific deep dive (TTS voices, Files API, multimodal).
- **`new-release` skill** — bump the app version after model migrations ship.

## Example invocations

- `/analyze-llm-models` — full survey across all three providers.
- `/analyze-llm-models --provider gemini` — focus on one provider.
- `/analyze-llm-models --role transcription` — only look at transcription defaults and candidate Whisper / Gemini Flash-Lite / OpenAI transcribe alternatives.
- `/analyze-llm-models migrate` — survey, then apply the recommendations (equivalent to running the command, reviewing, and saying "alles").

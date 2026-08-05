---
name: audit-llm-models
description: Audit OpenAI, Gemini, xAI (Grok), and Anthropic model lineups against what this repo uses today, recommend concrete migrations, and prove them with the test scripts. Use for "are we on the latest models?", "what's new in LLMs?", "should we switch to X?".
---

# Audit LLM Models

Systematic audit of the current model lineups at OpenAI, Google Gemini, xAI (Grok), and Anthropic (Claude) — compare against what this repo uses today and recommend concrete migrations, then **prove the recommendations work** by running the local test scripts. Use this when the user asks "are we on the latest models?", "what's new in LLMs?", "should we switch to X?", or simply runs `/audit-llm-models`.

This command audits along **four axes**:

1. **Currency** — for each feature, is the default still the newest GA model that fits the role? (stay current: the user heard about Grok 4.3 from X.com instead of from us — don't let that happen again.)
2. **Provider coverage** — for each feature, does the app offer a usable model from *every* provider that has one? The goal: **a user who supplies only one provider's API key can still use every feature of the app.** Any feature that is single-provider (e.g. a role where only one provider currently ships a capable model) is a coverage gap — flag it, and if a competing provider ships a capable model, recommend adding it.
3. **Empirical fitness** — for transcription, *measure* rather than assume: latency, glossary adherence, and silence hallucination, via `scripts/benchmark-transcription.py`. This axis exists because assuming cost the app a default: 3.5 Flash-Lite was made the dictation default in 2026-07 on the (correct) grounds that its audio-input rate is cheaper, and a measurement in 2026-08 showed it was 3.6× slower than 3.1 Flash-Lite on a 35 s dictation, reproduced glossary terms 77% vs 95% of the time, and leaked invented transcripts past the app's plausibility gates that 3.1's did not. **A price table cannot tell you any of that.**
4. **Pareto pruning** — every model offered must sit on the price/performance frontier. When one model of the same provider is better-or-equal on *every* axis and strictly better on at least one, the loser comes out of the lineup. See "Pareto pruning" below; the rule itself lives in the `llm-model-docs` skill.

The throughline is honesty: training data is stale, so every currency recommendation AND every "provider X now has a capable model for this role" coverage claim MUST be verified against the live API before it ships.

## Workflow

1. **Read the current code state.** Enumerate every model ID this app references — do not assume from memory.
   - `WhisperShortcut/TranscriptionModels.swift` — `TranscriptionModel` cases (Gemini + OpenAI transcription + xAI `grok-stt` + offline Whisper + self-hosted).
   - `WhisperShortcut/Settings/Shared/SettingsConfiguration.swift` — `PromptModel` cases (Gemini + Grok + OpenAI + Anthropic chat, plus the `local-llm` and `custom-openai-endpoint` sentinels), `TTSModel` cases, and `SettingsDefaults` (the *default* selections per role: transcription, dictate prompt, chat, meeting summary, smart improvement, TTS).
   - Migration tables — `PromptModel.migrateLegacyPromptRawValue`, `TranscriptionModel.migrateLegacyTranscriptionRawValue`, and `TTSModel.migrateLegacyReadAloudRawValue` (called from `ModelSelectionReconciler`). Read Aloud is an audited role, so a TTS migration that skips its table silently drops persisted voice-model selections.

2. **Pull the current model index from each provider.** Use WebFetch first; if it returns 403 / hallucinates / is JS-rendered, fall back to WebSearch with the current year. **All provider doc URLs, programmatic-list endpoints, deprecation pages, and status/forum links live in the `llm-model-docs` skill — read that skill (if you haven't this session) and use its URLs.** Cross-check every enum slug still in `current` against the Gemini deprecations table before recommending "no change."

3. **Build a feature × provider coverage matrix.** This is the heart of the audit. Enumerate every feature the app exposes a model choice for — transcription (Dictate), Dictate Prompt, Chat, Meeting Summary, Smart Improvement, Read Aloud (TTS), and any vision/screenshot path — and for each, fill a row with one cell per provider:

   | Feature | OpenAI | Gemini | xAI (Grok) | Anthropic | Default today |
   |---------|--------|--------|------------|-----------|---------------|
   | Read Aloud (TTS) | `gpt-4o-mini-tts` ✅ | `gemini-3.1-flash-tts-preview` ✅ (current) | `grok-voice-tts-1.0` ✅ (needs `language` in the body) | — no TTS model | Gemini |

   In each provider cell record one of: **offered** (enum already has a case → note the ID), **available-but-missing** (provider ships a capable model the app doesn't offer yet → coverage gap, name the ID), or **none** (provider has no model for this role → not a gap, just note it). Mark the cell `✅`/`gap`/`—` accordingly.

   For each feature also note:
   - Current default (from `SettingsDefaults`) and whether it's still the newest GA model that fits the role.
   - Whether any enum case points at a retired/renamed slug.

   Decide role-fit using the heuristic in the `llm-model-docs` skill ("Lineup check" section) — don't restate it here.

   A feature with fewer than the maximum achievable provider cells filled is a **coverage gap**: a user holding only the missing provider's key cannot use that feature. That's the primary thing this matrix surfaces.

4. **Verify with the live API.** Before recommending any model — whether a currency upgrade or a coverage-gap fill — run the relevant test script, and for coverage gaps probe the *new* endpoint/parameters directly with `curl` (a provider's TTS or vision path is often a different endpoint than its chat path, and account entitlement can differ — e.g. xAI TTS may return 403 "Team is not authorized" even though the model is listed). These read `.env` at the repo root (gitignored; keep it non-world-readable).
   ```
   ./scripts/test-gemini-models.sh
   ./scripts/test-openai-models.sh
   ./scripts/test-grok-models.sh
   ```
   Each prints `OK` / `FAIL` per bucket — `current` (must serve), `legacy` (migration safety net — Gemini/Grok must still redirect with 200; OpenAI legacy must 404 to prove retirement), `legacy-retired` (must 404), and `candidate` (exploratory); the OpenAI script additionally splits out audio-chat and transcription buckets. There is no Anthropic script yet — verify Claude IDs with a direct `curl` to `api.anthropic.com/v1/messages` and say so in the report. If a model you want to recommend isn't in `candidate` yet, **add it there first**, re-run the script, and only recommend it if the script reports OK. Watch for xAI's silent redirects: `test-grok-models.sh` compares response.model vs requested model and prints `redirected → X` when they differ — that's a signal the slug is dead weight.
   - **Partial Gemini failure:** If most `[current]` lines are OK and one slug returns **404**, treat it as a **retired enum case** (check deprecations), not a key problem. After removal, move the slug to `LEGACY_RETIRED_TEXT_MODELS` in `test-gemini-models.sh` with **must 404** (same pattern as OpenAI `LEGACY_CHAT_MODELS`), or add it there until the enum case is removed.
   - **Uniform Gemini failure:** If every Gemini line fails with the same HTTP code, probe one request and read `error.message` (expired key vs outage) before reporting model failures. Report each provider's script result separately.

5. **Benchmark the transcription and Dictate Prompt lineups.** `test-*-models.sh` proves a model *serves*; it says nothing about whether it is a good model to dictate with. Run:
   ```
   python3 scripts/benchmark-transcription.py            # latency + glossary + silence, ~15 min
   python3 scripts/benchmark-transcription.py --suite latency --rounds 10
   python3 scripts/benchmark-dictate-prompt.py          # rule compliance for audio-chat models
   python3 scripts/benchmark-dictate-prompt.py --cases edit-not-append --rounds 6
   ```
   The second script covers the **Dictate Prompt** path (chat completions with an inline
   `input_audio` part), which the transcription benchmark cannot see at all. It scores rule
   compliance rather than accuracy: does the model *apply* the spoken instruction instead of
   appending it, keep a casual register casual, leave a wrong date alone, avoid turning prose into
   bullets. Both scripts score output **after** the app's own post-processing, so a number here is
   what the user would actually get — when you change that post-processing, update the mirrored
   logic in the script too, or the benchmark starts measuring a build that does not exist.
   It reads the user's **real** Dictation prompt and Whisper Glossary from the app container, so the numbers reflect their vocabulary, not a synthetic one. Read the method notes in the script's docstring before interpreting output — in particular, latency must come from interleaved shuffled rounds and be reported as a median. A sequential per-model loop produced 2× differences that did not replicate.

   Three things decide a transcription default, in this order:
   - **Silence hallucination** — how often an invented transcript survives the app's plausibility gates and reaches the clipboard. A model that pastes fiction into the user's document is disqualifying, however fast or cheap it is. The script scores this through reimplementations of both gates in `TextProcessingUtility`.
   - **Glossary adherence** — percentage of the user's own terms reproduced verbatim. This is what users actually perceive as "accuracy".
   - **Latency** — median, at several audio lengths. Short-clip and long-clip rankings differ; report both.

   For **Dictate Prompt**, the decisive measure is the `edit-not-append` case: the model must fold the spoken instruction into the text rather than glue it on the end. That single case separated `gpt-audio-1.5` (6/6) from `gpt-audio` and `gpt-audio-mini` (2/6) on 2026-08-02 and is what justified the migration.

   Cost is the tie-breaker, not the lead criterion. When a new transcription or audio-chat model appears, add it to `MODELS` / `DEFAULT_MODELS` in the relevant script (with its request shape) and re-run before recommending it.

6. **Apply the Pareto rule in both directions.** For each provider, lay out the models the app offers with their price, measured/known quality, speed, and context window, and ask: is any of them beaten on *every* axis by a sibling? Only then is it dominated and removed. The two mistakes to avoid, both of which have happened:
   - Pruning by version number. A newer generation is not domination — Flash-Lite tiers cross on audio-input vs output price, and 3.1 beat 3.5 on speed and adherence while 3.5 was cheaper on audio input.
   - Never pruning at all. A picker full of superseded models is its own failure; when a model is priced identically to a newer sibling and loses on every measured axis, remove it.
   Also check the inverse: a frontier model the app simply never added is a violation too.

7. **Make the recommendations.** Each one must include the exact replacement model ID, the doc URL where you confirmed it, the test-script line that proves it works against the user's API key, the benchmark numbers where the role is transcription, and what code change implements it.

## Constraints

- **Never recommend a model you haven't verified live.** Recall is unreliable for model IDs and behavior. If a script can't be run (no key in `.env`), say so and stop — don't fabricate confidence.
- **No code changes in the analysis pass** (see the suggestions-first rule in `index.mdc`). "migrate" / "alles" is the follow-up that applies them.
- **Don't conflate Gemini API with Vertex AI.** This app uses `generativelanguage.googleapis.com` (ai.google.dev), not Vertex.
- **Don't propagate stale code comments.** If a model file's header comment lists IDs that have since changed, flag it in the report — don't trust it as a source.

## Output format

### Provider snapshot (live)

For each provider, a short table of currently advertised GA + relevant Preview models with IDs and one-line capability summary. Quote the doc URL you fetched.

### What we use today

For each role, the current `SettingsDefaults` selection + every enum case across `TranscriptionModel`, `PromptModel`, `TTSModel`. Flag any retired / renamed slug (live API said 404 or redirected).

### Provider coverage matrix

The feature × provider table from workflow step 3. One row per feature, one cell per provider (`✅ offered` / `gap` / `—` none), plus the current default. This is the headline output: it shows at a glance which features a single-key user can and cannot reach.

### Coverage gaps

For every cell marked `gap` (provider ships a capable model the app doesn't offer): the feature, the missing provider, the exact model ID to add, the endpoint it uses, doc URL, and the live `curl`/test-script proof that the user's key can actually call it. If a gap can't be closed (provider has no such model, or the account isn't entitled — e.g. xAI TTS 403), say so explicitly so it's a known limitation, not an oversight. **Closing coverage gaps is how we reach the goal: every feature usable with any single provider's key.**

### Transcription benchmark

The table from `scripts/benchmark-transcription.py`: per model, silence leaks (n/total), glossary adherence (%), and median latency at each audio length. State the run parameters (rounds, date) so the next audit can compare like with like. If a suite was skipped, say which and why — a missing number is not a passing grade.

### Pareto check

One row per model the app offers, grouped by provider, with the axes that decide domination (input/output price, measured quality where available, speed, context window). Then two explicit lists:

- **Dominated → remove** — for each, the sibling that beats it on every axis, with the numbers. Implement via `chatReplacement` (chat-facing models) or by deleting the enum case plus a `migrateLegacy*RawValue` entry.
- **Frontier but missing** — models that belong in the lineup and are not there yet.

If nothing is dominated, say so explicitly. "No pruning needed" is a valid result; silence is not.

### Recommended migrations

For each suggestion: **From → To** (or **Add** for a coverage fill), role affected, doc URL, test-script proof line, and the file(s) that would change. Group by intent:

- **Risk-free** — same model, different slug (e.g. a `-preview` slug that's now GA).
- **Behavioral upgrade** — newer model, similar role, may produce slightly different output.
- **Coverage fill** — add a model from a provider currently missing for a feature, so a single-key user of that provider gains access.
- **Cleanup** — remove enum cases that point at retired slugs (their `migrateLegacyXyzRawValue` mapping handles persisted selections).

### Test-script confirmation

Paste the relevant test-script output lines proving each recommended ID returns OK. If any returns FAIL, downgrade it from "recommended" to "investigate further" and explain.

### Open questions

Anything you couldn't decide alone — e.g. "GPT-5.5 Pro pricing is 6× GPT-5.5; do we want that price tier as a default for Smart Improvement?".

## When the user follows up with "migrate" / "apply" / "alles"

Actually apply the recommended migrations:

1. Update enum raw values, add new cases (including coverage-fill cases from new providers), remove retired cases. A coverage fill may need a new provider branch in the feature's request path (different endpoint/auth/response decoding), not just an enum case — implement that too, or call out clearly what's still required if it's a larger change.
2. Update default selections in `SettingsDefaults`.
3. Extend the relevant `migrateLegacy*RawValue` table so existing UserDefaults selections still resolve.
4. Make sure all exhaustive `switch` statements that enumerate cases (displayName, description, costLevel, provider, asymmetryClass, etc.) handle the additions and removals.
5. Update the test scripts: move new IDs from `candidate` → `current`, removed IDs from `current` → `legacy` with the right assertion (`must serve via redirect` vs `must 404`).
6. Build via the always-applied rebuild rule (`bash scripts/rebuild-and-restart.sh`).
7. Re-run all three test scripts and confirm exit 0 for each (the multi-agent xAI slug is a known false-positive — exclude it from candidates).

## Related

- **`llm-model-docs` skill** — the canonical curated list of where each provider documents their models, gotchas (whisper-1 224-token limit etc.), and the proactive-lineup-check workflow. Read it before this command does anything.
- **`/release`** — bump the app version after model migrations ship.

## Example invocations

- `/audit-llm-models` — full survey across all four providers.
- `/audit-llm-models --provider gemini` — focus on one provider.
- `/audit-llm-models --role transcription` — only look at transcription defaults and candidate Whisper / Gemini Flash-Lite / OpenAI transcribe alternatives.
- `/audit-llm-models --coverage` — focus on the feature × provider matrix and coverage gaps only: which features are missing a provider, and what to add so any single key unlocks everything.
- `/audit-llm-models migrate` — survey, then apply the recommendations (equivalent to running the command, reviewing, and saying "alles").

---
name: analyze-user-interactions
description: Mine the local user-interaction JSONL logs to find systematic failures and propose improvements (system prompt, defaults, code, logging, or UI). Follows the procedure in .cursor/skills/analyze-user-interactions/SKILL.md.
---

# Analyze User Interactions

Mine the local user-interaction logs to find systematic failures and propose improvements at the right level (system prompt, defaults, code, logging, or UI). Read **`.cursor/skills/analyze-user-interactions/SKILL.md`** and follow its procedure end-to-end.

## Scope resolution

Resolve scope in this order:

1. **Explicit override** — if the user specifies a flag, honor it:
   - `--mode <name>` — restrict to `prompt`, `transcription`, or `geminiChat`. Default: all three.
   - `--since <range>` — time window. Default: last 7 days.
   - `--model <id>` — restrict to interactions where this model was actually active (requires cross-referencing the macOS log). Useful right after a default-model change.
2. **Default** — last 7 days, all three modes, all models, with model attribution cross-referenced from the macOS log.
3. **Print scope first** — window, modes, total records, distinct models actually used. The user should be able to reject the default before you continue.

## Steps (per the skill)

1. **Establish scope** and print it.
2. **Extract** records from `~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext/interactions-*.jsonl`.
3. **Cross-reference** the macOS log via `bash scripts/logs.sh -t <window> -f '<filter>'` for latency and errors. Model attribution is in the JSONL `model` field for all three modes; only fall back to the log filter `PROMPT-MODE-GEMINI: Using model` for older `prompt` records that pre-date that field.
4. **Classify** each interaction against the 6 checks in the skill: instruction honored, minimal-edit, language preserved, format preserved, no hallucinations, input integrity.
5. **Cluster** failures. **Threshold: ≥2 examples per cluster** for a fix proposal. Single anecdotes are listed as "observed, insufficient data".
6. **Report** — see output format below.

## Output format

### Scope
Window, modes, total records, distinct models actually used.

### Failure clusters
For each cluster with ≥2 examples: short name, why it matters, then quoted examples (instruction / input excerpt / output excerpt with timestamps).

### Proposed changes
One per cluster, **tagged** with level:
- `[prompt]` — system-prompt edit (`WhisperShortcut/AppConstants.swift`)
- `[default]` — `SettingsDefaults` value (`WhisperShortcut/Settings/Shared/SettingsConfiguration.swift`)
- `[code]` — code logic fix (specific file:line)
- `[logging]` — `ContextLogger.swift` / `DebugLogger` gap
- `[ui]` — UI / preset / shortcut

Cite file paths so the user can verify.

### Gaps for confident analysis
Logging holes, sample-size issues, missing cross-references — anything that makes a finding tentative.

## When the user follows up with "fix" / "apply"

Apply only the proposed changes the user names (or all if they say "all"). Rebuild via `bash scripts/rebuild-and-restart.sh` (per the always-applied rule in `.cursor/rules/index.mdc`) before reporting completion. Do not commit unless explicitly asked.

## Related commands / skills

- **`/review-code`** — when the user wants a static code review instead of a usage-driven one. Use this command when the scope is "behavior the user actually experienced".
- **`/audit-llm-context`** — when the user wants to check the LLM-context files (`.cursor/commands`, `.cursor/rules`, `.cursor/skills`) themselves for staleness instead of app behavior.
- **debugging-workflow** (skill) — switch to when a cluster points to a code bug and you need to add `DebugLogger` instrumentation + a repro plan.
- **gemini-system-prompt-best-practices** (skill) — when the fix is a system-prompt change.
- **llm-model-docs** (skill) — when proposing a default-model change (covers Gemini canonically; `gemini-model-docs` is a TTS-only stub).

## Example invocations

- `analyze-user-interactions` — default scope (7 days, all modes, all models).
- `analyze-user-interactions --mode prompt` — only Dictate Prompt.
- `analyze-user-interactions --since "2 days" --model gemini-3-flash-preview` — only the model we just switched to.

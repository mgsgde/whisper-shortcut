---
name: analyze-user-interactions
description: Mine the local user-interaction JSONL logs to find systematic failures and propose improvements (system prompt, defaults, code, logging, or UI). Follows the procedure in .cursor/skills/analyze-user-interactions/SKILL.md.
---

# Analyze User Interactions

Mine the local user-interaction logs to find systematic failures and propose improvements at the right level (system prompt, defaults, code, logging, or UI).

**Read `.cursor/skills/analyze-user-interactions/SKILL.md` and follow its procedure end-to-end.** The skill is the source of truth for data sources, the extraction one-liner, the 6-point classification checks, the ≥2-example clustering threshold, the tagged output format (`[prompt]` / `[default]` / `[code]` / `[logging]` / `[ui]`), anti-patterns, and linked skills. This command only adds the invocation-time scope flags below — don't restate the skill's content.

## Scope resolution

Resolve scope in this order, then **print it first** (window, modes, total records, distinct models actually used) so the user can reject the default before you continue:

1. **Explicit override** — honor any flag the user passes:
   - `--mode <name>` — restrict to `prompt`, `transcription`, or `geminiChat`. Default: all three.
   - `--since <range>` — time window. Default: last 7 days.
   - `--model <id>` — restrict to interactions where this model was actually active (cross-reference the macOS log). Useful right after a default-model change.
2. **Default** — last 7 days, all three modes, all models, with model attribution cross-referenced from the macOS log.

## When the user follows up with "fix" / "apply"

Apply only the proposed changes the user names (or all if they say "all"). Rebuild via `bash scripts/rebuild-and-restart.sh` (per the always-applied rule in `.cursor/rules/index.mdc`) before reporting completion. Do not commit unless explicitly asked.

## Related commands

- **`/review-code`** — static code review instead of a usage-driven one. Use this command when the scope is "behavior the user actually experienced".
- **`/audit-llm-context`** — check the LLM-context files (`.cursor/commands`, `.cursor/rules`, `.cursor/skills`) themselves for staleness instead of app behavior.

(Skill-level cross-links — debugging-workflow, gemini-system-prompt-best-practices, llm-model-docs — are listed in the skill itself.)

## Example invocations

- `analyze-user-interactions` — default scope (7 days, all modes, all models).
- `analyze-user-interactions --mode prompt` — only Dictate Prompt.
- `analyze-user-interactions --since "2 days" --model gemini-3.5-flash` — only the model we just switched to.

# Cursor Commands — Naming Convention

Every slash command follows **`{verb}-{topic}`**. The verb tells the agent _what kind of work_ to do; the topic names the domain. Workflow-style commands (one-off operational entry points) may omit the verb prefix.

## Verbs

| Verb            | Use when                                                                  | Output                                                        |
| --------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------- |
| **`audit-*`**   | Systematic quality pass over a bounded corpus (model lineups, LLM-context files, logs, heuristics) | Tiered checklist, false pos/neg, coverage gaps                |
| **`analyze-*`** | Diagnose a symptom — _why_ / _where_ / _how much drift_                   | Root cause + concrete fix                                     |
| **`review-*`**  | Qualitative assessment (code, UI, commits)                                | Positives, concerns, suggestions — no file edits unless asked |
| **`report-*`**  | Counts and lists only                                                     | Numbers, lists — minimal recommendations                      |
| **`validate-*`** | End-to-end sanity check that a specific behavior is wired up correctly    | Pass/fail per checkpoint, with log/file evidence              |
| _(workflow)_    | Meta / one-off operational entry points                                    | Side-effect (release cut, version bump, etc.)                 |

## Inventory

| Command                                              | Skill                          | Verb     |
| ---------------------------------------------------- | ------------------------------ | -------- |
| `/audit-llm-context [--scope=…] [--fix-tier-1] [--no-subagents]` | `audit-llm-context` | audit |
| `/audit-llm-models [--provider …] [--role …] [--coverage] migrate` | `llm-model-docs` | audit    |
| `/analyze-user-interactions [--mode …] [--since …] [--model …]` | `analyze-user-interactions` | analyze  |
| `/analyze-chat-freeze [--file …] [--since …]`        | `analyze-chat-freeze`          | analyze  |
| `/review-code [N]`                                   | —                              | review   |
| `/review-llm-state-of-the-art`                       | `review-llm-state-of-the-art`  | review   |
| `/validate-audio-verification`                       | `validate-audio-verification`  | validate |
| `/improve-context`                                   | —                              | workflow |
| `/release`                                           | —                              | workflow |
| `/submit-appstore`                                   | `app-store-connect` (parent)   | workflow |

### Skills without a slash command (agent-invoked)

These run automatically when their `description:` matches the user's intent — no explicit slash command needed:

| Skill                                       | Role                                       |
| ------------------------------------------- | ------------------------------------------ |
| `view-logs-via-bash`                        | Run `bash scripts/logs.sh` for log queries |
| `debugging-workflow`                        | Add `DebugLogger` instrumentation + repro plan |
| `push-after-rebuild`                        | Rebuild then commit + push                 |
| `llm-model-docs`                            | Canonical pointers to OpenAI / Gemini / xAI docs (incl. Gemini TTS) |
| `gemini-system-prompt-best-practices`       | Apply Google's prompt guidance when editing Gemini system prompts |
| `run-whisper-shortcut`                      | Build / launch / drive / screenshot the app via `driver.sh` (run, onboarding, walkthrough) |

Note: the rebuild rule lives in `.cursor/rules/index.mdc` with `alwaysApply: true`, so no separate `rebuild-after-change` skill is needed.

## Rules for new commands

1. **Pick the verb first** — don't default everything to `analyze-`. If the work produces a qualitative judgment, it's `review-*`. If it produces an end-to-end pass/fail wired-up check, it's `validate-*`. If it walks a fixed corpus systematically, it's `audit-*`. If it diagnoses a symptom, it's `analyze-*`.
2. **One command file in `.cursor/commands/`** with a thin description and pointer; **the canonical playbook lives in `.cursor/skills/<same-name>/SKILL.md`** for non-trivial commands. The command is the user-facing entry point; the skill is the procedure the agent follows. Simple commands (e.g. `/release`) don't need a paired skill.
3. **Cross-link sibling commands by slash name** (`/audit-llm-context`), not file path — links survive moves.
4. **`.claude/commands` and `.claude/skills` are symlinks to `.cursor/`** — only edit under `.cursor/`. Touching `.claude/...` directly will silently break the next time the symlinks are recreated.
5. **Reference scripts, not steps.** If `scripts/logs.sh` or `scripts/rebuild-and-restart.sh` already does the work, the skill should call the script — don't restate the steps.
6. **Verify before recommending.** Skills that name a Swift type, model ID, or file path are making a claim the codebase should currently satisfy. Run `grep -n` / `Read` before relying on the claim in a fresh audit.

## Renamed (2026-05-24)

| Old                      | New                  | Reason                                                                                  |
| ------------------------ | -------------------- | --------------------------------------------------------------------------------------- |
| `analyze-code-quality`   | `review-code`        | Output is a qualitative judgment, not a symptom diagnosis — fits `review-*`.            |
| `analyze-llm-models`     | `audit-llm-models`   | Systematic pass over a bounded corpus (model lineups) + recommendation — fits `audit-*`. |
| `new-release`            | `release`            | Workflow command; verb prefix not meaningful here.                                      |

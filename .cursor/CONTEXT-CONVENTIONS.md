# Context Files — Where To Put What, And How To Name It

Same layout as sabaki.dance (`~/sabaki.dance.v3/.cursor/CONTEXT-CONVENTIONS.md`) and the parent
repo, so an agent that knows one repo knows all three. Not a slash command — governance docs live
in `.cursor/`, never in `.cursor/commands/`, where every file becomes a command.

## Where to put what (read this first)

| Kind                | Path                                            | When it loads                 | Edit here, not the symlink                                   |
| ------------------- | ----------------------------------------------- | ----------------------------- | ------------------------------------------------------------ |
| Repo facts, always  | `AGENTS.md` (= `CLAUDE.md`)                     | Every session                 | that file                                                    |
| Working rules       | `.cursor/rules/index.mdc` (`alwaysApply: true`) | Every session (via `AGENTS.md` `@`-reference in Claude Code) | `.cursor/rules/`                    |
| Rules by glob       | `.cursor/rules/*.mdc` with `globs`/`paths`      | Matching files                | `.cursor/rules/`                                             |
| Playbook / routine  | `.agents/skills/<name>/SKILL.md`                | On `/name` or when relevant   | `.agents/skills/` (`.claude/skills` is a symlink **here**)   |
| Workflow slash only | `.cursor/commands/*.md`                         | On `/name`                    | `.cursor/commands/` (`.claude/commands` → here)              |
| Topic → file        | `.cursor/CODEMAP.md`                            | JIT, when orienting           | that file                                                    |
| Loop architecture   | `plans/agent-loops.md`                          | JIT, and by every loop job    | that file                                                    |

Symlinks (edit the **target**, never the link): `.claude/commands` → `.cursor/commands`,
`.claude/rules` → `.cursor/rules`, `.claude/skills` → `.agents/skills`. Skills are **not** under
`.cursor/` — the app's own Chat, Cursor and Claude Code all read `.agents/skills/` directly.

**A skill directory name is a public interface.** `scripts/*-job.sh` and
`scripts/implementer/run-implementer.sh` resolve `.agents/skills/<name>/SKILL.md` by name and
fail on a missing directory, so renaming one breaks its launchd job. Currently load-bearing:
`review-agent-loops`, `review-growth`, `analyze-user-interactions`, `implement-proposal`,
`analyze-chat-freeze`. Rename one → update the script, re-run its `install-*.sh`.

Keep portable frontmatter (`name`, `description`) only. Cursor-only extras (`paths`, `icon`) are
ignored by Claude and fine; Claude-only extras (`when_to_use`, `argument-hint`,
`disallowed-tools`, `context: fork`, `$ARGUMENTS`, bang-backtick injection) are **not** — the same
file serves both tools. Spec: [agentskills.io/specification](https://agentskills.io/specification).

# Slash Commands and Skills — Naming Convention

Every slash command follows **`{verb}-{topic}`**. The verb tells the agent _what kind of work_ to do; the topic names the domain. Workflow-style commands (one-off operational entry points) may omit the verb prefix.

## Commands and skills are the same namespace

Claude Code merged custom commands into skills: `.claude/commands/x.md` and
`.claude/skills/x/SKILL.md` **both register `/x`, and the skill wins**. A file that exists in both
places is therefore dead — its unique sections silently never load. Cursor treats them as one
namespace too (`/migrate-to-skills` converts a command into a skill with
`disable-model-invocation: true`).

So the rule in this repo is: **one name, one file.**

- A slash command whose procedure is worth reusing → `.agents/skills/<name>/SKILL.md`, and **no**
  command file.
- A slash command with no reusable procedure → `.cursor/commands/<name>.md`, and **no** skill.
- Never both. The collision check in the **audit-llm-context** skill (cross-cutting check 6) exists
  to catch regressions here; six such collisions were folded and removed on 2026-08-05.

## Verbs

| Verb            | Use when                                                                  | Output                                                        |
| --------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------- |
| **`audit-*`**   | Systematic quality pass over a bounded corpus (model lineups, LLM-context files, logs, heuristics) | Tiered checklist, false pos/neg, coverage gaps                |
| **`analyze-*`** | Diagnose a symptom — _why_ / _where_ / _how much drift_                   | Root cause + concrete fix                                     |
| **`review-*`**  | Qualitative assessment (code, UI, commits)                                | Positives, concerns, suggestions — no file edits unless asked |
| **`report-*`**  | Counts and lists only                                                     | Numbers, lists — minimal recommendations                      |
| **`validate-*`** | End-to-end sanity check that a specific behavior is wired up correctly    | Pass/fail per checkpoint, with log/file evidence              |
| **`improve-*`** | Turn observed friction into durable edits to the context corpus itself     | Proposed additions/edits to rules, skills, commands           |
| _(workflow)_    | Meta / one-off operational entry points                                    | Side-effect (release cut, version bump, etc.)                 |

## Inventory — defined as skills (`.agents/skills/<name>/SKILL.md`)

Each is invocable as `/<name>` **and** auto-invoked when its `description:` matches the user's intent.

| Skill / slash command                                | Verb     | Role                                       |
| ---------------------------------------------------- | -------- | ------------------------------------------ |
| `/audit-llm-context [--scope=…] [--fix-tier-1] [--no-subagents]` | audit | Staleness/drift pass over the context corpus |
| `/analyze-user-interactions [--mode …] [--since …] [--model …]` | analyze | Mine usage JSONL for systematic failures |
| `/analyze-chat-freeze [--file …] [--since …]`        | analyze  | Triage a main-thread hang capture          |
| `/review-refactors [target]`                         | review   | Deep structural simplification + ledger    |
| `/review-llm-state-of-the-art`                       | review   | LLM architecture vs current provider practice |
| `/validate-audio-verification`                       | validate | Smart Improvement audio path, end to end   |
| `/run-whisper-shortcut`                              | workflow | Build / launch / drive / screenshot via `driver.sh` |
| `/view-logs-via-bash`                                | workflow | Run `bash scripts/logs.sh` for log queries |
| `/debugging-workflow`                                | workflow | `DebugLogger` instrumentation + repro plan |
| `/push-after-rebuild`                                | workflow | Rebuild, then commit + push                |
| `/llm-model-docs`                                    | workflow | Canonical provider doc pointers + lineup check |
| `/gemini-system-prompt-best-practices`               | workflow | Google prompt guidance for `systemInstruction` |
| `/review-growth`                                     | review   | App Store / GitHub growth bottleneck + ledger |
| `/review-agent-loops`                                | review   | Meta-loop over usage/model/growth/implementer |
| `/implement-proposal`                                | workflow | Headless BUILD playbook (not for interactive use) |

## Inventory — defined as commands (`.cursor/commands/<name>.md`)

No paired skill: the playbook is inline because nothing else reuses it.

| Command                                              | Verb     | Supporting skill (different name) |
| ---------------------------------------------------- | -------- | --------------------------------- |
| `/audit-llm-models [--provider …] [--role …] [--coverage] migrate` | audit | `llm-model-docs` |
| `/review-code [N]`                                   | review   | —                                 |
| `/competitor-teardown <name\|URL>`                   | workflow | —                                 |
| `/improve-context`                                   | improve  | —                                 |
| `/release`                                           | workflow | —                                 |
| `/submit-appstore`                                   | workflow | `app-store-connect` (parent repo) |

Note: the rebuild rule lives in `.cursor/rules/index.mdc` with `alwaysApply: true`, so this submodule needs no `rebuild-after-change` skill. The **parent** repo has one for cross-repo work.

## Rules for new commands

1. **Pick the verb first** — don't default everything to `analyze-`. If the work produces a qualitative judgment, it's `review-*`. If it produces an end-to-end pass/fail wired-up check, it's `validate-*`. If it walks a fixed corpus systematically, it's `audit-*`. If it diagnoses a symptom, it's `analyze-*`.
2. **One name, one file — never a command and a skill with the same name** (see "Commands and skills are the same namespace" above; the duplicate is unreachable). Default to a **skill**: write the whole playbook in `.agents/skills/<name>/SKILL.md`, with no command file. Use a **command** file instead only when the procedure has no reusable sub-part and nothing else will ever call it — `/release`, `/review-code`, `/audit-llm-models`. Size is not the criterion; reuse is. A command may still *reference* a differently-named skill (`/audit-llm-models` → `llm-model-docs`).
3. **Cross-link sibling commands by slash name** (`/audit-llm-context`), not file path — links survive moves.
4. **`.claude/commands` → `.cursor/commands`, `.claude/skills` → `.agents/skills`** — only edit the targets. Touching `.claude/...` directly will silently break the next time the symlinks are recreated.
5. **Reference scripts, not steps.** If `scripts/logs.sh` or `scripts/rebuild-and-restart.sh` already does the work, the skill should call the script — don't restate the steps.
6. **Verify before recommending.** Skills that name a Swift type, model ID, or file path are making a claim the codebase should currently satisfy. Run `grep -n` / `Read` before relying on the claim in a fresh audit.

## Renamed (2026-05-24)

| Old                      | New                  | Reason                                                                                  |
| ------------------------ | -------------------- | --------------------------------------------------------------------------------------- |
| `analyze-code-quality`   | `review-code`        | Output is a qualitative judgment, not a symptom diagnosis — fits `review-*`.            |
| `analyze-llm-models`     | `audit-llm-models`   | Systematic pass over a bounded corpus (model lineups) + recommendation — fits `audit-*`. |
| `new-release`            | `release`            | Workflow command; verb prefix not meaningful here.                                      |

## Folded into skills (2026-08-05)

Claude Code's commands-are-skills merge made these command files unreachable — the same-named skill
won `/name`. Their unique sections were folded into the skill and the command files deleted:
`analyze-chat-freeze`, `analyze-user-interactions`, `audit-llm-context`,
`review-llm-state-of-the-art`, `review-refactors`, `validate-audio-verification`.

---
name: audit-llm-context
description: Systematically reviews all LLM-context files (.cursor/commands/, .cursor/rules/, .cursor/skills/) for stale references, factual drift vs the current codebase, redundancy, and files that no longer earn their slot. Produces a tiered report.
---

# Audit LLM-Context Files

Run a thorough review of every markdown file that gets loaded into LLM prompts: cursor commands, cursor rules, and cursor skills (symlinked into `.claude/skills/`). This repo's project-wide rule lives in `.cursor/rules/index.mdc` (`alwaysApply: true`); the root `CLAUDE.md` just `@`-includes it. Goal: find files that have silently rotted (broken references, function pointers at wrong lines, factual drift, redundancy across files).

See the full method in `.cursor/skills/audit-llm-context/SKILL.md` — that is the canonical playbook. This command is the user-facing entry point.

## Quick scope

By default, audit everything in the repo's prompt-context surface:

- `.cursor/commands/*.md`
- `.cursor/rules/*.mdc`
- `.cursor/skills/*/SKILL.md` (same as `.claude/skills/` — symlinked in this repo)

Accept these flags:

- `--scope=commands|rules|skills` — narrow to one group.
- `--fix-tier-1` — after the audit, auto-apply only Tier 1 (broken / actively misleading). Never auto-apply Tier 2 or Tier 3 without explicit confirmation.
- `--no-subagents` — run inline instead of dispatching parallel subagents (only useful with a narrow `--scope=`).

## How to run

Follow the method in the skill file:

1. Dispatch parallel subagents if your tool supports them (Claude Code: `Agent` tool with `subagent_type: general-purpose`; in Cursor, sequence them), one per group: commands, rules, skills. Each agent reads its files, spot-verifies claims against the codebase, and reports per-file findings with severity tags + cited `file:line`.
2. While they run, the orchestrator does the **cross-cutting checks** that need a global view: redundancy between `.cursor/rules/index.mdc` and `.cursor/skills/`, skill ↔ bash-script overlap, symlink integrity between `.cursor/skills/` and `.claude/skills/`, naming-convention adherence vs `.cursor/commands/README.md`.
3. Synthesize one tiered report (Tier 1 broken / Tier 2 dedup wins / Tier 3 hygiene) with concrete fixes.
4. End by asking the user which tier to apply.

## Constraints

- Suggestions only by default. Do not edit files unless the user says "fix" or "apply" (or `--fix-tier-1` was passed).
- Be strict on severity. Most files are fine. Don't pad with ⚪ findings to look thorough.
- Verify subagent claims with `grep -n` / `Read` before reporting them — they hallucinate line numbers sometimes.

## Related

- **`/review-code`** — same review pattern but for app source code, not LLM-context files.
- **`.cursor/commands/README.md`** — verb taxonomy + command/skill inventory used by the cross-cutting naming check.

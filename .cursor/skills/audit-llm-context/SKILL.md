---
name: audit-llm-context
description: Systematically reviews all LLM-context files in this repo (.cursor/commands/, .cursor/rules/, .cursor/skills/) for stale references, factual drift vs the current codebase, redundancy across files, and files that no longer earn their slot. Produces a tiered report (broken / drift / dedup / hygiene). Use when the user asks to audit, review, check, or validate LLM-context files, cursor rules, claude skills, prompt files, or "are these instructions still correct".
---

# Audit LLM-Context Files

Goal: tell the user which LLM-context files are stale, redundant, or load-bearing-but-broken — concrete `file:line` citations, no nitpicks. Skills, commands, and rules drift silently because nothing fails when they go wrong; they just mislead the next LLM.

## Step 0 — Refresh the format specs before auditing (MANDATORY)

The Skills/Rules/Commands ecosystem moves fast (new frontmatter fields, deprecations, format consolidations). Auditing from memory risks flagging current best practice as "drift" or missing a real deprecation. **Before any other step**, WebFetch these canonical sources and read them in full:

1. **Agent Skills standard** — `https://agentskills.io/home` (the open spec that both Cursor and Claude follow; defines required vs optional frontmatter).
2. **Claude Code Skills docs** — `https://code.claude.com/docs/en/skills` (Claude-only extensions: `allowed-tools`, `when_to_use`, `argument-hint`, `arguments`, `user-invocable`, `model`, `effort`, `context: fork`, `agent`, `hooks`, `shell`, plus dynamic shell injection `!<cmd>` at line-start). Note: `disable-model-invocation` and `paths` were once Claude-only but are now portable — Cursor supports both. Do not flag them as Claude-only.
3. **Cursor Skills docs** — `https://cursor.com/docs/skills` (Cursor-specific behavior: `.cursor/skills/` vs `.agents/skills/`, `paths` glob restriction, `/migrate-to-skills`).

Also re-read locally:

- `.cursor/rules/*.mdc` frontmatter (`alwaysApply`, `globs`, `description`) — these are Cursor-only and have no Claude equivalent.
- `.cursor/rules/index.mdc` for project-specific conventions (rebuild rule, slash-command-only policy, English-only UI strings, data directory paths). This is the always-applied repo rule — the root `CLAUDE.md` just `@`-includes it.
- `.cursor/commands/README.md` for the verb taxonomy this repo follows.

**From the fetched docs, extract and pin in working memory:**

- The current list of standard (portable) frontmatter fields vs vendor-specific ones.
- Any newly deprecated fields or renamed conventions.
- The canonical recommended location(s) for skills, commands, rules in each tool.

Then proceed to the audit. Findings about "Claude-only feature in a portable skill" or "stale convention" must cite the fetched doc, not prior knowledge.

## Scope

**Always review:**

- `.cursor/commands/*.md` — Cursor slash commands (naming convention in `.cursor/commands/README.md`).
- `.cursor/rules/*.mdc` — Cursor project rules (`.cursor/rules/index.mdc` with `alwaysApply: true` is the project's repo-level rule; the root `CLAUDE.md` just `@`-includes it).
- `.cursor/skills/*/SKILL.md` — Skill playbooks. (`.claude/skills` is a symlink to `../.cursor/skills`, so one edit propagates to both surfaces.)

**If the user gives a `--scope` flag**, narrow accordingly (e.g. `--scope=skills`, `--scope=rules`, `--scope=commands`).

## Method

Dispatch **parallel subagents** if your tool supports them (Claude Code: `Agent` tool with `subagent_type: general-purpose`; in Cursor, sequence the per-group reviews instead since Cursor has no equivalent dispatcher). If the user passed `--no-subagents`, skip dispatch entirely and run the per-group reviews inline in the main context (useful with a narrow `--scope=`). One reviewer per group: commands, rules, skills. The orchestrator (this skill) then synthesizes a cross-cutting view. Why parallel: reading every file in the main context bloats it and slows synthesis; per-group reviews fit comfortably in a single subagent.

**Each subagent must receive the fetched-doc summary from Step 0** in its prompt — otherwise it will fall back on potentially stale training data when judging frontmatter and conventions.

For each subagent, instruct it to:

1. **Read every file in its group fully.**
2. **Verify** at least 3 spot-claims per file against the actual codebase:
   - Referenced file paths exist (`ls`, `Read`).
   - Referenced functions / symbols exist (`grep -n` — function names are stable, line numbers aren't, so cite names).
   - Referenced bash scripts exist (e.g. `scripts/logs.sh`, `scripts/rebuild-and-restart.sh`, `scripts/test-*-models.sh`).
   - Referenced env vars / Swift types / UserDefaults keys / model IDs match reality (this repo is Swift, so `grep` in `WhisperShortcut/`).
3. **Cross-check vs `.cursor/rules/index.mdc`** — flag content restated with different wording (drift risk).
4. **Output format:** per-file findings with `[severity]` tag (🔴/🟠/🟡/⚪) and `file:line` citation, plus a final redundancy map and top-N recommendations.

Be strict about severity:

- 🔴 **critical** — broken reference, factually wrong, will send the LLM down a wrong path.
- 🟠 **high** — significant drift, large duplication, file likely misleading.
- 🟡 **medium** — readability, partial overlap, minor staleness.
- ⚪ **low** — nitpick. Most things should NOT be 🔴.

## Synthesis

After all subagents finish, produce a single tiered report:

### Tier 1 — Broken / actively misleading (fix today)

- Dead file references (point to files that don't exist).
- Function / symbol pointers at wrong file or wrong name.
- Frontmatter `name:` ≠ filename.
- Stale model IDs (a `current` model the audit knows is retired — cross-check with the **llm-model-docs** skill / `scripts/test-*-models.sh`).
- Stale pinned versions / dates.

### Tier 2 — Real de-dup wins

- Pairs/groups of files that share large blocks of content. Cite the duplicated lines.
- "Two files for one concern" — e.g. two skills doing essentially the same job, or a skill that just restates an inline `.cursor/rules/index.mdc` rule.
- Skills that shadow an existing bash script in `scripts/` (the script is the source of truth; the skill should call it, not duplicate the steps).

### Tier 3 — Hygiene

- Line numbers cited in skills/commands (function names are stable, line numbers aren't — recommend replacement).
- Trivial overview files that just repeat what `.cursor/rules/index.mdc` already says.
- Cross-tool references that won't resolve (e.g. Cursor command referencing Claude-Code-specific tools).
- Tool-naming mismatches (`.cursor/skills/...` vs `.claude/skills/...` — pick one and stick with it).
- Verb-prefix mismatches vs `.cursor/commands/README.md` (e.g. an `analyze-*` command that's actually a `review-*`).

For each finding, include: **file:line**, **what's wrong**, **proposed fix** (concrete).

## Cross-cutting checks (do these in synthesis, not per-subagent)

These need a view across all three groups, so the orchestrator runs them after the subagents return:

1. **Single-source-of-truth check** — for top-level project facts (state machine in `AppState.swift`, `DebugLogger`-only logging, rebuild script, slash-command-only convention, English-only UI, sandboxed data directory): does any `.cursor/skills/*/SKILL.md` restate something already in `.cursor/rules/index.mdc`? The cursor rule has `alwaysApply: true` so it fires every session; a skill that just restates it is dead weight. Either delete the skill or shrink it to a 5-line pointer.
2. **Skill ↔ bash-script overlap** — for each skill, grep its `SKILL.md` for `bash scripts/` and check whether the same logic is already in a script (e.g. `scripts/logs.sh`, `scripts/rebuild-and-restart.sh`, `scripts/test-{gemini,openai,grok}-models.sh`). The skill should call the script, not duplicate its steps.
3. **Symlink integrity for skills** — `.claude/skills` should resolve to the same content as `.cursor/skills`. Run `ls -la .claude/skills` to confirm it is a symlink to `../.cursor/skills` (current setup). If it ever becomes a separate directory (no symlink), the two trees can drift silently — flag this immediately.
4. **Portability check vs Step 0 fetched docs** — for every skill under `.cursor/skills/`, check whether its frontmatter or body uses Claude-only features (per the freshly fetched Claude Code docs): `allowed-tools`, `when_to_use`, `argument-hint`, `arguments`, `user-invocable`, `model`, `effort`, `context: fork`, `agent`, `hooks`, `shell`, or dynamic injection `!<cmd>` syntax in the body. (Do NOT flag `disable-model-invocation` or `paths` — both are now Cursor-supported too.) Since `.claude/skills` is a symlink to `.cursor/skills`, Claude-only features make the skill silently misbehave in Cursor. Flag each occurrence with the exact field/syntax and recommend either (a) moving the skill to a Claude-only location or (b) rewriting to use standard fields.
5. **Verb-taxonomy adherence** — compare every `.cursor/commands/*.md` filename against the verb table in `.cursor/commands/README.md`. Flag mismatches (e.g. `analyze-*` that is really a `review-*` because it produces qualitative judgments, or a command without a verb prefix that isn't a workflow). The README inventory should also match the actual file list — flag stale entries.
6. **Skill ↔ command pairing** — every command file should either (a) have a same-named skill at `.cursor/skills/<command>/SKILL.md` for non-trivial commands, or (b) be a stand-alone simple command. Flag commands that say "see the skill" but have no skill, and skills that look user-triggered but have no corresponding command.

## Constraints

- **Suggestions only by default.** Do not edit files unless the user explicitly says "fix" or "apply".
- **Be strict.** Most files are fine. Don't pad the report with ⚪ findings to look thorough.
- **Trust but verify subagents.** If a subagent claims "function X is at line N," confirm with a quick `grep -n` before relying on it.
- **Dispatch in parallel where possible.** In Claude Code, use the `Agent` tool with `subagent_type: general-purpose`. In Cursor (no subagent dispatcher), run the per-group reviews sequentially.

## Output skeleton

```
# LLM-Context Audit

## Tier 1 — broken / misleading
| File | Line | Issue | Fix |
|---|---|---|---|
| ... | ... | ... | ... |

## Tier 2 — de-dup wins
- file A ↔ file B: <what overlaps>, recommendation

## Tier 3 — hygiene
- ...

## Cross-cutting findings
- Single-source-of-truth: ...
- Symlink integrity: ...
- Verb-taxonomy: ...

## Recommended order to fix
1. ...
2. ...
```

End with a one-line ask: "Want me to apply Tier 1 now? Tier 2 needs decisions on consolidation strategy."

## Example invocations

- `/audit-llm-context` — full audit.
- `/audit-llm-context --scope=skills` — only `.cursor/skills/`.
- `/audit-llm-context --scope=rules` — only `.cursor/rules/`.
- `/audit-llm-context --scope=commands` — only `.cursor/commands/`.
- `/audit-llm-context --fix-tier-1` — audit then auto-apply only Tier 1 fixes (broken refs).
- `/audit-llm-context --no-subagents` — run the per-group reviews inline instead of dispatching subagents (best with a narrow `--scope=`).

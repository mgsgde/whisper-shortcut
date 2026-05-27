---
name: improve-context
description: Reviews the current conversation to find moments where the LLM was confused, missing information, going down wrong paths, or being corrected by the user — then proposes concise, durable edits to context files (.cursor/rules/, .cursor/skills/, .cursor/commands/) so future sessions don't hit the same friction without bloating context.
---

# Improve LLM Context From This Session

Goal: turn the friction in **this conversation** into durable, compact improvements in the repo's LLM-context files, so the next session is less confused without making context files noisy.

This is a post-hoc retro. The conversation may have been productive overall — but somewhere the LLM probably guessed wrong, missed a convention, was told "no, do it differently", read files it didn't need to, or asked the user for something that should have been documented. Capture those and patch the context.

## Method

### Step 1 — Scan the conversation for friction signals

Look back through the **current conversation** (user messages + your own tool calls and replies) for any of these signals. Be specific — cite the actual moment.

- **User corrections** — "no", "stop", "don't do that", "wrong file", "use X instead", "we don't do it that way here". These are the strongest signal.
- **User had to supply info that should have been discoverable** — e.g. "logs are in `scripts/logs.sh`", "rebuild with `bash scripts/rebuild-and-restart.sh`", "AppState is the only state machine", "slash commands are typed in chat, not hotkeys".
- **Wrong assumptions you made** — picked the wrong Swift file, wrong service (`SpeechService` vs `MenuBarController`), wrong model ID, wrong data directory, wrong convention. Bonus if you only discovered the mistake after reading several files under `WhisperShortcut/`.
- **Excessive exploration** — you ran 5+ greps / Reads to find something a one-line pointer in `.cursor/rules/index.mdc` or an existing skill could have given you instantly.
- **Repeated questions** — you asked the user for the same kind of context you'll likely need again next time (e.g. "where do logs go?", "which rebuild script?", "Gemini or Grok for this path?").
- **Skill / command misses** — the user described a workflow that should have been a skill but wasn't; or an existing skill was outdated and led you astray (e.g. skipped **view-logs-via-bash**, **debugging-workflow**, or **llm-model-docs** when they applied).
- **Architecture confusion** — manipulated UI flags instead of transitioning via `AppState`, added hotkeys for chat commands, used `print()` instead of `DebugLogger`, or edited `.claude/skills/` instead of `.cursor/skills/`.

Skip:

- Ephemeral details about the specific task ("we fixed bug X today") — those belong in the commit, not in LLM context.
- Special cases, edge cases, or one-off preferences unless they reveal a reusable rule that will likely prevent future friction.
- Things already documented in `.cursor/rules/index.mdc`, `.cursor/rules/*.mdc`, or an existing skill (verify with `Read` / `grep` before claiming a gap exists).
- Your own minor inefficiencies that won't recur (one-off typos, etc.).

### Step 2 — Classify each finding by destination

For each friction point, decide **where** the fix belongs. Use the table below — pick the **narrowest** scope that fits.

| Type of knowledge                                              | Goes in                                                         |
| -------------------------------------------------------------- | --------------------------------------------------------------- |
| Repo-wide convention, architecture invariant, "always do X"    | `.cursor/rules/index.mdc` **(last resort — see budget rule below)** |
| Cursor-specific rule (glob-scoped, not every session)          | `.cursor/rules/*.mdc` (new file only if `index.mdc` is wrong scope) |
| Repeatable workflow / procedure (multi-step, run on demand)    | new or existing `.cursor/skills/*/SKILL.md`                     |
| User-facing entrypoint that maps to a skill                    | `.cursor/commands/*.md` (see [README.md](README.md) for `{verb}-{topic}` naming) |
| Multi-step implementation specs (not prompt context)           | `plans/` — only when the gap is "where does the plan live?", not for session friction |
| Public-facing or contributor docs                              | root `README.md` (only if the gap is broad enough)              |

**There is no `CLAUDE.md` in this repo.** The always-applied project rule is `.cursor/rules/index.mdc` (`alwaysApply: true`) — every line there loads in every session. Default destination for a new fact is an on-demand skill or a glob-scoped rule. Only add to `index.mdc` if the rule is needed in _every_ conversation and can't live as a skill.

Heuristics:

- If it's "one fact" → add a line to `index.mdc` or an existing skill/rule. Don't create a new top-level file.
- If it's "a multi-step playbook" → it's a skill, not a rule. Pair with a thin `.cursor/commands/*.md` entrypoint if users will invoke it often (see `.cursor/commands/README.md`).
- If two existing files both kind of cover it but neither nails it → update the better-fitting one rather than splitting further.
- Avoid creating new context files. Prefer editing existing skills, rules, or `index.mdc`.
- Prefer replacing or tightening existing wording over appending new bullets. If a new note only makes sense with the details of today's task, skip it.
- Keep proposed additions short: usually 1–3 bullets or a short paragraph. A longer edit must replace existing verbosity or describe a genuinely repeatable workflow.
- Edit only under `.cursor/` — `.claude/skills` and `.claude/commands` are symlinks to `.cursor/`; one edit propagates to both.

### Step 2.5 — Apply the context budget

Before keeping a finding, ask whether the proposed context will pay for the tokens it adds:

- **Frequency:** Will this likely recur across future sessions, not just this one?
- **Generality:** Can it be phrased as a stable convention, location, command, or workflow rather than a narrow anecdote?
- **Compression:** Can it be merged into an existing sentence, bullet, or skill instead of adding a new section?
- **Removal tradeoff:** If the target file is already long, can you replace stale or weaker guidance instead of only adding more?
- **Actionability:** Will the next agent know exactly what to do differently from the text alone?

Drop the finding if the answer is weak. The best outcome is often "no edit needed."

### Step 3 — Verify before proposing

Before writing the report, **verify each gap is real**:

- `grep -n` the relevant keyword in `.cursor/rules/`, `.cursor/skills/*/SKILL.md`, and `.cursor/commands/` to make sure the info isn't already there in different words.
- Spot-check Swift claims against `WhisperShortcut/` (types, file paths, UserDefaults keys, model IDs).
- If you're proposing to add it to a specific file, `Read` that file first to find the right insertion point and match its tone.
- If you're proposing a new skill or command, check no existing one already covers it (`ls .cursor/skills/`, `ls .cursor/commands/`, `.cursor/commands/README.md` inventory).

Drop any finding where the info is already documented. Be honest — a session with no real gaps should produce an empty report, not padded suggestions.

### Step 4 — Produce the report

For each surviving finding, output a block like:

```
### Finding N — <one-line description>

**Friction moment:** <what happened in the conversation — quote/paraphrase briefly>

**Why it matters next time:** <will this recur? for whom?>

**Proposed edit:**
- File: `<absolute or repo-relative path>`
- Action: <append / replace / create>
- Content:
```

<exact text to add, in the file's existing style>

```

```

Group findings by destination file when there are several for the same file.

### Step 5 — Ask the user, per finding

After the report, ask the user **which findings to apply** (e.g. "apply 1, 3, 5" or "apply all" or "skip"). Do NOT apply anything before this confirmation.

When applying:

- Use `Edit` for additions to existing files; `Write` only for genuinely new skill/command files.
- For new skills, create `.cursor/skills/<name>/SKILL.md` (and a matching `.cursor/commands/<name>.md` entrypoint if users will invoke it via slash command).
- After applying, briefly confirm what was changed (file paths, one-line summary).
- Then nudge the user: `/improve-context` is additive-biased. Recommend running **`/audit-llm-context`** periodically (every ~10 cycles or ~3–4 weeks) to compensate — it's the pruning counterpart that catches stale and bloated context.

## Constraints

- **Suggestions first, edits second.** Never edit context files until the user confirms which findings to apply.
- **Be strict.** Most conversations have 0–3 real findings, not 10. If you can't cite a specific moment in the conversation, don't include it.
- **Don't pad.** Skip "low-severity" hygiene observations unless asked. The point is to fix friction, not to redesign the context system.
- **Keep context lean.** Do not add special-case instructions, long examples, or session-specific detail unless they replace broader confusion with a shorter durable rule.
- **No meta-process docs.** Don't add findings like "the LLM should always be careful about X" — write the actual rule, in the actual file.
- **Match existing tone.** New text in `index.mdc` should read like the rest of `index.mdc`; new rules should match `.cursor/rules/*.mdc` style; new skills should follow the format of existing ones (frontmatter, `Goal` / `Method` sections).
- **Respect language conventions.** User-facing product copy is English (per `.cursor/rules/index.mdc`). LLM-context files may be English for consistency; match the tone of the target file.

## Related

- **`/audit-llm-context`** — pruning counterpart; tiered audit of commands, rules, and skills for drift and redundancy.
- **`.cursor/commands/README.md`** — verb taxonomy and command/skill inventory when proposing new entrypoints.

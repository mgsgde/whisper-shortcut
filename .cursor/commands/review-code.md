---
name: review-code
description: Systematically scrutinise recently changed code for bugs AND opportunities to make it simpler and more elegant. Scope is auto-detected from recent git activity. Run `/review-code` for a single pass, or `/review-code N` for N review → fix → rebuild cycles.
---

# Review Code

Continuously keep this codebase healthy. Every invocation does two things in equal measure:

1. **Hunt for bugs and regressions** — especially anything introduced or touched by recent diffs.
2. **Find simplification opportunities** — duplicated code, dead code, unused parameters, over-engineered abstractions, helpers that obscure their only caller, two near-identical implementations that should be one.

A review that surfaces only bugs is incomplete. A review that surfaces only style polish is incomplete. Both must be on the table every time.

## How to invoke

There are exactly two forms — nothing else:

- **`/review-code`** — one review pass. Auto-detects scope from recent git activity. **Suggestions only, no file edits.** The user opts in to changes by replying "fix" / "fix all".
- **`/review-code N`** — N full **review → fix → rebuild** cycles. Each cycle automatically applies its findings (as if the user said "fix all") and rebuilds, then advances to a wider time window for the next cycle.

Do **not** accept any flags (`--path`, `--since`, `--whole-repo`, `--iterations`, …). They were removed deliberately to keep the command frictionless. If the user wants a different scope, they should `cd` mentally into a topic via the chat and ask plainly — don't reintroduce flag parsing.

## Scope resolution

Run `git log --oneline --name-only --since="<window>"` for the cycle's window (see schedule below). Aggregate changed paths, then pick the **top 1–2 files/directories** by change volume.

- If changes are spread too evenly to pick a clear winner, print the top candidates and **ask the user to pick**. Don't silently guess.
- In iteration mode (cycle ≥ 2), if the top candidate was already reviewed in an earlier cycle of this run, drop to the **next-most-changed** unreviewed file so each pass targets fresh ground.
- If the window returns nothing changed, widen one step at a time until you have something to look at.

### Time window per cycle

| Cycle | `git log --since=…` |
|-------|---------------------|
| 1     | last 24 hours       |
| 2     | last 3 days         |
| 3     | last 1 week         |
| 4     | last 2 weeks        |
| 5+    | last 4 weeks (cap)  |

Single-pass `/review-code` uses cycle 1's window. Overlap across cycles is expected and fine — see "Overlap and re-review" below.

## What the review looks for

### Correctness & risk

- Bugs and regressions in recent diffs (`[diff]` issues)
- Concurrency hazards, race conditions, missing cancellation
- Error-handling gaps, silently swallowed errors, wrong error types surfacing to the user
- Edge cases in parsers, data access, public APIs
- Breaking changes that aren't reflected at callers
- Performance hotspots only when there's evidence they matter

### Simplification & elegance

- Duplicate code / two near-identical implementations → collapse into one
- Dead code, unreachable branches, unused enum cases / fields / parameters → delete
- Helpers called from one place that obscure the call site → inline
- Over-engineered abstractions (protocols/types whose only job is to forward) → remove the layer
- State that's redundant with other state → drop one
- Comments that just narrate the code → delete (per project rule)

Treat the simplification pass as **mandatory**, not optional flavor. Even healthy code usually has *something* worth removing.

## Per-cycle flow

1. **Print "Detected scope"** — cycle number (when N > 1), time window, commit count, top changed files. The user should be able to cancel before you continue.
2. **Orient broadly within scope** — read changed files *and* their neighbors, entry points, and relevant tests so findings are grounded in context. Don't review a file in isolation.
3. **Use project rules** — reference `@.cursor/rules/index.mdc` where relevant (logging via `DebugLogger`, KISS, English-only user-facing text, main-thread UI, etc.).
4. **Risk-based deep dive** — prioritize auth, data access, public APIs, parsers, concurrency, error paths, and recently churned hot spots. Don't line-by-line every file.
5. **Extra attention to recent diffs** — scrutinize the actual changes for regression risk and inconsistencies with surrounding code.
6. **Produce findings** in the format below.
7. **In iteration mode (`/review-code N`)**:
   - Apply all simplification-shaped fixes (as if the user said "fix all" — see fix rules below).
   - Rebuild: `bash scripts/rebuild-and-restart.sh`.
   - If the rebuild fails, **stop the loop** and report — don't advance to the next cycle on a broken build.
   - Otherwise, advance to the next cycle's time window.
8. **In single-pass mode (`/review-code`)**: stop after findings. Do not modify files.

### Overlap and re-review (iteration mode)

Because windows expand, later cycles will re-touch files from earlier cycles. That's expected:

- Issues **already fixed** in a prior cycle of this run → mark **✅ already fixed**; do not re-apply.
- Issues **still open** or **newly visible** in the wider window → report and fix normally.
- Pre-existing `[area]` issues outside the changed diff may surface on a later pass — treat as new findings for that cycle.

## Output format

### Detected scope

File(s)/directory, time window, commit count, top changed files. In iteration mode also include cycle number (e.g. "Cycle 2 / 3").

### Issues found

Group by category: **bugs** / **smells** / **naming & structure** / **complexity** / **error handling** / **performance**.

Tag each issue:

- `[diff]` — introduced or touched by recent changes
- `[area]` — pre-existing in the scope
- `✅ already fixed` — closed in a previous cycle of this run (iteration mode only)

Reference file paths and line numbers so suggestions are verifiable.

### Suggested fixes

Concrete and safe. Propose refactor-shaped fixes when they make the code **simpler today**.

"Simpler today" means the diff **removes complexity**:

- Removes duplicate code, dead code, or redundant state
- Replaces two near-identical implementations with one canonical version
- Drops a parameter, field, enum case, or function with no real users
- Inlines a helper that's only called once and obscures the call site

"Simpler today" does **not** mean adding abstractions for hypothetical flexibility:

- Adding a new protocol/interface that wraps existing concrete code
- Introducing a new file/type whose only job is to forward to another type
- Splitting a clear linear function into N tiny helpers when the original reads top-to-bottom
- "Framework-style" extraction that doesn't delete anything

**Size doesn't disqualify a fix.** A 200-line consolidation that nets fewer lines and removes a duplication is legitimate. A 5-line change that adds a new layer without deleting anything is not.

For each fix, briefly say *what it removes* (lines of duplication, a dead enum case, a parameter, etc.) so the user can judge it on the simplification bar.

Include small diff-style snippets where helpful.

## When the user follows up with "fix" / "fix all"

In single-pass mode, if the user replies "fix", "fix all", "apply these", etc., **apply all simplification-shaped fixes** above — including the refactor-shaped ones. Don't pre-filter to "the small ones" or "the safe-looking ones"; the simplification bar already gates them.

Iteration mode (`/review-code N`) behaves as if "fix all" was said after every cycle. Same rules.

Things you may still legitimately defer (call them out explicitly, don't silently skip):

- Pure optimizations (caching, retry parity) — these *add* code for non-functional gains; skip unless requested or measured to matter
- Behavior-changing rewrites unrelated to the reported issue
- Changes that need user input (which of two competing patterns to keep)

After applying fixes:

- Rebuild (`bash scripts/rebuild-and-restart.sh`) before reporting completion
- Do **not** commit unless the user explicitly asks

## Constraints

- Single pass: suggestions only — do not modify files until a "fix" follow-up.
- Iteration mode: apply fixes per cycle, rebuild between cycles. If a rebuild fails, stop the loop.
- Do **not** commit, push, or cut a release. Hold all changes in the working tree and summarise at the end.
- Do NOT run Playwright. This command is code-focused, not UX.
- Do NOT run Xcode tests; the user runs tests manually in Xcode.

## Related commands

- **`/analyze-user-interactions`** — when the user wants improvements based on what they actually experienced (recurring "korrigiere" misbehaving, hallucinations, format drift, etc.), not on static code review. Mines the local interaction JSONL + macOS log and proposes changes at the right level (`[prompt]` / `[default]` / `[code]` / `[logging]` / `[ui]`). Prefer it whenever the user references real usage ("works badly", "is not doing what I want", "find patterns").
- **`/audit-llm-context`** — when the review target is the LLM-context files themselves (`.cursor/commands`, `.cursor/rules`, `.cursor/skills`) rather than app source code.

## Example invocations

- `/review-code` — one review pass, suggestions only. Reply "fix all" to apply.
- `/review-code 3` — three review → fix → rebuild cycles, expanding time window each cycle.

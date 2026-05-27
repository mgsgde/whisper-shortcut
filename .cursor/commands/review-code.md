---
name: review-code
description: Qualitative review of a focused scope of this repo for bugs, smells, and regression risk. Scope is auto-detected from recent git activity unless overridden via flags. Suggestions only by default; "fix" follows up to apply.
---

# Review Code

Qualitative review of a focused scope of this repo for bugs, smells, and regression risk. Scope is auto-detected from recent git activity unless overridden. This is a **review** (suggestions, no edits) by default; the user opts in to fixes with a follow-up.

## Scope resolution

Resolve scope in this order:

1. **Explicit override** — if the user specifies a flag, honor it exactly:
   - `--path <path>` (e.g. `WhisperShortcut/ChatView.swift`, `WhisperShortcut/Settings`, `scripts`) → use that file or directory.
   - `--since <range>` (e.g. `2 weeks`, `10 commits`) → use that window instead of the default.
   - `--whole-repo` → scan the Swift app, scripts, release tooling, and docs.
   - **Iteration count** — a bare integer (`/review-code 3`) or `--iterations N` means run **N full review → fix → rebuild cycles**. Default is 1. See "Iteration mode" below.
2. **Auto-detection (default)** — run `git log --oneline --name-only` for the last ~20 commits or last 14 days (whichever is larger). Aggregate changed paths and pick the **top 1–2 files/directories** by change volume.
3. **Fallback** — if changes are spread evenly (no clear winner), print the top candidates and **ask the user to pick**. Do not silently guess.

## Steps

1. **Print a "Detected scope" block first** — which file(s)/directory, time window, commit count, top changed files. The user should be able to reject the default before you continue.
2. **Orient broadly within scope** — read not only changed files but their neighbors, entry points, and relevant tests so findings are grounded in context.
3. **Use project rules** — reference `@.cursor/rules/index.mdc` where relevant.
4. **Risk-based deep dive** — prioritize: auth, data access, public APIs, parsers, concurrency, error paths, performance hotspots. Not every file line-by-line.
5. **Extra attention to recent diffs** — within the detected scope, review the actual changes for regression risk, new smells, and inconsistencies with surrounding code.

## Iteration mode

When invoked with `/review-code N` (or `--iterations N`):

1. Run the full cycle — auto-detect scope, print "Detected scope", produce findings, apply fixes (as if the user said "fix all"), then `bash scripts/rebuild-and-restart.sh`.
2. Between cycles, **rotate scope to the next-most-changed source file** that hasn't been reviewed in this run. Skip files already reviewed in earlier cycles of the same invocation so each pass targets fresh ground. If the auto-detection would land on a just-reviewed file, drop to the next candidate.
3. Repeat until N cycles are done or no fresh scope remains.
4. Do **not** commit or cut a release between cycles unless the user asked for it explicitly. Hold all changes in the working tree and summarise at the end.

An explicit `--path` combined with an iteration count keeps the same scope but does multiple review/fix passes on it — useful when one big file has more than one cycle's worth of cleanup.

## Output format

### Detected scope

File(s)/directory, time window, commit count, and top changed files.

### Issues found

Group by category: **bugs** / **smells** / **naming & structure** / **complexity** / **error handling** / **performance**.

Tag each issue:

- `[diff]` — introduced or touched by recent changes.
- `[area]` — pre-existing in the scope.

Reference file paths and line numbers so suggestions are verifiable.

### Suggested fixes

Concrete and safe. Don't artificially shrink the scope. If a fix is shaped like a refactor — extracting a duplicated helper, deleting dead code, collapsing two implementations into one, dropping a parameter no caller depends on — propose it whenever it makes the code **simpler today**.

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

**Size doesn't disqualify a fix.** A 200-line consolidation that nets fewer lines and removes a duplication is a legitimate fix. A 5-line change that introduces a new layer without deleting anything is not.

For each fix, briefly say *what it removes* (lines of duplication, a dead enum case, a parameter, etc.) so the user can judge it on the simplification bar.

Include small diff-style snippets where helpful.

## When the user follows up with "fix" / "fix all"

If, in the same session, the user says "fix", "fix all", "apply these", etc., **actually apply all the simplification-shaped fixes** above — including the refactor-shaped ones. Don't pre-filter to "the small ones" or "the safe-looking ones." The simplification bar already gates them.

Things you may still legitimately defer (call them out explicitly, don't silently skip):
- Pure optimizations (caching, retry parity) — these *add* code for non-functional gains; skip unless requested or measured to matter
- Behavior-changing rewrites unrelated to the reported issue
- Changes that need user input (which of two competing patterns to keep)

After applying fixes:
- Rebuild (`bash scripts/rebuild-and-restart.sh`) before reporting completion
- Do **not** commit unless the user explicitly asks

## Constraints

- For the review pass: suggestions only, do not modify files.
- For the follow-up fix pass: see "When the user follows up with 'fix'" above.
- Do NOT run Playwright. This command is code-focused, not UX.
- Do NOT run Xcode tests; the user runs tests manually in Xcode.
- If the user supplies an explicit flag, honor it — do not auto-detect on top.

## Related commands

- **`/analyze-user-interactions`** — when the user wants improvements based on what they actually experienced (recurring "korrigiere" misbehaving, hallucinations, format drift, etc.), not on static code review. That command mines the local interaction JSONL + macOS log and proposes changes at the right level (`[prompt]` / `[default]` / `[code]` / `[logging]` / `[ui]`). Prefer it whenever the user references real usage ("works badly", "is not doing what I want", "find patterns").
- **`/audit-llm-context`** — when the review target is the LLM-context files themselves (`.cursor/commands`, `.cursor/rules`, `.cursor/skills`) rather than app source code.

## Example invocations

- `/review-code` — auto-detect scope from recent commits.
- `/review-code --path WhisperShortcut/ChatView.swift` — review the chat view and nearby collaborators.
- `/review-code --path WhisperShortcut/Settings` — review Settings broadly.
- `/review-code --since "3 weeks"` — widen the detection window.
- `/review-code --whole-repo` — full Swift app and repo tooling scan.
- `/review-code 3` — three review → fix → rebuild cycles, rotating to a fresh top-churn file each time.
- `/review-code --iterations 2 --path WhisperShortcut/MenuBarController.swift` — two passes on the same file.

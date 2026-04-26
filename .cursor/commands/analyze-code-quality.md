# Analyze Code Quality

Analyze a focused scope of this repo for bugs, smells, and regression risk. Scope is auto-detected from recent git activity unless overridden.

## Scope resolution

Resolve scope in this order:

1. **Explicit override** — if the user specifies a flag, honor it exactly:
   - `--app <name>` (e.g. `web`, `crawler`, `messenger`) → use that app directory.
   - `--since <range>` (e.g. `2 weeks`, `10 commits`) → use that window instead of the default.
   - `--whole-repo` → scan all apps and root tooling.
2. **Auto-detection (default)** — run `git log --oneline --name-only` for the last ~20 commits or last 14 days (whichever is larger). Aggregate changed paths and pick the **top 1–2 apps/directories** by change volume.
3. **Fallback** — if changes are spread evenly (no clear winner), print the top candidates and **ask the user to pick**. Do not silently guess.

## Steps

1. **Print a "Detected scope" block first** — which app(s), time window, commit count, top changed files. The user should be able to reject the default before you continue.
2. **Orient broadly within scope** — read not only changed files but their neighbors, entry points, and relevant tests so findings are grounded in context.
3. **Use project rules** — reference `@.cursor/rules/index.mdc` and `@.cursor/rules/architecture.mdc` where relevant.
4. **Risk-based deep dive** — prioritize: auth, data access, public APIs, parsers, concurrency, error paths, performance hotspots. Not every file line-by-line.
5. **Extra attention to recent diffs** — within the detected scope, review the actual changes for regression risk, new smells, and inconsistencies with surrounding code.

## Output format

### Detected scope

App(s), time window, commit count, and top changed files.

### Issues found

Group by category: **bugs** / **smells** / **naming & structure** / **complexity** / **error handling** / **performance**.

Tag each issue:

- `[diff]` — introduced or touched by recent changes.
- `[area]` — pre-existing in the scope.

Reference file paths and line numbers so suggestions are verifiable.

### Suggested fixes

Concrete, minimal, safe. Include small diff-style snippets where helpful.

**Do NOT auto-commit or apply changes** unless the user explicitly asks in the same session.

## Constraints

- Suggestions only. Do not modify files.
- Do NOT run Playwright. This command is code-focused, not UX.
- If the user supplies an explicit flag, honor it — do not auto-detect on top.

## Example invocations

- `analyze-code-quality` — auto-detect scope from recent commits.
- `analyze-code-quality --app web` — analyze `apps/web` broadly.
- `analyze-code-quality --since "3 weeks"` — widen the detection window.
- `analyze-code-quality --whole-repo` — full monorepo scan.

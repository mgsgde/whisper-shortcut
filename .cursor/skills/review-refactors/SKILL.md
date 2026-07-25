---
name: review-refactors
description: Hunt for the mid-to-long-term simplest, most elegant design — deep structural simplifications, not surface cleanups. Explicitly discounts "that's more code / more work to build" as an objection, so it argues for the best long-term shape even when it means large rework. Given no target it triages the repo itself (churn, defect density, size, crusted code, centrality) and picks the highest-payback hotspots. Produces a tiered, blast-radius-tagged proposal list; applies only what the user approves. Use when the user asks where the code could be built simpler/more elegantly/better, wants refactoring opportunities, wants technical debt reduced, or wants duplication removed across files.
---

# Review Refactors

Find where this codebase could be **fundamentally** simpler, more elegant, and better for the
mid-to-long term — then propose it, and apply what the user approves.

The guiding rule: **"it's more code / more work to build" is NOT a valid argument against the
better design.** Implementation cost has collapsed; the only things that count are the _resulting_
design's clarity, safety, and maintainability. Argue for the best long-term shape even when the
rework is large.

This does not contradict the project's KISS rule (`.cursor/rules/index.mdc`) — KISS is about the
_resulting_ design being simple to reason about, not about the diff being small. A 400-line change
that collapses five divergent copies into one tested builder is KISS. A 20-line change that adds a
protocol wrapping one concrete type is not.

## Distinguish from the siblings

- **`/review-code`** — bug hunt + simplification over the _recently changed_ files. Its bar is
  explicitly "simpler **today**, and the diff must delete something". It rejects anything that
  looks like architecture work.
- **`/review-refactors`** (this) — sweeps a whole area for structural simplifications worth real
  rework. May legitimately propose new files, new types, and large diffs, provided the end state
  has fewer places to change and fewer ways to drift.
- **`/audit-llm-context`** — the target is the context files (`.cursor/**`), not app source.
- **`/review-llm-state-of-the-art`** — the target is LLM architecture measured against provider
  best practices, not internal structure.

## Step 0 — Args & scope

- **With a target**: a path, directory, type, or feature area — `WhisperShortcut/Settings/`,
  `LLMChatProvider.swift`, "the TTS chunking path", "the provider implementations". Sweep that area
  plus its neighbors and skip to Step 1.
- **Without a target**: do **not** default to the working diff (that is `/review-code`'s job).
  Instead run the triage below and pick the targets yourself — the places where reducing technical
  debt buys the most.

**Never silently cap the sweep.** Whatever you pick, say what you read and what you skipped, so a
quiet week never reads as "nothing to improve".

### Step 0a — Collect the signals (no-target mode)

Five cheap measurements. Run them all before deciding anything; each one alone is misleading.

```bash
# 1. Churn — where work actually happens. A refactor here pays back every week.
git log --since="6 months ago" --name-only --pretty=format: -- '*.swift' \
  | grep -v '^$' | sort | uniq -c | sort -rn | head -15

# 2. Defect density — where bugs keep landing. The strongest debt signal there is.
git log --since="12 months ago" -i --grep='fix\|bug\|revert\|regress' \
  --name-only --pretty=format: -- '*.swift' \
  | grep -v '^$' | sort | uniq -c | sort -rn | head -12

# 3. Size — god-file candidates.
find WhisperShortcut -name '*.swift' -exec wc -l {} + | sort -rn | sed -n '2,16p'

# 4. Crusted code — large files nobody has touched in months (oldest first).
find WhisperShortcut -name '*.swift' | while read -r f; do
  n=$(wc -l < "$f"); [ "$n" -lt 250 ] && continue
  printf '%s  %5s  %s\n' "$(git log -1 --format=%ad --date=short -- "$f")" "$n" "$f"
done | sort | head -12

# 5. Centrality (tie-breaker only) — how many files reference the types a file declares.
types=$(grep -hoE '^(public |private |internal )?(final )?(class|struct|enum|actor|protocol) [A-Za-z_][A-Za-z0-9_]*' "$FILE" | awk '{print $NF}' | sort -u)
for t in $types; do
  echo "$(grep -rl --include='*.swift' "\b$t\b" WhisperShortcut | grep -v "^$FILE$" | wc -l) $t"
done
```

Swift has no per-file imports, so signal 5 is a rough proxy and the counts in this repo run low —
use it to break ties, never to rank. For "importance", trust the architecture-critical set named in
`.cursor/rules/index.mdc` instead: `AppState`, `MenuBarController`, `SpeechService`,
`LLMChatProvider` / `LLMProviderFactory`, `KeychainManager`, the audio pipeline
(`AudioRecorder`, `AudioChunker`, `AudioMerger`), `ChatToolRegistry`.

### Step 0b — Rank into tiers

The classic hotspot is **high churn × large size** — a file that is both big and constantly edited
is where complexity costs real time. Layer defect density on top and sort into:

- **Tier A — hotspots.** Top-10 churn _and_ top-10 size, or top-5 defect density. Best payback;
  start here.
- **Tier B — crusted.** Large, central, and untouched for months. Either genuinely stable (leave it
  alone) or code people route around because it's scary. Decide which by reading it — if it is
  stable, say so and move on.
- **Tier C — the rest.** Mention only if something specific stands out.

Read the signals honestly, not mechanically:

- **High churn alone is not debt.** It often just means a feature is under active development.
  It counts when paired with size, defect density, or visible duplication.
- **Staleness alone is never a finding.** Small, stable, untouched code is healthy code. Staleness
  only matters combined with size or centrality.
- **Size alone is weak.** A long file of flat, obvious declarations (`AppConstants`,
  `UserDefaultsKeys`) is not a hotspot. A long file of branching logic is.
- The signals are proxies for _where to look_. The finding still has to be a concrete structural
  problem you can point at with `file:line` — never report a ranking as if it were a finding.

### Step 0c — Show the triage, then dive

Print a short table of the shortlist with the numbers behind it (churn / size / fix-count / last
touched) and say which 2–3 targets you picked and why. The user can redirect you before you spend
the effort. Then deep-read those targets and their neighbors.

## Step 1 — Read for real

Read the target files **and their neighbors** — callers, callees, and sibling implementations of
the same concept. Most high-value refactors are invisible from a single file; they live in the
_repetition across_ files. Concretely, grep for:

- the same helper defined more than once (formatters, retry wrappers, JSON extraction, audio
  duration math, temp-file naming);
- the same request/prompt/settings shape hand-assembled in several places;
- two functions that differ only in their data (the `buildGerman`/`buildEnglish` smell — here it
  shows up as per-provider or per-model near-clones).

## Step 2 — Hunt these patterns

Rank candidates by **(long-term value × confidence) ÷ blast radius**. Look for:

1. **Duplicated logic that must change in lockstep** — especially anything security- or
   correctness-critical: Keychain access, API key handling, spend/quota math, error mapping,
   cancellation. N hand-copies are a latent drift bug. Collapse to one source of truth. This is
   almost always the top-priority find.
2. **Clonal implementations / wrong altitude** — two or more near-identical blocks differing only
   in literals or a key. Typical here: per-provider request builders, per-model capability
   branches, per-tab settings scaffolding, duplicated chunking/merging paths. Drive them from one
   skeleton plus a data table (a capability struct, a model table, a parameterized builder).
3. **Missing or leaky seams** — a type reaching across a boundary it shouldn't (a view touching a
   service's internals, a service mutating UI state directly instead of going through `AppState`),
   or inline logic that wants to be a named, testable unit. Extract the seam; keep the _variable_
   part local and share only the _mechanical_ part.
4. **Primitive obsession / stringly-typed** — model IDs, provider names, or prompt roles passed as
   raw `String`s; a shape passed as five loose arguments when a small value type would make illegal
   states unrepresentable.
5. **Dispatch ladders & god-conditionals** — long `if`/`switch` chains selecting a handler where
   the same selector is duplicated in several files. Replace with one table or one factory.
   `LLMProviderFactory` is the shape to converge on, not to duplicate.
6. **Scattered conditional compilation** — `#if APP_STORE` sprinkled across many call sites instead
   of one capability flag or one gated seam. Each extra site is another way the two targets drift.
7. **Inconsistency with the repo's own conventions** — this file does X the hard way while a shared
   helper already exists (`DebugLogger`, `SpeechErrorFormatter`, `AppState` transitions,
   `KeychainManager`). Adopt the existing pattern instead of inventing a parallel one.

Explicitly **do not** reject a candidate because the fix touches a lot of code or is "hard". Do
weigh _blast radius_ — that governs how you roll it out and whether you ask first, not whether the
better design is worth proposing.

## Step 3 — Write each finding

For every candidate capture:

- **Current shape** — what's there now, with `file:line`.
- **Proposed shape** — the target design, concretely: a signature, a type sketch, a small diff.
- **Why it's better long-term** — single source of truth, testability, fewer places to change,
  illegal states unrepresentable. Not "shorter" for its own sake.
- **Blast radius** — exactly one of:
  - **self-contained** — one file or one feature; safe to apply once approved;
  - **cross-file / shared helper** — apply, but name the ripple and the call sites touched;
  - **hot path / risk-sensitive** — `AppState` transitions, the audio recording/chunking pipeline,
    `KeychainManager`, the provider protocol, anything under `#if APP_STORE`, or a widely-imported
    type. Must be behavior-preserving, and scope has to be confirmed with the user first.
- **Effort** — `S` / `M` / `L`, stated but explicitly _not_ used as an argument against the design.

## Step 4 — Present, then decide scope

Report first. The project rule is suggestion-first (`.cursor/rules/index.mdc`): **do not edit files
in the reporting pass.** Show the prioritized, tiered list (most structural first) with a clear
recommendation on what you'd do and in what order.

Then:

- The user replies **"apply"**, **"apply 1 and 3"**, or **"apply all"** → do the work.
- For anything tagged **hot path / risk-sensitive**, use `AskUserQuestion` to confirm scope _before_
  the rework — e.g. "unify across all five providers" vs "only the two new ones". Present the
  blast-radius trade-off honestly.

Never do a silent large refactor of shared or risk-sensitive code without surfacing its reach first.

## Step 5 — Apply: behavior-preserving and verified

Refactors must not change behavior. For each applied change:

1. Keep the _observable_ output identical. When collapsing duplicates, diff the generated artifact
   (request body, prompt text, formatted error string) against the original and confirm equivalence
   — don't eyeball it.
2. Run the build; it is the authoritative check:
   `bash scripts/rebuild-and-restart.sh` (never piped through `tail`/`grep`/`tee`). Ignore transient
   SourceKit errors — only the script's exit status counts.
3. Prefer executing the code over reasoning about it. In order of confidence:
   - drive the affected flow in the real app (skill **run-whisper-shortcut**), then read
     `bash scripts/logs.sh -t 5m`;
   - `bash scripts/run-tests.sh` **only** when the refactor touches the provider / transcription /
     TTS request paths — it makes live, billable API calls, so don't run it as a reflex.
4. New shared helpers on non-trivial logic deserve a test in `WhisperShortcutTests/` — it doubles as
   the equivalence lock against the old copies.
5. Keep comments and naming at the density of the surrounding code. Document _why_ the seam exists,
   never what the line does.
6. Hold everything in the working tree. Do not commit, push, or cut a release unless explicitly told.

## Step 6 — Report

Summarize:

- what was unified or simplified, with before → after (files touched, copies removed, net line delta);
- how equivalence was verified (build status, which flow was driven, which logs/tests were checked);
- what was deferred and why — usually blast radius awaiting a go-ahead. Be explicit; a deferred
  finding that isn't named is a finding that's lost.

## Anti-patterns for this command

Do not propose:

- an abstraction for hypothetical future flexibility that unifies nothing that exists today;
- a new type whose only job is to forward to another type;
- splitting a clear linear function into many tiny helpers that each get one caller;
- renames or reformatting dressed up as refactoring.

The test is always: **after this change, are there fewer places where the same decision has to be
made correctly?** If not, it isn't a refactor worth proposing here.

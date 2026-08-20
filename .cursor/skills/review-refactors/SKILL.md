---
name: review-refactors
description: Hunt for the mid-to-long-term simplest, most elegant design — deep structural simplifications, not surface cleanups. Explicitly discounts "that's more code / more work to build" as an objection, so it argues for the best long-term shape even when it means large rework. Given no target it triages the repo itself (churn, defect density, size, crusted code, centrality) and picks the highest-payback hotspots. Produces a tiered, blast-radius-tagged proposal list; applies only what the user approves. Use when the user asks where the code could be built simpler/more elegantly/better, wants refactoring opportunities, wants technical debt reduced, or wants duplication removed across files. Scope is WhisperShortcut Swift ONLY — for web/ workspace tooling, use the parent review-refactors skill.
---

# Review Refactors

Find where this codebase could be **fundamentally** simpler, more elegant, and better for the
mid-to-long term — then propose it, and apply what the user approves.

**How to invoke:**

- **`/review-refactors`** — no target: triage the repo (churn × size × defect density, minus what
  the ledger already covers) and pick the 2–3 highest-payback areas.
- **`/review-refactors <target>`** — a path, type, or feature area: sweep that plus its neighbors.

Both forms report first and edit nothing until the user approves. They reply `apply`,
`apply R4 and R6`, or `apply all`. Anything tagged **hot path / risk-sensitive** gets a scope
question before the rework.

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

## The ledger — this command is meant to be run again and again

Refactoring a repo is a campaign, not one pass. This command is designed to be invoked repeatedly
over weeks, each run picking up where the last one stopped, so **`plans/refactor-ledger.md` is part
of the command, not an optional nicety**. Without it every run re-triages from zero, re-proposes
findings the user already rejected, and keeps re-reporting the same deferred items as if they were
new.

The ledger is the memory. It records, per finding: a stable ID, what it was, its blast radius, and
its **status** — `applied`, `deferred`, `rejected`, or `superseded` — plus which areas have been
swept and at which commit. It is long-lived: unlike the plans described in `plans/README.md`, it is
**not** deleted when a piece of work finishes, because its value is precisely the accumulated
history. Individual entries get their status updated instead.

Two rules make repeated runs additive rather than repetitive:

- **Read it before you measure anything** (Step 0a) — it changes what you triage.
- **Write it back before you finish** (Step 6) — a run that proposes findings and doesn't record
  them has thrown away the only thing that makes the next run cheaper.

If the file doesn't exist yet, this is run #1: create it in Step 6 with the template at the bottom
of this skill.

## Step 0 — Args & scope

**Always read `plans/refactor-ledger.md` first**, before the triage or the target sweep. It tells
you what is already done, what the user turned down, and what is waiting. Then:

- **With a target**: a path, directory, type, or feature area — `WhisperShortcut/Settings/`,
  `LLMChatProvider.swift`, "the TTS chunking path", "the provider implementations". Sweep that area
  plus its neighbors and skip to Step 1. Check the ledger for entries covering that target and say
  up front what was already applied there, so the user isn't re-sold a finished refactor.
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

### Step 0b2 — Subtract what the ledger already covers

The raw signals do not know about previous runs, so a file you refactored last week still ranks
high on churn (you just changed it) and on size. Reconcile before choosing targets:

- **A swept area is not a target again unless it moved.** For each ledger entry with a swept-at
  commit, check whether the area actually changed since:
  ```bash
  git diff --stat <swept-at-commit>..HEAD -- <path>
  ```
  No meaningful diff → deprioritize; it was read and its findings are recorded. Substantial new
  work → it is fair game again, and say so ("re-sweeping X, ~400 lines changed since the last run").
- **`applied` entries mean the smell is gone.** Do not re-report a collapsed duplication as a fresh
  finding. If it has genuinely regressed — someone added a sixth copy — that is a *new* finding that
  references the old ID, not a re-run of it.
- **`rejected` entries are settled.** Do not re-propose them. Raise one again only if the reason it
  was rejected has changed, and then say explicitly what changed.
- **`deferred` entries are the backlog, and they outrank new discovery.** The point of running this
  command repeatedly is to work *through* the list, not to grow it forever. Carry them into Step 4
  ahead of anything newly found, unless the user asked for something specific.
- **Prefer an unswept neighborhood.** All else equal, pick targets in areas no previous run has
  touched — that is how repeated runs cover the repo systematically instead of circling the same
  three files.

### Step 0c — Show the triage, then dive

Print a short table of the shortlist with the numbers behind it (churn / size / fix-count / last
touched) and say which 2–3 targets you picked and why. The user can redirect you before you spend
the effort. Then deep-read those targets and their neighbors.

Open with one line of continuity so the user knows where this run sits in the campaign — e.g.
"Run #4. Carrying 3 deferred findings; `MenuBarController` / providers already swept; picking up
`Settings/` and the TTS chunking path." On run #1 say that instead: no ledger yet, starting fresh.

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

- **ID** — stable, never reused: `R<n>` continuing from the highest number in the ledger (run #2
  starts at `R9` if the ledger ends at `R8`). The ID is how a later run, a commit message, or the
  user refers to this finding, so it must not shift between runs. Never renumber existing entries.
- **Current shape** — what's there now, with `file:line`.
- **Proposed shape** — the target design, concretely: a signature, a type sketch, a small diff.
- **Why it's better long-term** — single source of truth, testability, fewer places to change,
  illegal states unrepresentable. Not "shorter" for its own sake.
- **Depends on** — other IDs that should land first, where there is a natural order (extract the
  seam before splitting the god object that uses it). This is what lets a later run pick the next
  item off the backlog without re-deriving the sequence.
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

Present the backlog and the new findings as **one** list, each with its ID, not as two disconnected
sections — the user cares about what to do next, not about which run discovered it. Mark carried-over
items so the distinction is still visible (`R4 (deferred, run #2)`). A previously deferred finding
whose blast radius has since shrunk — because a dependency landed — is usually the best next move,
so say that when it applies.

Then:

- The user replies **"apply"**, **"apply 1 and 3"**, or **"apply all"**, or refers to an ID from a
  previous run (**"apply R4"**) → do the work.
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

## Step 6 — Report, then update the ledger

Summarize:

- what was unified or simplified, with before → after (files touched, copies removed, net line delta);
- how equivalence was verified (build status, which flow was driven, which logs/tests were checked);
- what was deferred and why — usually blast radius awaiting a go-ahead. Be explicit; a deferred
  finding that isn't named is a finding that's lost.

**Then write `plans/refactor-ledger.md` — every run, including runs where nothing was applied.** A
run that only proposed still produced the backlog the next run starts from; a run that applied
nothing because the user said no still produced `rejected` entries that stop the next run wasting
effort. Skipping the write-back is the one failure mode that makes this command feel like it has
amnesia.

Record:

- every finding from this run, with its ID and final status — `applied` (with the commit SHA once
  one exists, else "working tree"), `deferred`, or `rejected` (with the reason in the user's terms);
- status changes to entries from earlier runs — a `deferred` item applied this run flips to
  `applied`; a finding a later refactor made moot flips to `superseded` and names the ID that
  replaced it;
- the areas swept this run, each with the `HEAD` SHA at sweep time (`git rev-parse --short HEAD`),
  which is what Step 0b2 diffs against next time;
- areas deliberately **not** swept yet, so the next run has an obvious starting point.

Keep entries one or two lines each. This is an index for future runs, not a second copy of the
report — the reasoning lives in git history and in the conversation.

### Ledger template (run #1 creates this)

```markdown
# Refactor Ledger

Running record for `/review-refactors`. Each run reads this before triaging and updates it at the
end. Long-lived: entries change status, they are not deleted.

## Findings

| ID  | Finding                                          | Blast radius | Status     | Run | Notes                        |
| --- | ------------------------------------------------ | ------------ | ---------- | --- | ---------------------------- |
| R1  | Live-meeting state has no owner (17 flags)       | hot path     | applied    | 1   | 44a83e1 → LiveMeetingSession |
| R3  | ChatViewModel is 9 responsibilities in 2,374 ln  | cross-file   | deferred   | 1   | do after R1 proves the shape |
| R6  | Four independent retry/backoff policies          | cross-file   | deferred   | 1   |                              |

## Swept areas

| Area                        | Last swept | At commit | Notes                                |
| --------------------------- | ---------- | --------- | ------------------------------------ |
| `MenuBarController.swift`   | run 1      | cbfea03   | R1, R4 applied                       |
| chat providers              | run 1      | cbfea03   | R7 applied; already in good shape    |

## Not yet swept

- `Settings/` (1,590-line `SettingsConfiguration` + per-tab views)
- `PopupNotificationWindow.swift`, `ContextDerivation.swift`
- the TTS chunking path
```

## Anti-patterns for this command

Do not propose:

- an abstraction for hypothetical future flexibility that unifies nothing that exists today;
- a new type whose only job is to forward to another type;
- splitting a clear linear function into many tiny helpers that each get one caller;
- renames or reformatting dressed up as refactoring.

And across runs, do not:

- re-triage from scratch and re-propose findings the ledger already records as `applied` or
  `rejected` — that is the amnesia this command is built to avoid;
- renumber IDs, or reuse the ID of a closed finding for something new;
- finish a run without writing the ledger back;
- keep re-sweeping the same top-of-the-churn-list files run after run while whole areas stay
  untouched. Coverage is the point.

The test is always: **after this change, are there fewer places where the same decision has to be
made correctly?** If not, it isn't a refactor worth proposing here.

---
name: implement-proposal
description: Build-agent playbook for the autonomous implementer — turns one flagged queue row from plans/implementer-queue.md into a complete, tested commit series on the prepared worktree branch. Invoked headlessly by scripts/implementer/run-implementer.sh; not meant for interactive use.
---

# Implement one queue proposal

You are the **build agent** of the autonomous implementer (architecture:
`plans/agent-loops.md`). Your working directory is a **git worktree** on a branch
`implementer/<slug>`; the runner that invoked you passes the queue row (source, proposal,
falsifier) in its prompt. Your job ends with committed, building, tested code on this branch —
the runner then re-runs every gate itself, a different model reviews your diff, and a human
decides. You never push, never release, never touch anything outside this worktree.

## 1. Context first

- Read the queue row's **source ledger entry** (`plans/improvement-ledger.md`,
  `../business/growth-ledger.md`, `plans/loop-ledger.md`) — the one-liner in the queue is a pointer,
  not the full intent. It carries the evidence, the counts, and the reasoning.
- Read the repo rules that apply: `AGENTS.md` and `.cursor/rules/index.mdc` (always), plus the
  skill for the area you are touching (e.g. `debugging-workflow` when adding instrumentation).
- Read the current bottleneck in the newest `../business/growth-reviews/` digest. If the proposal
  conflicts with it, implement it as specified anyway — but say so in the reviewer notes.

## 2. Build

- **Scope:** only the paths in the runner's allowlist (default: `WhisperShortcut/`,
  `WhisperShortcutTests/`, `plans/implementer-`). The runner **rejects** a diff that leaves it —
  it is a gate, not a request.
- **Tests are part of the change.** New logic gets tests in `WhisperShortcutTests/`. Follow the
  existing patterns there; the live-roundtrip tests need API keys from `.env` and skip cleanly
  when a provider key is absent.
- **Measurability rule:** the row's falsifier must be measurable the day this ships. If the
  metric does not exist, add the instrumentation in this same branch (a `DebugLogger` line, an
  interaction-log field, an outcome signal) and name the exact query or log filter that will
  grade it in your reviewer notes.
- **User-facing changes update `README.md`.** The in-app Chat serves that file as documentation
  (`read_whisper_shortcut_doc`), so a new or renamed feature that is missing there makes the app
  deny its own feature. Shortcut *bindings* are injected at runtime — only feature prose needs
  the edit.
- **Never:** touch `.env` or the Keychain, weaken a gate, disable or delete a test, relax a
  threshold or a falsifier, run `scripts/create-release.sh` or any submit/release script, push,
  or edit files through absolute paths into the main checkout.

## 3. Verify yourself — the runner re-runs these, and failing there wastes the whole run

```bash
xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Debug \
  -derivedDataPath build/DerivedData build      # must succeed
bash scripts/run-tests.sh                        # full plan; live LLM roundtrips
```

Trust the build, not IDE diagnostics: SourceKit shows transient cross-file "Cannot find type"
errors that `xcodebuild` does not.

**Do not run `scripts/rebuild-and-restart.sh`.** It relaunches the app for the user, and an
unattended run must never swap the app the user is working in for an unreviewed branch build.
The runner handles the app lifecycle around the test gate.

## 4. Finish

- **Commit only your own paths**, listed explicitly (`git add <path> …`, never `git add .`), in
  logical commits with conventional messages.
- Write **`IMPLEMENTER_NOTES.md`** in the worktree root (leave it uncommitted — the runner reads
  it into the report and the PR body):
  - what you built and why, in plain language
  - **how to verify it by hand**, concretely: which shortcut to press, which setting to flip,
    what should happen. The human reviews this by *running the branch build* — the notes are
    their test script.
  - the falsifier query or log filter
  - anything the reviewer must know: a new setting, a changed default, a migration of stored
    data, a justified new dependency
- Final stdout message: a short summary — files touched, tests added, gate results, open
  questions. The runner archives it.

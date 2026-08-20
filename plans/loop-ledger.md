# Loop Ledger — the meta-loop's memory

Running record of `review-agent-loops` (`scripts/agent-loops-job.sh`): proposals for
changing how the self-improvement loops themselves work — their skills, gates, cadences,
ledgers — plus lessons transferred to/from sabaki.dance's loop setup. Never product
proposals; those belong in `plans/improvement-ledger.md` or `../business/growth-ledger.md`.

Long-lived by design; IDs (L1, L2, …) are stable and never reused.

## Rules for entries

- **Every proposal names a measured weakness** of the machinery (hit rate, deploy lag,
  blind spot, silent failure) and the number that would show it got better.
- **Max 3 new entries per run.**
- **Tighten only.** A proposal that loosens a gate (removes a falsifier, relaxes a
  threshold, lowers an evidence floor) does not go in this table — it goes to the run
  digest's `## Open questions` for the human.
- **Rejections keep their reason.**

Status values: `proposed` · `applied` · `measured` · `rejected` · `superseded`.

## Ideas

| ID  | Proposal | Weakness it fixes (measured) | Status | Run | Notes |
| --- | -------- | ---------------------------- | ------ | --- | ----- |
| L7 | Every scheduled loop digest must name one **Weglassen** (deletion candidate: a skill section, job flag, ledger row, or digest habit to remove) — port Sabaki's mandatory deletion line | Accumulation without pruning: four loops only ever add rows/checks; no run is forced to shrink the machine. Measured: 0 deletion candidates across all digests since 2026-08-03 | proposed | 1 | Falsifier: by the next Architect run, ≥3 of the four loop families have a Weglassen line in their newest digest; if still 0, drop L7 as theatre |
| L6 | Tighten `review-agent-loops` §2: measure **implementer** as a first-class loop; require reading `../business/usage-reviews/` + `../business/growth-reviews/` (not only ledgers); assert job-log presence / cadence doc↔plist match (model-audit "Wed 09:17" vs plist Day=3 06:12) | Meta-loop blind spots: run 1 had to discover implementer + business/ digest move ad hoc; growth ledger still cites `plans/growth-reviews/`. Missed fires and path drift are invisible if the skill's checklist is incomplete | proposed | 1 | Falsifier: next meta digest's funnel table has five loop rows (incl. implementer) and cites business/ paths with zero "path not found" |
| L5 | Missed-fire watchdog: if an expected cadence window has neither a new digest nor a FAILED mail (e.g. usage Mon with no `*-review.md` and no FAILED subject), a small launchd/cron check mails FAILED within 24h — silence must not equal "Mac was asleep" | Measured 2026-08-10: expected weekly usage-review produced **no digest and no FAILED mail** (log jumps 08-03 → 08-17). Same failure mode the TCC empty-read guard was built to kill, one layer up | proposed | 1 | Effort M. Falsifier: next missed Monday (or forced dry miss) produces a FAILED mail within 24h; zero silent gaps in the following 4 expected usage fires |
| L4 | Runner diagnostics must go to stderr: `log()`/`warn()` wrote to stdout, so every `$(helper)` capture swallowed them | Measured 2026-08-18, run 1 of the implementer: build, full test plan and an Opus `APPROVE` all passed, then the runner rejected its own reviewer because the captured verdict read `[implementer]gate:review…APPROVE`. A second instance of the same bug made `run_static_gates` run in a subshell, so `CHANGED_FILES` never reached the parent and the report claimed "0 files changed" for a 5-file diff | applied | 0 | Fixed same day together with L3. **Graded run 1:** APPLIED+WORKED — implementer run completed with real file count and clean APPROVE parse |
| L3 | Runner must diff the branch against the **merge-base**, not against `main`'s tip: `git diff --name-only $(git merge-base main $BRANCH)..$BRANCH`. As written, any commit landing on main during a run makes those files appear as branch changes and trips the scope gate | Found 2026-08-18 while the first run was in flight: main needed a commit (moving business data out of the public repo), and committing it would have failed a healthy run with bogus "out-of-scope paths". Sabaki's runner has the same shape but is shielded by its "local main must not be ahead of origin/main" precondition plus nobody committing mid-run — neither holds here | applied | 0 | **Graded run 1:** APPLIED+WORKED — no bogus scope failures on the I2 build |
| L2 | Make a killed implementer run recoverable: the runner should detect a stale worktree from a previous run and either resume or clean it up behind a flag, and it should report a run that dies without reaching a gate | Measured 2026-08-18, first real run: the parent process was killed at session teardown after the build phase. Result: no mail, no notification, a 0-byte agent log, uncommitted work in the worktree, and the leftover worktree then *blocks* the next run (`die "worktree dir already exists"`). Silence was indistinguishable from success — the exact failure mode every other loop in this repo is built to rule out | proposed | 0 | **Run 1 grade: NOT APPLIED** (still `die` at line 210). Workaround: `nohup`. First re-argue: still the loudest residual silent-failure after L1 proved execution works. Second NOT APPLIED → drop or re-scope |
| L1 | Port Sabaki's rung-2 autonomous implementer (queue → worktree build → runner-enforced gates → cross-model diff review → dogfood-as-review → PR; merge = approval, releases stay with the operator) | Deploy lag: improvement-ledger I2 + I3 sit `proposed` since run 2 with no build started; Sabaki measured the same pattern ("ledgers accumulate OFFEN rows while the Implementer is a manual session") and this design is their answer. Falsifier here: within 2 cycles of building it, ≥1 flagged proposal reaches a mergeable PR with all gates green; demotion rule identical to Sabaki's (≥2 structurally reworked of 5) | measured | 0+ | Built 2026-08-18. **Graded run 1: APPLIED+WORKED** — queue #1 (I2) → [PR #45](https://github.com/mgsgde/whisper-shortcut/pull/45) merged 2026-08-19, gates green, Opus APPROVE 1st pass, Outcome MERGED clean. Falsifier held. Demotion counter: 0 structural rework / 1 run |

## Rejected — do not re-propose

| ID  | Proposal | Why not | Run |
| --- | -------- | ------- | --- |
| _(empty)_ | | | |

## Run log

| Run | Date | Verdict (one line) | Entries added |
| --- | ---- | ------------------ | ------------- |
| 1 | 2026-08-20 | Implementer closed execution gap (I2→PR#45 in 2d); silent missed fires + unrecoverable kills remain binding. | L5, L6, L7 |
| 0 | 2026-08-18 | Baseline — machinery state recorded at setup so the first real run has something to compare | _(none)_ |

## Baseline — 2026-08-18 (recorded at setup, not a real run)

| Signal | Value at 2026-08-18 |
| ------ | ------------------- |
| Loops installed | 4: usage-review (weekly, 3 runs so far), model-audit (monthly), growth-review (biweekly, 0 runs), this one (monthly, 0 runs) |
| Proposals in flight | improvement-ledger: I1 `shipped` (awaiting verify-by-absence), I2 `proposed`, I3 `proposed`; growth-ledger: empty |
| Hit rate | not yet computable — no proposal has reached its falsifier date |
| Known blind spots | see `plans/instrumentation-gaps.md` (4 registered: no web analytics, developer-only usage logs, no review ingestion between growth runs, GitHub traffic 14-day memory) |
| Cross-repo | architecture ported from `~/sabaki.dance.v3` on 2026-08-18; their `docs/loop-meta-log.md` baseline is the same date — first thesis there: the binding weakness is execution (built-but-not-deployed), not idea quality. Check whether it holds here too |

First thesis to test: with only one user-side data source (developer's own usage) the
loops' risk is not execution lag but **proposal starvation** — quiet weeks padded into
findings. The first real run must check the ledgers for padding before anything else.

## Run 1 notes — 2026-08-20

Baseline thesis update: **execution lag is no longer binding** (I2 flagged → merged in 2 days
via implementer). Padding discipline held (usage run 3 added zero rows). Residual binding
weaknesses are **silent missed fires** (usage Mon 08-10) and **L2 unrecoverable kills**.
Proposal-starvation risk remains for growth/usage as customer data stays thin (gap #2), but
it did not produce padded findings this window.

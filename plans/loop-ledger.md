# Loop Ledger — the meta-loop's memory

Running record of `review-agent-loops` (`scripts/agent-loops-job.sh`): proposals for
changing how the self-improvement loops themselves work — their skills, gates, cadences,
ledgers — plus lessons transferred to/from sabaki.dance's loop setup. Never product
proposals; those belong in `plans/improvement-ledger.md` or `plans/growth-ledger.md`.

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
| L1 | Port Sabaki's rung-2 autonomous implementer (queue → worktree build → runner-enforced gates → cross-model diff review → dogfood-as-review → PR; merge = approval, releases stay with the operator) | Deploy lag: improvement-ledger I2 + I3 sit `proposed` since run 2 with no build started; Sabaki measured the same pattern ("ledgers accumulate OFFEN rows while the Implementer is a manual session") and this design is their answer. Falsifier here: within 2 cycles of building it, ≥1 flagged proposal reaches a mergeable PR with all gates green; demotion rule identical to Sabaki's (≥2 structurally reworked of 5) | applied | 0+ | Built 2026-08-18 (same day). Added by the scheduled cross-repo check, from `~/sabaki.dance.v3/specs/2026-08-18-autonomous-implementer-design.md`. Shipped as `scripts/implementer/run-implementer.sh` + `.cursor/skills/implement-proposal/`, queue `plans/implementer-queue.md`, log `plans/implementer-log.md`; architecture in `plans/agent-loops.md` ("The Implementer (rung 2)"). Verified: kill switch refuses, empty queue exits 0, BUILD row is picked. First queue row (I2 hang) sits at `HOLD` — flagging is the user's act. **Grade at the next meta run:** did a flagged row reach a mergeable PR with green gates? |

## Rejected — do not re-propose

| ID  | Proposal | Why not | Run |
| --- | -------- | ------- | --- |
| _(empty)_ | | | |

## Run log

| Run | Date | Verdict (one line) | Entries added |
| --- | ---- | ------------------ | ------------- |
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

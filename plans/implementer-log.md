# Implementer Log

One line per implementer run. The runner appends the row **on the PR/branch**, so it merges
together with the code it describes. After your review, set the Outcome:
`MERGED` (clean) · `MERGED+REWORK` (structural rework needed — counts against the automation's
falsifier) · `DROPPED` (rejected).

**Automation falsifier:** ≥2 of any 5 consecutive runs ending `MERGED+REWORK` or `DROPPED` for
structural reasons (wrong approach, broken behaviour found while dogfooding, gate evasion — not
nits) → demote the capability back to rung 1: build only with a human watching. Set
`IMPLEMENTER_ENABLED=0` and say so here.

**Promotion:** 5 consecutive clean `MERGED` rows → `IMPLEMENTER_SELF_PICK=1` may be enabled, which
lets the runner pick the top-ranked open proposal from the ledgers when the queue has no `BUILD`
row (ranked against the current bottleneck in `../business/growth-ledger.md`, effort S/M only). That flip
is yours to make, never the runner's.

| Date | Queue # | Branch | Review | Gates | Outcome |
| ---- | ------- | ------ | ------ | ----- | ------- |
| 2026-08-18 | 1 | `implementer/q1-20260818` | APPROVE (Opus, 1st pass) | build+tests green | **MERGED** (clean — no rework) |

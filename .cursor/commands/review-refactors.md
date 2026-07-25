---
name: review-refactors
description: Hunt for the mid-to-long-term simplest, most elegant design — deep structural simplifications, not surface cleanups. Given no target it triages the repo itself (churn, defect density, size, crusted code) and picks the highest-payback hotspots. Designed to be run repeatedly: it reads and updates plans/refactor-ledger.md so each run builds on the last instead of re-proposing settled findings. Use when the user asks where the code could be built simpler/more elegantly/better, wants refactoring opportunities, wants technical debt reduced, or wants duplication removed across files.
---

# Review Refactors

Runs the **`review-refactors`** skill — see `.cursor/skills/review-refactors/SKILL.md` for the full
procedure.

## How to invoke

- **`/review-refactors`** — no target: triage the repo (churn × size × defect density, minus what
  the ledger already covers) and pick the 2–3 highest-payback areas.
- **`/review-refactors <target>`** — a path, type, or feature area: sweep that plus its neighbors.

Both forms report first and edit nothing until you approve. Reply `apply`, `apply R4 and R6`, or
`apply all`. Anything tagged **hot path / risk-sensitive** gets a scope question before the rework.

## Built to be run repeatedly

The command keeps a ledger at `plans/refactor-ledger.md`: every finding gets a stable ID and a
status (`applied` / `deferred` / `rejected` / `superseded`), alongside which areas were swept and at
which commit. Each run reads it before triaging and writes it back at the end, so running
`/review-refactors` again continues the campaign — working through the deferred backlog and moving
into unswept areas — instead of re-deriving the same findings.

## Distinguish from the siblings

| Command                        | Target                                | Bar                                               |
| ------------------------------ | ------------------------------------- | ------------------------------------------------- |
| `/review-code`                 | recently changed files                | simpler **today**; the diff must delete something |
| `/review-refactors`            | a whole area, structurally            | fewer places to change; large diffs are fine      |
| `/audit-llm-context`           | `.cursor/**` context files            | stale / duplicated instructions                   |
| `/review-llm-state-of-the-art` | LLM architecture vs provider practice | keep / change / later roadmap                     |

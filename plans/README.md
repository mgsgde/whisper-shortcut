# Implementation Plans

This directory is the shared source of truth for implementation plans and specs used by Cursor, Claude, and other coding agents.

## Guidelines

- One plan per feature, bug, workflow, or release task. Keep plans in plain Markdown so every tool can read and edit them.
- Add plan files directly under `plans/`. Delete them once the work is done — git history preserves decision context if you ever need it.
- Do not duplicate plans under `.cursor/` or `.claude/`; agent-specific files should only point here.
- Before implementing a plan, read the relevant file and update it if requirements have changed.

## Long-lived files (not deleted when work finishes)

- `refactor-ledger.md` — running record for `/review-refactors`.
- `improvement-ledger.md` — usage-driven product proposals, written by the weekly usage-review job.
- `growth-ledger.md` — growth/strategy verdicts (bottleneck, recommendation, falsifier), written by the growth-review job.
- `loop-ledger.md` — meta-proposals about the loop machinery itself, written by the agent-loops job.
- `agent-loops.md` — the architecture of all these loops: roles, autonomy policy, cross-repo coordination with sabaki.dance.
- `instrumentation-gaps.md` — the register of measurement gaps that blind the loops; gap fixes rank above features.
- `implementer-queue.md` — input queue of the autonomous implementer; **you** set `Flag=BUILD`, no agent may.
- `implementer-log.md` — one row per implementer run; its Outcome column grades the automation's own falsifier.

## Scheduled jobs that write here

All run **locally** via launchd, not as cloud routines, because each needs something that only
exists on this Mac: API keys and the audio pipeline, the app's usage logs, or the `asc`/`gh`
Keychain auth. None changes code — they report, and the user decides. Their shared
architecture, autonomy policy, and cross-repo coordination: `plans/agent-loops.md`.

| Job | When | Script | Writes | Notification |
|---|---|---|---|---|
| Model audit | Wednesdays 09:17 | `scripts/model-audit-job.sh` | `plans/model-audits/` | mail, macOS notification fallback |
| Usage review | Mondays 08:47 | `scripts/usage-review-job.sh` | `plans/improvement-ledger.md` + `plans/usage-reviews/` | mail, macOS notification fallback |
| Growth review | Saturdays 09:07 (11-day gate → biweekly) | `scripts/growth-review-job.sh` | `plans/growth-ledger.md` + `plans/growth-reviews/` | mail, macOS notification fallback |
| Agent-loops review | 6th of month 10:17 | `scripts/agent-loops-job.sh` | `plans/loop-ledger.md` + `plans/loop-reviews/` | mail, macOS notification fallback |

LaunchAgents: `~/Library/LaunchAgents/com.whispershortcut.{model-audit,usage-review,growth-review,agent-loops}.plist`.
Logs: `build/logs/`. Disable one with
`launchctl unload ~/Library/LaunchAgents/com.whispershortcut.<name>.plist`.

### Usage review and model audit need Full Disk Access — granted 2026-08-02

(The growth and agent-loops jobs read only the repo, `asc`, and `gh` — no container access,
no Full Disk Access dependency.)

A launchd job cannot read the app's container (`~/Library/Containers/com.magnusgoedde.whispershortcut/…`)
by default. macOS TCC keys the grant to the executable, and launchd's `/bin/bash` does not have it
out of the box. Measured with a throwaway LaunchAgent, before and after:

| | `list` | `read` | files visible | child processes |
|---|---|---|---|---|
| before | DENIED | DENIED | 0 | — |
| after adding `/bin/bash` | OK | OK | 15 | `python3`, `wc` both OK |

Children inherit the grant, which matters because the real reading is done by `claude` and
`python3`, not by bash itself.

Granted via System Settings → Privacy & Security → Full Disk Access → `+` → ⌘⇧G → `/bin/bash`.
Note the tradeoff: this covers every bash script on the machine. It is also why the usage review
probes readability and fails loudly rather than routing around a denial — if the grant is ever
revoked, a zero count would otherwise be indistinguishable from a quiet week.

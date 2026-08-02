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

## Scheduled jobs that write here

Both run **locally** via launchd, not as cloud routines, because both need something that only
exists on this Mac: API keys and the audio pipeline for one, the app's usage logs for the other.
Neither changes code — they report, and the user decides.

| Job | When | Script | Writes | Notification |
|---|---|---|---|---|
| Model audit | Wednesdays 09:17 | `scripts/model-audit-job.sh` | `plans/model-audits/` | mail, macOS notification fallback |
| Usage review | Mondays 08:47 | `scripts/usage-review-job.sh` | `plans/improvement-ledger.md` + `plans/usage-reviews/` | mail, macOS notification fallback |

LaunchAgents: `~/Library/LaunchAgents/com.whispershortcut.{model-audit,usage-review}.plist`.
Logs: `build/logs/`. Disable one with
`launchctl unload ~/Library/LaunchAgents/com.whispershortcut.<name>.plist`.

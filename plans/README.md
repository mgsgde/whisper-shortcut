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
- `loop-ledger.md` — meta-proposals about the loop machinery itself, written by the agent-loops job.
- `agent-loops.md` — the architecture of all these loops: roles, autonomy policy, cross-repo coordination with sabaki.dance.
- `instrumentation-gaps.md` — the register of measurement gaps that blind the loops; gap fixes rank above features.
- `implementer-queue.md` — input queue of the autonomous implementer; **you** set `Flag=BUILD`, no agent may.
- `implementer-log.md` — one row per implementer run; its Outcome column grades the automation's own falsifier.

## What must never be committed here — this repo is PUBLIC

`mgsgde/whisper-shortcut` is a public, open-source repository. The code is meant to be
public; **the business is not.** Anything about how the product earns money lives in the
private parent repo (`whisper-shortcut-private/business/`), never here:

| Belongs in `../business/` (private) | Stays here (public) |
| --- | --- |
| Revenue, proceeds, purchase counts, price strategy | The loop machinery: scripts, skills, architecture |
| Funnel metrics: impressions, product-page views, conversion | Technical ledgers: refactor, model audits, implementer queue/log |
| Competitive positioning and pricing decisions | The instrumentation-gap register (technical) |
| Usage-review digests — they quote real transcript fragments | `improvement-ledger.md` (product proposals, no numbers) |

The loop jobs enforce this: `growth-review-job.sh` and `usage-review-job.sh` abort with an
error if `../business/` is missing rather than falling back to a path in this repo, and
`.gitignore` refuses the moved paths so they cannot drift back in.

**Why the split runs this way.** The machinery being public is fine, arguably good — it is
part of what the project *is*. The numbers being public hands competitors a free read on
what works and what does not, and the usage digests contain the developer's own dictated
text. Publishing revenue can be a deliberate build-in-public choice; it must never be an
accident of where a file happened to land.

*(Learned the hard way on 2026-08-18: the first growth ledger, with a full revenue history,
was committed and pushed here before anyone asked the question. Moved out the same day —
but note that a push is not undoable, only followed by a better decision.)*

## Scheduled jobs that write here

All run **locally** via launchd, not as cloud routines, because each needs something that only
exists on this Mac: API keys and the audio pipeline, the app's usage logs, or the `asc`/`gh`
Keychain auth. None changes code — they report, and the user decides. Their shared
architecture, autonomy policy, and cross-repo coordination: `plans/agent-loops.md`.

| Job | When | Script | Writes | Notification |
|---|---|---|---|---|
| Model audit | Wednesdays 09:17 | `scripts/model-audit-job.sh` | `plans/model-audits/` | mail, macOS notification fallback |
| Usage review | Mondays 08:47 | `scripts/usage-review-job.sh` | `plans/improvement-ledger.md` + `../business/usage-reviews/` (private) | mail, macOS notification fallback |
| Growth review | Saturdays 09:07 (11-day gate → biweekly) | `scripts/growth-review-job.sh` | `../business/growth-ledger.md` + `../business/growth-reviews/` (private) | mail, macOS notification fallback |
| Agent-loops review | 6th of month 10:17 | `scripts/agent-loops-job.sh` | `plans/loop-ledger.md` + `plans/loop-reviews/` | mail, macOS notification fallback |
| Sales scout | Daily 08:17 | parent `scripts/sales/scout-job.sh` | `../sales/ops/` (private) | mail, macOS notification fallback |
| Sales poster | Daily 15:05 | parent `scripts/sales/poster-job.sh` | queue status in `../sales/ops/queue.jsonl` | mail on activity; `SALES_POST_ENABLED=0` by default |

LaunchAgents: `~/Library/LaunchAgents/com.whispershortcut.{model-audit,usage-review,growth-review,agent-loops,sales-scout,sales-poster}.plist`.
App-loop logs: `build/logs/`. Sales-agent logs: `../sales/ops/logs/`. Disable one with
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

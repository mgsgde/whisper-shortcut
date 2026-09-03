# The self-improvement loops — who does what

WhisperShortcut is improved by a family of scheduled, agent-run loops. This page is their
single source of truth: the goal they serve, who does what, what each may write, and how
this repo's loop machinery coordinates with sabaki.dance's (`~/sabaki.dance.v3`), which
runs the same architecture and learned most of these lessons first.

## The goal (North Star)

> **Paying customers.** App Store proceeds, and the funnel that feeds them:
> App Store impressions → product-page views → downloads → activated users → ratings/reviews.
> GitHub stars and website traffic are distribution levers, not the goal.

Every loop ranks its proposals against the **current bottleneck** named in the latest
`../business/growth-reviews/` verdict. A proposal that pulls effort away from the bottleneck ranks
last, however good it looks locally.

## The loops

| Role | Skill / job | Sees | Rewarded for | Writes | Cadence |
| ---- | ----------- | ---- | ------------ | ------ | ------- |
| **Usage** | `usage-review-job.sh` (`analyze-user-interactions`) | Local interaction logs + outcome signals | Recurring failures with counts | `plans/improvement-ledger.md` + digest | Mon 08:47 weekly |
| **Models** | `model-audit-job.sh` (`audit-llm-models`) | Live provider lineups vs shipped defaults, benchmarks | Pareto-justified migrations | `plans/model-audits/` | Wed 09:17 monthly |
| **Strategy/Growth** | `growth-review-job.sh` (`review-growth`) | App Store Connect, GitHub, git effort, competitors | Naming the ONE binding constraint toward revenue | `../business/growth-ledger.md` + digest | Sat 09:07, effectively biweekly |
| **Architect** | `agent-loops-job.sh` (`review-agent-loops`) | The loops' own ledgers, hit rates, blind spots, outside best practices, Sabaki's loop docs | The loops finding more true things per run | `plans/loop-ledger.md` + digest | 6th of month, 10:17 |
| **Implementer** | `tick.sh` → `groom-queue.py` + `run-implementer.sh` (`implement-proposal`) — **rung 2** | One released queue row + its source ledger entry | A gated, reviewed branch you can dogfood | Code on a branch, `plans/implementer-{queue,log}.md` | Hourly tick (launchd); builds a row you flagged `BUILD`, or one whose veto window ran out |
| **Sales** | parent `scripts/sales/scout-job.sh` (`run-sales-agent`) — scout **rung 0**; poster **rung 3** | Public HN/Reddit/GitHub/App Store conversations | Disclosed drafts that route people to the store; customer-voice feedback | `../sales/ops/` (private parent — queue, digests, feedback). Never the public app repo | Daily 08:17 scout, 15:05 poster |

## Shared conventions (kept identical with sabaki.dance — do not drift)

These are the lessons Sabaki's loops paid for; both repos apply them the same way, and the
Architect loop checks for drift on every run:

- **The proposer is never the judge.** Loops write proposals with falsifiers; reality (a
  metric two weeks later) and the user decide. No loop evaluates its own output with the
  context that produced it.
- **Strategy outranks.** Loops read the latest growth verdict first and rank against its
  bottleneck. Without that, four loops each produce a locally sensible backlog and together
  build the wrong thing efficiently.
- **Grade before proposing.** Every run opens by grading its own previous output against
  reality (`git log`, release history), never against the ledger's claim.
- **The deploy gate.** A falsifier may only be graded once the change is confirmed live
  for the population being measured — a released App Store/GitHub version for customer
  metrics, a rebuilt local app for the developer's own usage metrics. Built-but-not-live
  is `TOO EARLY`, never `NO EFFECT`: writing off an undeployed change plants a false
  lesson in a ledger that is never cleaned up, and the loop then learns from it. Sabaki's
  meta-log calls this its most expensive failure mode.
- **Instrumentation gaps rank above features** and live in one register with statuses —
  `plans/instrumentation-gaps.md` — not in per-run prose.
- **"Build nothing this cycle" is a valid verdict** for every loop, and the honest one
  whenever the bottleneck is not the thing that loop can move.
- **Loud failure.** A loop that cannot read its data or write its digest reports a FAILED
  run by mail — silence must never be distinguishable from a quiet week.

## Autonomy policy

Scheduled **review** jobs sit at **rung 0 — report-only**: they read anything, write reports
and ledger rows, and never touch code, prompts, defaults, settings, commits, or pushes. The
full ladder (rungs 0–4, promotion criteria, kill-switch requirements) is defined in
`~/sabaki.dance.v3/docs/agent-autonomy-policy.md` and applies here unchanged.

Two capabilities are above rung 0:

| Capability | Rung | Gate that holds it there |
| ---------- | ---- | ------------------------ |
| Implementer: build a released queue row → gated branch | **2** | The *runner* re-runs every gate (scope allowlist, clean tree, main-checkout pollution, `xcodebuild`, full test plan); a **different model** reviews the diff; `IMPLEMENTER_ENABLED` and `IMPLEMENTER_TICK_ENABLED` kill switches read at run time; nothing is merged or released. A row is released either by you flagging it `BUILD`, or by a **veto window** running out (below). Reversibility: everything it produces is a branch and a PR you merge. |
| Groomer: file a loop proposal as a `VETO` row that builds on silence | **2** | `groom-queue.py` contains no model — every lane is a lookup or a regex against committed state. Only reversible, in-scope classes with a gradeable falsifier get a window; `instrumentation` needs an OPEN row in `plans/instrumentation-gaps.md`; everything else lands in `ASK`. At most `IMPLEMENTER_MAX_INFLIGHT` (3) auto rows open at once, and every window is announced by mail before it starts. Kill switch `IMPLEMENTER_VETO_LANE=0` restores the pre-2026-09-03 behaviour. |
| Sales poster: comment on a public thread or App Store review | **3** | Morning digest is the preview; 15:05 posts PREVIEWED rows whose veto window elapsed (`SALES_VETO_HOURS`, default 7). `../scripts/sales/veto.sh S-001` stops a row. Kill switch `SALES_POST_ENABLED` (default 0). A comment to a stranger is irreversible, so this capability does not promote to rung 4. |

The rule that outranks every finding, from the same policy:

> **An agent may tighten a gate, never loosen one.** Adding a check, raising an evidence
> bar, demanding a falsifier: propose freely. Removing a falsifier, relaxing a threshold,
> lowering a sample floor: a human change, in its own commit.

The `VETO` lane is the one loosening this repo has taken, and it was taken the way the rule
requires: asked and answered by the owner on **2026-09-03**, in its own commit, with a kill
switch (`IMPLEMENTER_VETO_LANE=0`). What it changes is who must act — before, a proposal
nothing could prove waited for approval that never came (queue row 2 has sat `OPEN` since
2026-08-20); now it waits for an objection. What it does **not** change is any gate on the code
itself: the runner still re-runs every check, a different model still reviews the diff, and the
output is still a PR you merge.

And its corollary for the Architect loop specifically: it proposes changes to the loop
machinery, it never applies them unattended — an agent that edits the criteria it is judged
by will eventually make itself look successful.

## The Implementer (rung 2) — how it runs

Ported from sabaki.dance's `specs/2026-08-18-autonomous-implementer-design.md` on 2026-08-18.
The shape is theirs; three things differ because this repo is a sandboxed macOS app, not a
web service (see the divergence table below).

```
loop jobs (usage · model-audit · growth · architect)
        │ each run drops proposals.json in ~/.local/state/whispershortcut-implementer/incoming
        ▼
scripts/implementer/tick.sh         ← hourly under launchd
        │ groom-queue.py: lookups only, no model. instrumentation w/ an OPEN gap → BUILD;
        │ reversible+in-scope+falsifiable → VETO (announced by mail, builds on silence);
        │ everything else → ASK. Ripe VETO windows promote to BUILD.
        ▼
plans/implementer-queue.md          ← YOU set Flag=BUILD, or stop a VETO row: veto.sh <#>
        │
scripts/implementer/run-implementer.sh
        │ 1. kill switch, lock, main-branch check, pick topmost BUILD/OPEN row
        │ 2. worktree .claude/worktrees/implementer-<slug> on branch implementer/<slug>
        │    build agent (cursor-agent) runs .cursor/skills/implement-proposal/SKILL.md
        │ 3. gates re-run BY THE RUNNER: scope allowlist · clean tree · pollution check ·
        │    xcodebuild · full test plan   (an agent cannot skip what it does not control)
        │ 4. a DIFFERENT model reviews the diff → APPROVE | BLOCK (one rework cycle, then stop)
        │ 5. queue row + ledger line committed ON THE BRANCH, so bookkeeping travels with code
        │ 6. mail + notification: how to dogfood it, how to approve it
        ▼
YOU run the branch build for a while → merge → release when you decide
```

**Operating it**

```bash
bash scripts/implementer/install-implementer.sh    # once: ~/.config/whispershortcut-implementer/env
bash scripts/implementer/install-tick.sh           # once: the hourly launchd agent
bash scripts/implementer/run-implementer.sh --dry-run
bash scripts/implementer/run-implementer.sh        # one build, by hand

python3 scripts/implementer/groom-queue.py --dry-run   # what would the groomer file?
bash scripts/implementer/veto.sh 7                     # stop VETO row 7 before its deadline
```

Both switches must be `1` in `~/.config/whispershortcut-implementer/env` before the schedule
does anything: `IMPLEMENTER_ENABLED` (master) and `IMPLEMENTER_TICK_ENABLED` (schedule only).
Tick log: `build/logs/implementer/tick-<date>.log`.

**The rules that keep it honest** — all mirrored from Sabaki, all enforced in the script:

- **Builder ≠ judge.** The model that wrote the code never decides it is fine — the same
  proposer-is-never-the-judge rule the loops run on, applied to code. Cursor builds (large,
  cheap quota), Claude judges (scarce, high-judgment). The split is config, so the scout/meta
  loops may propose adjusting it; they may never propose removing the review step.
- **Measurable-on-ship-day.** A row whose falsifier cannot be measured when it ships is not
  eligible; the build must add the instrumentation in the same branch, or the proposal goes to
  `plans/instrumentation-gaps.md` first.
- **Releasing is human, or it is silence.** No loop may set `BUILD` on its own finding — only
  the groomer may, and only for classes an existing gate judges. Everything else it files is
  either a `VETO` row you were mailed about and can stop, or an `ASK` row that waits for you.
- **Nothing is ever dropped.** A proposal the groomer cannot justify becomes an `ASK` row, not
  a discarded finding. That is what makes the ASK lane safe to be conservative with.
- **Demotion falsifier:** ≥2 of any 5 consecutive runs needing structural rework → back to
  rung 1. Tracked in `plans/implementer-log.md`, graded from its Outcome column.
- **Promotion is earned:** 5 clean merges before `IMPLEMENTER_SELF_PICK=1` is even offered, and
  you flip it, not the runner.

## What this machinery costs

Measured 2026-08-19. The point of this section is that no line here is a guess — if a number
changes, re-measure it rather than editing the prose.

| Surface | Billed as | Per run | Brake |
| --- | --- | --- | --- |
| The four scheduled Claude jobs | **Max subscription** — no `ANTHROPIC_API_KEY` anywhere, so they spend rate-limit capacity, not dollars | $0 | `--max-budget-usd` (3–10) is a backstop that only binds if an API key ever enters the environment |
| Implementer build agent | **Cursor subscription**, model `auto` (the Auto/Composer pool, not the API pool) | quota only | 120-min per-run timeout · **10 runs/month** (`IMPLEMENTER_MAX_RUNS_PER_MONTH`) · one build per tick, and only when a row is actually released |
| Implementer review pass | Max subscription (Opus) | $0 | one rework cycle, then the run stops |
| Implementer test gate | **Real dollars** — the live roundtrip tests use the provider keys in `.env` | 5 requests × 1.24 s audio ≈ **under $0.01** | gated per credential; tests skip when a key is absent |
| Monthly model audit | Real dollars, same keys | ~400 short transcription requests ≈ **a few cents** | monthly cadence |
| Voice Feedback selection | Real dollars, user's Gemini key | ≤2000 chars ≈ 500 extra tokens ≈ **$0.00005** | the 2000-char cap in `VoiceFeedbackService` |
| `web-traffic-report.sh` | **$0 marginal** — Cloud Logging *reads* are free; Cloud Run was already writing those logs | $0 | `--limit 20000` |

**Total real-dollar exposure of the whole loop system: well under $1/month** at current cadences.

**The hourly tick does not mean hourly builds.** A tick with no released row exits in under a
second: the runner prints "no BUILD/OPEN row in the queue" and stops before any agent starts.
What bounds the spend is unchanged and is not the schedule — it is `IMPLEMENTER_MAX_RUNS_PER_MONTH`
(10), counted in a file so it survives a crash mid-run, plus `IMPLEMENTER_MAX_INFLIGHT` (3) on
how many rows the groomer may have released at once. The schedule only removes the requirement
that you be at the keyboard for a build you already agreed to.


**Two of the three billing surfaces are now closed by construction, not by luck:**

1. **Claude: enforced.** Every job unsets `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` before
   invoking the CLI, so it authenticates against the subscription even if a key is exported in a
   shell profile. Absence used to be merely true; it is now guaranteed. Policy: this machinery
   runs on the subscription or it does not run. The `--max-budget-usd` caps stay as a second
   line, but nothing should ever reach them.
2. **Cursor: capped.** On-demand spending is Disabled (verified below), so the plan price is the
   ceiling.

**The one surface that cannot be a subscription** is the app's own provider keys in `.env`
(Gemini / OpenAI / xAI). Those are pay-per-use accounts by design — "bring your own API keys" is
what the product *is*, and the same keys pay for everyday dictation.

Since 2026-08-19 the machinery touches them in exactly **one** place:

| Job | Requests | Bounded by | Measured cost |
| --- | --- | --- | --- |
| Monthly model audit | **128** = 8 models × (10 latency + 3 glossary + 3 silence), each on a 1.24 s clip | the model list and the round counts in `benchmark-transcription.py` — both literals in the repo, not a loop over live data | a few cents |
| Implementer test gate | **0** | `IMPLEMENTER_LIVE_TESTS=0` skips both `(live)` suites; the remaining 213 tests stub `URLProtocol` and run in 0.75 s | **$0** |

The count is fixed, not data-dependent: no job iterates over a growing corpus, retries in a loop,
or scales with usage. A month cannot cost more than a month unless someone edits those literals.
The honest answer is that this surface costs cents, not that it costs nothing.

**Adding a live test later re-opens it.** Both current live suites carry `(live)` in their
`@Suite` name; a new one must be added to `TEST_SKIP_ARGS` in the runner, or the implementer
starts spending per run again.

Re-check rather than assume:
2. **Cursor on-demand spending** being enabled in the dashboard would let an implementer run bill
   past the subscription. Nothing in this repo can see that setting. **Checked 2026-08-19: it is
   Disabled, with no monthly limit set** — so a run that exhausts the included quota stops rather
   than charging, and the plan (Pro+, $60/mo) is the ceiling. Re-check if the plan changes; that
   is the single setting standing between this machinery and an unbounded bill.

## Why these run locally (launchd, not cloud routines)

Same reason as ever (see `plans/README.md`): the inputs only exist on this Mac — usage
JSONL in the sandboxed container, API keys in `.env`, `asc`/`gh` auth in the Keychain.
A cloud routine would see an empty repo and report a quiet week.

## Cross-repo coordination with sabaki.dance

Both repos run the same loop architecture; the transfer channel is the **Architect loop**,
not ad-hoc copying:

- `review-agent-loops` here **reads** Sabaki's loop state read-only:
  `~/sabaki.dance.v3/docs/{loop-architecture,agent-autonomy-policy,loop-meta-log,ai-stack-log,product-loop-log,elon-log}.md`
  and `scripts/routines/README.md`. Its report ends with a **Transfer** section: lessons to
  import here (as proposals in `plans/loop-ledger.md`) and lessons to export (as a
  paste-ready block for `~/sabaki.dance.v3/docs/loop-meta-log.md` — it never writes into
  the other repo).
- Sabaki's `/improve-loop` may read this repo's `plans/{agent-loops.md,loop-ledger.md}` the
  same way. Symmetric, read-only, human applies.

Deliberate divergences (infrastructure, not architecture — do not "fix" these toward
Sabaki):

| | sabaki.dance | whisper-shortcut | Why |
| --- | --- | --- | --- |
| Scheduler/host | systemd timers on the minipc | launchd on this Mac | The data (usage logs, Keychain auth for `asc`/`gh`, audio pipeline) only exists here |
| Agent runner | `cursor-agent`, model `auto` (Cursor pool) | `claude -p`, opus/sonnet (Max subscription) | Different billing pools; both pin models + budget caps in the job script |
| Ledger writes | paste-ready block, human pastes (a dirty tree breaks the minipc's deploy pull) | job appends directly (local working copy, user reviews via git diff) | Same auditability, one less manual step |
| "Live" check | `deployment-status.ts` against `/api/version` | App Store version (`asc versions list`) / GitHub release for customer metrics; rebuilt local app for own-usage metrics | Different deploy targets, same deploy gate |
| Implementer review surface | Branch deployed to a gated dev instance with sanitized prod data | The built app itself — you run the branch build (dogfood-as-review) | No server, no database; the app *is* the artifact |
| Implementer test gate | `npm run test:web` in the worktree | `xcodebuild test`, which requires killing the running app — the runner relaunches the user's **main** build after each gate | Mid-run the branch has not been judged yet, so the app the user works in must not be swapped for it |
| After a green run | Branch is deployed to a gated dev instance | The runner leaves the **branch build running** as the user's app (`IMPLEMENTER_LAUNCH_BRANCH_BUILD=1`, asked for 2026-09-03) | There is no dev instance; the app *is* the review artifact, and a change you have to launch yourself is a change you do not try. Only after every gate and the reviewer's APPROVE — a failed run always restores the user's own build |
| Implementer auto lane | `scorer-fix` (a failing eval-corpus case is red→green) and `instrumentation` build with no announcement | `instrumentation` only — there is no eval corpus here | The auto lane may only hold classes an existing gate already judges; inventing one to match Sabaki would be the loosening the policy forbids |
| Proposal transport | routines write JSON to `~/.local/state/sabaki-implementer/incoming`, groomer is TypeScript | identical shape, groomer is Python (`groom-queue.py`) | No node toolchain in a Swift repo; a dependency nobody maintains is a scheduled job that dies silently |

## Operating

```bash
# Manual runs (from whisper-shortcut/)
bash scripts/growth-review-job.sh            # strategy/growth review now
bash scripts/agent-loops-job.sh              # meta review now
bash scripts/growth-review-job.sh --dry-run  # check plumbing without a Claude pass

# Sales agent (from the private parent repo)
bash ../scripts/sales/install.sh             # once: config + launchd
bash ../scripts/sales/scout-job.sh --dry-run
bash ../scripts/sales/scout-job.sh --force
bash ../scripts/sales/veto.sh S-001          # before 15:05
bash ../scripts/sales/poster-job.sh --once --id S-001

# Status
launchctl list | grep whispershortcut
ls ../business/growth-reviews/ plans/loop-reviews/ ../sales/ops/digests/

# Disable a loop
launchctl unload ~/Library/LaunchAgents/com.whispershortcut.growth-review.plist
launchctl unload ~/Library/LaunchAgents/com.whispershortcut.agent-loops.plist
launchctl unload ~/Library/LaunchAgents/com.whispershortcut.sales-scout.plist
launchctl unload ~/Library/LaunchAgents/com.whispershortcut.sales-poster.plist
```

Every job mails its digest (macOS notification as fallback) and reports failures loudly —
a loop that silently stops running looks exactly like a quiet week, and that is the one
failure mode this design exists to rule out.

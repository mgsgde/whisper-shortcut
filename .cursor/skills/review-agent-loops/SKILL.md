---
name: review-agent-loops
description: Meta-loop — audits the self-improvement machinery itself (usage-review, model-audit, growth-review, their ledgers and gates), measures each loop's hit rate and blind spots, sweeps current best practices for autonomous agent loops, and exchanges lessons with sabaki.dance's loop setup. Proposes changes to how the loops work, never to the product; may only ever tighten a gate. Use when the user asks whether the loops are working, "verbessern sich die Loops selbst", why proposals never get built, whether the agent setup follows current best practices, or as the scheduled monthly meta routine.
---

# Review Agent Loops — the meta-loop

Answer one question: **is this machinery finding more true things per run than it did last
time, and where is it blind?** Everything else improves the app; this improves the
machinery. Read `plans/agent-loops.md` first — it defines the roles and the rule that
constrains this skill.

## The rule that constrains this skill

> **You may tighten a gate. You may never loosen one.**

Adding a check, raising an evidence bar, demanding a falsifier: propose freely. Removing a
falsifier, relaxing a threshold, lowering the interaction floor, shortening a review
window: **not yours** — those go under `## Open questions` for the human, with evidence.
An agent that can edit the criteria it is judged by will eventually make itself look
successful; this rule outranks every finding you make.

**Anti-goal:** a list of tooling ideas. Every proposal names a measured weakness of the
loop machinery and the number that would show it got better.

## 1. Grade your own previous run first

Read `plans/loop-ledger.md` and the newest digests in `plans/loop-reviews/`. For each open
meta-proposal: was it applied (`git log --oneline --since=<that date> -- .cursor/skills/
scripts/ plans/`), and did the number it predicted move? Verdicts: `APPLIED+WORKED` ·
`APPLIED+NO EFFECT` (write it off with why) · `NOT APPLIED` (twice = drop or re-argue) ·
`TOO EARLY`. First run: say so in one line and continue.

## 2. Measure each loop — counts, not impressions

For every loop in `plans/agent-loops.md` (usage-review, model-audit, growth-review, and
this one):

- **Proposal funnel:** parse its ledger (`plans/improvement-ledger.md`,
  `plans/growth-ledger.md`, `plans/model-audits/`, `plans/loop-ledger.md`) and count per
  status: proposed / accepted / shipped / measured / rejected. **Hit rate = worked /
  (worked + written off).** Near 100 % is not good news — it means the loop only proposes
  the obvious. Around a third means it is actually reaching.
- **Did it run?** Compare expected firings (cadence) against actual digests and
  `build/logs/*.log`. A loop that silently stopped IS the finding. Check the run logs for
  timeouts, budget kills, and mail failures.
- **Deploy lag:** median days from `proposed` to `shipped` for acted-on entries. A loop
  whose proposals sit unbuilt for months is producing reports, not improvement — say
  whether the problem is proposal quality or user bandwidth, with examples.
- **Blind spots:** the register is `plans/instrumentation-gaps.md` — update its status
  rows (that is within rung 0) instead of re-listing gaps in prose. Verify claimed
  `CLOSED`/`BUILT` rows against reality, add newly discovered gaps with the loop they
  blind, and check that gap fixes were ranked above features by the other loops.
- **Deploy-gate discipline:** scan the ledgers for falsifiers graded `NO EFFECT` where
  the change was never confirmed live — Sabaki's meta-log names this the most expensive
  failure mode, because a false write-off in a never-cleaned ledger teaches every later
  run the wrong lesson.
- **Cost/noise:** digests that repeated themselves, quiet weeks padded into findings,
  re-proposals of rejected ideas — each one erodes the user's trust, which is the real
  budget every loop spends.

## 3. Sweep outside best practices

The user explicitly wants current best practices for autonomous self-improvement loops
folded in. Sources (each may fail — note it, continue; zero reachable sources = FAILED
run, say so):

- Claude Code changelog: `https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md`
  — harness features the jobs could use (headless flags, skills, hooks, subagents,
  scheduled/cloud agents, budget controls).
- Anthropic engineering blog and agent docs (`https://www.anthropic.com/engineering`,
  `https://docs.claude.com`) — agent-loop patterns, evaluator/optimizer designs.
- Agent Skills standard: `https://agentskills.io/home` — portable-skill format drift.
- One WebSearch for recent writing on autonomous agent improvement loops / self-improving
  agent setups; skim critically — extract mechanisms with evidence, ignore hype.

A finding must map to a concrete file or job here with a gate that would prove the
improvement; otherwise it is one line under "watching".

## 4. Cross-repo exchange with sabaki.dance

Read (read-only, at `~/sabaki.dance.v3` — if the path is missing, note it and skip):
`docs/loop-architecture.md`, `docs/agent-autonomy-policy.md`, `docs/loop-meta-log.md`,
`docs/ai-stack-log.md`, `docs/product-loop-log.md`, `docs/elon-log.md`,
`scripts/routines/README.md`.

Produce a **Transfer** section, both directions:

- **Import:** mechanisms Sabaki's loops learned that ours lack (their meta-log records
  what worked and what was written off — mine it before re-inventing). Each becomes a
  normal proposal with a falsifier.
- **Export:** lessons from this repo's loops that Sabaki lacks, as ONE paste-ready fenced
  markdown block for `~/sabaki.dance.v3/docs/loop-meta-log.md`. **Never write into the
  other repo** — the human pastes it (their convention, same as their minipc routines).

## 5. Output

1. A digest whose first line is `VERDICT: <one sentence, max 120 chars>` — the top finding
   or "loops healthy, nothing actionable".
2. Then: the per-loop funnel table, blind spots, best-practice findings
   (adopt/adapt/ignore, each with the file it touches, effort S/M/L, and a falsifier),
   the Transfer section, `## Open questions` (anything that would loosen a gate).
3. At most 3 new rows in `plans/loop-ledger.md`, following that file's rules.

## Ground rules

- **Report-only** except `plans/loop-ledger.md` and the digest — even for the loops' own
  skill files. Interactively, you may edit skills/jobs only when the user approves in the
  session.
- Max 3 proposals; "the loops are healthy" is a valid and welcome verdict.
- This loop is deliberately the rarest: its mistakes change the machine that changes the
  product, and it needs completed cycles of evidence before it has anything honest to say.
- Language: interactive runs answer in the user's language; scheduled reports are English.

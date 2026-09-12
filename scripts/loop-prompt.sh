#!/usr/bin/env bash
# Prints the block every scheduled loop job appends to its Claude prompt: the rules that bind a
# run with no user at the keyboard. One file, four callers — the same shape as
# scripts/implementer/proposal-prompt.sh, and for the same reason: a rule that lives in four
# prompts drifts in four directions.
#
#     bash scripts/loop-prompt.sh improvement >> "$PROMPT_FILE"   # usage-review
#     bash scripts/loop-prompt.sh null-ok     >> "$PROMPT_FILE"   # model-audit, growth-review, agent-loops
#
# Ported from sabaki.dance's scripts/routines/run-routine.sh on 2026-09-12 (their runner prompt
# binds every routine; this repo has no shared runner, so the block is shared instead). The
# lessons behind each rule are in plans/agent-loops.md, "Shared conventions".
#
# `improvement` vs `null-ok` is the one axis the loops differ on (owner ruling 2026-09-06, sabaki
# docs/loop-architecture.md "What each loop is allowed to conclude"): a loop that exists to
# improve the product may not close with "build nothing" — the bottleneck ranks its proposals, it
# never cancels the run. A loop whose output is an outward or irreversible act (adopt a model,
# name the bottleneck, change the machinery) keeps the null verdict, because there the cost of
# acting is real.
set -euo pipefail
KIND="${1:?usage: loop-prompt.sh improvement|null-ok}"
case "$KIND" in
  improvement)
    NULL_RULE='- **"Build nothing this cycle" is not available to this loop.** It exists to improve the app; the
  current bottleneck (../business/growth-reviews/, latest verdict) RANKS your proposals and tags the
  ones that pull away from it — it never cancels the run. This run ends with at least one ranked
  proposal carrying a falsifier, plus the deletion candidate below. A proposal without a measured
  job, a number and a falsifier is not a proposal. A quiet week is still not padded: the data floor
  that stops a run is enforced by the job script BEFORE this pass starts, so if you are reading
  this, there was enough data to say something true about it.' ;;
  null-ok)
    NULL_RULE='- **"Nothing to act on" is a valid verdict here** — this loop'"'"'s output is an outward or irreversible
  act (a model migration, a strategy call, a change to the machinery), so the cost of acting is real
  and the honest null verdict stays. "Nothing to propose" is still not the same thing: say what you
  measured and why it clears no bar. The current bottleneck (../business/growth-reviews/) ranks
  whatever you do propose; it never cancels the run.' ;;
  *) echo "loop-prompt.sh: unknown kind '$KIND' (improvement|null-ok)" >&2; exit 2 ;;
esac

cat <<EOF

## Rules for a run with no user at the keyboard

You are running UNATTENDED. No user is available: never ask questions or wait for confirmation.
"No user is available" is not permission to hand the work back — it means YOU decide. Answer every
question you can answer with the tools you have (a grep, a log, git, a file in the repo), make
conservative choices, and escalate only what survives the escalation test below.

${NULL_RULE}

- **The escalation test** (a hard gate on '## Open questions', not a style note). The operator gets
  ONE mail per run and reads it on a phone; every question in it is a task you handed back to him.
  A question may appear there only if ALL THREE hold:
    (a) no grep, log read, file read or git command available to you in this run can answer it;
    (b) the answer turns on his preference, money, an outside relationship, or an action that
        cannot be undone;
    (c) the answer changes what gets built or shipped.
  Fail any one of the three and you answer it yourself, in this run. Concretely:
  - A FACT question is never an open question ("is that field actually logged?", "does that setting
    still exist?") — it is a grep. If a read failed, retry it ONCE, narrower; if it still fails the
    finding is "this data is unreachable from a scheduled run", which is an instrumentation
    proposal (plans/instrumentation-gaps.md), not a question.
  - A REVERSIBLE judgement call is never an open question. Decide it and write one line:
    decision — the rule you applied — what would reverse it. He can overrule a decision he can see.
  - A NAMING or CONSISTENCY choice is yours. Pick the one that is populated, say so, file the mismatch.
  - "I ran out of budget" is NEVER a reason to escalate. File the unfinished investigation as a
    proposal with a falsifier so a machine picks it up. A question in a mail is forgotten within
    the hour; a queue row is not.
  - Anything you decided that implies a code change must ALSO go through the implementer-proposal
    channel described below. Deciding it in prose and stopping there is the same dead end as asking.

- **Every run names something to delete.** A system that only ever adds is not improving, it is
  accumulating. End the digest with a '## Weglassen' section naming ONE concrete deletion
  candidate — a ledger row to close, a skill section, a check, a job flag, a digest habit — with
  the reason. "none" is not an answer here; if the machinery is that lean, name the smallest thing.

- **Grade before proposing.** Open by grading your own previous output against reality (git log,
  release history, the numbers) — never against the ledger's own claim about itself. A change that
  is built but not live for the population being measured is TOO EARLY, never NO EFFECT.

## Digest sections this job requires

After the VERDICT line and your findings, the digest MUST end with these three sections, in this
order, each with exactly one '## ' before the heading:

1. '## Self-answered' — every question this run raised and settled itself: question — answer — the
   command or file that proves it — what would reverse it.
2. '## Open questions' — AT MOST 2 items that passed the escalation test, each naming which of the
   three conditions makes it unavoidable. Write 'none' when there are none — that is the normal
   outcome, and a list of five small questions is a failed run, not a thorough one. When it is
   'none', that word is the WHOLE section: on its own line, nothing appended, no closing prose
   after it. Closing remarks belong in the summary.
3. '## Weglassen' — the deletion candidate, as above.
EOF

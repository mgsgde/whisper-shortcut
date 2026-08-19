---
name: review-growth
description: First-principles growth/strategy review — pulls real business metrics (App Store Connect revenue and downloads, GitHub stars and traffic, git effort, competitor moves), identifies the single biggest bottleneck toward paying customers, and says bluntly what to do next and what to stop. Grades its own previous verdict first. Use when the user asks how to grow revenue, downloads, or stars, "was ist der Engpass", whether current work is pointed at the goal, or as the scheduled biweekly growth routine.
---

# Review Growth — First-Principles Bottleneck Review

Answer one question: **given the goal, what is the single binding constraint right now,
and is current work pointed at it?** Method: first principles + Theory of Constraints
(there is always exactly one bottleneck). Adapted from sabaki.dance's `/elon` skill; the
shared architecture is `plans/agent-loops.md` — read it if you have not.

**Anti-goal:** a balanced report. If the output lists three "focus areas", the analysis
failed. One bottleneck, one recommendation, one stop-doing.

## Phase 0 — Goal and self-grading (always first)

The North Star (from `plans/agent-loops.md`):

> Paying customers. App Store proceeds, and the funnel that feeds them: impressions →
> product-page views → downloads → activated users → ratings/reviews. GitHub stars and
> website traffic are distribution levers, not the goal.

Then grade the previous run before producing anything new:

1. Read the latest entry in `../business/growth-ledger.md` and the newest digest in
   `../business/growth-reviews/`.
2. For its recommendation: was it acted on? Check reality (`git log --oneline
   --since="<that run's date>"`, App Store version history via `asc versions list --app
   6749648401`), not the ledger's claim.
3. **The deploy gate** (see `plans/agent-loops.md`): grade the falsifier only once the
   change is confirmed live for the population it measures — a released version for
   customer metrics, a rebuilt local app for own-usage metrics. Built-but-not-live is
   `TOO EARLY`, never `NO EFFECT`. Then: did the falsifier metric move? Verdicts: `SHIPPED+WORKED` ·
   `SHIPPED+NO EFFECT` (write it off, one sentence why the prediction was wrong) ·
   `NOT ACTED ON` (twice in a row = say whether it still matters or retire it) ·
   `TOO EARLY`.
4. If this is the first run, say so in one line and continue.

## Phase 1 — Evidence, not opinion

Every claim in the verdict must trace to a number gathered here. If a metric cannot be
measured, write **"unmeasured"** — never estimate it into the verdict. ~10 numbers, not a
data warehouse. Compare the last 30 days against the 30 before where the source allows.

1. **Revenue and funnel** (App Store Connect via `asc`, app ID `6749648401`): proceeds,
   units/downloads, product-page views, impressions, conversion rate. Discover the exact
   subcommands with `asc analytics --help`, `asc finance --help`, `asc insights --help` —
   do not guess flags. Ratings/reviews: current average, count, and any new written reviews
   (read them; they are the only verbatim customer voice this repo has).
2. **Distribution:** `gh api repos/mgsgde/whisper-shortcut` (stars, forks),
   `gh api repos/mgsgde/whisper-shortcut/traffic/views` and `/traffic/clones` (14-day
   window — record them each run precisely because the API forgets). Release cadence:
   `gh release list --limit 5`.
3. **Website:** run `bash scripts/web-traffic-report.sh --days 14` — it reads the site's Cloud
   Run request logs and reports visits, entry paths and external referrers. Trust the
   **referrer table** over the visit counts: undeclared crawlers inflate IP counts, and the
   script prints a CAVEAT when it detects them. Site→App-Store clicks are still unmeasured
   (gap #1 PARTIAL, gap #6). Check `plans/instrumentation-gaps.md` before writing
   "unmeasured" anywhere, and do not re-argue a registered gap in prose. If a measurement gap
   blocks a factor of the value equation, an instrumentation fix ranks above any feature
   recommendation of comparable size — say so.
4. **Where effort actually went:** `git log --oneline --since="3 weeks ago"` — cluster
   commits into 3–5 themes with rough share. This is what "alignment" is judged against.
5. **Product health, don't recompute it:** read the newest `../business/usage-reviews/LATEST.md`
   and open entries in `plans/improvement-ledger.md`. Note honestly: local usage logs are
   the developer's own usage, not customers' — they measure product quality, not demand.
6. **Competitors** (light touch): one WebSearch pass for pricing/positioning moves by the
   usual suspects (superwhisper, Wispr Flow, MacWhisper, VoiceInk). A deep dive is
   `/competitor-teardown`'s job, not yours — reference `plans/research/` if fresh teardowns
   exist. Note anything that changes OUR pricing/positioning calculus, ignore the rest.

## Phase 2 — First-principles decomposition

Write the value equation from the physics of the business and fill it with Phase 1 numbers:

```
proceeds = impressions × (view rate) × (download rate) × (activation) × (paid conversion / price)
```

The **bottleneck is the factor with the worst ratio relative to what is physically
plausible** — not the one that is most fun to fix. Compare against the previous run's
numbers: did the last recommendation move its factor?

## Phase 3 — The Verdict

Output, in this order, short:

1. **Bottleneck** — one sentence, with the number that proves it.
2. **Alignment** — was the last 3 weeks' effort pointed at it? Blunt yes/no, with the
   commit-theme evidence.
3. **Do this next** — one concrete, shippable move (days, not months). Sanity-check it:
   question the requirement → can deleting something fix it → simplify → only then build.
4. **Stop doing** — the one current activity with the worst effort-to-goal ratio.
5. **Falsifier** — the metric + threshold that will show, by the next run, whether this
   was right.

Then append one dated entry (goal, ~10 key numbers, bottleneck, recommendation, falsifier,
grade of the previous entry) to `../business/growth-ledger.md`, following the rules at the top of
that file.

## Ground rules

- **Report-only** except `../business/growth-ledger.md` and the digest. No code, no metadata
  changes in App Store Connect (`asc` is used strictly read-only), no commits, no pushes.
- **One bottleneck.** Secondary observations get at most one line each at the end.
- **"Change nothing, keep going" is a valid verdict** when the data says the current
  course is right — say it and keep the report short. Do not manufacture a pivot to fill
  the template.
- **Be blunt.** This runs to correct course, not to reassure.
- Language: interactive runs answer in the user's language; scheduled reports are English.

# Instrumentation gaps — the register

Every self-improvement loop is capped by what it can measure. A gap re-listed across runs
in prose is a gap nobody is closing — so gaps live here instead: one row, one gap, until it
is closed. Pattern adopted from `~/sabaki.dance.v3/docs/instrumentation-gaps.md`.

**Why gaps rank above features.** Closing a measurement gap is a few lines, its blast
radius is one logged field, and it widens what every later loop run can decide. A loop
proposing work should rank an instrumentation fix above any feature proposal of comparable
size, and say so. (Unlike Sabaki, no loop in this repo writes code autonomously — gap fixes
still land through an interactive session; they just go first.)

**Status values:** `OPEN` · `BUILT` (committed, not yet in a shipped release) · `PARTIAL` ·
`CLOSED` (live and producing usable data; keep the row with its close date) · `DROPPED`
(not worth measuring; keep the row and say why).

**Rules:** loop runs update this file instead of re-listing gaps in prose (updating a
status row is within rung 0). New gaps need the loop that is blind because of them.

## The register

| # | Gap | Blinds | Status | Notes |
| - | --- | ------ | ------ | ----- |
| 1 | The marketing site (`../web/`) has no analytics at all — visits, referrers, and page→App-Store click-through are invisible | growth-review's funnel top (traffic → product-page views) | PARTIAL | **Closed for arrivals, still open for exits (2026-08-18).** `scripts/web-traffic-report.sh` reads the Cloud Run request logs the site already writes — visits, entry paths and external referrers, with no analytics provider, no account, no script tag and no consent banner (fits the "no account, no backend" positioning). Limits: IP-based counting, undeclared crawlers inflate it (the script warns when sub-page counts go uniform), ~30-day log retention. **Exit hop BUILT 2026-08-18, live after next deploy:** `/go/appstore?src=…` (302 via `web/public/serve.json`) — every site→store click hits the Cloud Run log before leaving. Wired into hero (`src=web-hero`), features (`web-features`), download (`web-download`) and the GitHub README (`github-readme`); structured-data/canonical URLs keep the direct Apple link. Verified locally: 302 → App Store, other routes 200. Attribution = filter request logs for `/go/appstore` |
| 2 | Local usage logs cover only the developer's own usage — customer **feature-level** behavior (which features are used, where people get stuck) is unmeasured | usage-review measures product quality, not demand | PARTIAL | In-app telemetry stays deliberately absent (privacy-first is the differentiator). **Churn and engagement are NOT blind — measured 2026-08-18, recipe below.** What remains blind is feature granularity: Apple's `App Sessions` covers only opted-in devices (July: 7 devices, 35 sessions) — too thin to rank features. Closing that further is a product decision (opt-in sharing), not a loop decision |
| 3 | App Store customer reviews are only read when a growth run happens to fire — no ingestion between runs, no reply tracking | growth-review (customer voice), usage-review (failure reports from customers) | PARTIAL | **Daily ingest BUILT 2026-08-20** — `scripts/sales/discover.py` pulls `asc reviews list --paginate --include-response` into each sales-scout hit dump; unreplied reviews can become `review-reply` drafts. Growth-review still does not diff reviews itself on Saturday — that remaining slice is a one-line add to `review-growth` Phase 1 if the Saturday digest should cite them |
| 4 | GitHub traffic API forgets after 14 days — views/clones older than that are gone unless recorded | growth-review trend lines | PARTIAL | review-growth records the 14-day window in each ledger entry; biweekly cadence means gaps when a run is skipped. A tiny weekly `gh api` append job would close it fully |
| 6 | Apple's analytics reports are pulled ad-hoc; the install/delete/session series is not part of any scheduled run | growth-review's retention and activation factors — it graded them "unmeasured" in G1 although the data existed | OPEN | Recipe verified 2026-08-18 (below). Add it to `review-growth` Phase 1 so every run reads churn instead of assuming it |
| 7 | No App Store campaign attribution — every store link (`README.md:13`, `web/app/site.ts:6`, GitHub release bodies) is untagged, so App Store Connect cannot say which channel produced a download | growth-review's channel attribution: the site, the README and the release notes are indistinguishable in ASC | OPEN | Blocked on one **manual** step: the campaign provider token (`pt=`) lives in App Store Connect → App Analytics → Acquisition → Campaigns and is **not exposed by the `asc` API** (verified 2026-08-18 — no subcommand, config fields empty). Once the token is known, adding `?pt=<token>&ct=github-readme\|web-hero\|release-notes` to those three links is a 10-minute change. Alternative that needs no Apple token: **BUILT 2026-08-18** — README, hero, features and download CTAs now route through the own-domain `/go/appstore?src=…` redirect (see gap #1), so channel attribution comes from the Cloud Run logs. The Apple-side `pt` token remains worth adding once read from the ASC web UI (it would additionally attribute inside App Analytics itself); release-note bodies still untagged |
| 5 | The macOS rating count and average are unreadable — `asc reviews ratings --app 6749648401 --all` returns `0.00 avg / 0 total ratings across 0 countries` although 3 written reviews exist | growth-review's last funnel stage (ratings/reviews), and any read on whether App Store search ranking is rating-driven | OPEN | Added by growth-review G1 (2026-08-18). Likely an API/platform limitation for macOS apps rather than a real zero. Workarounds to test: the App Store product page itself, or `asc reviews summarizations`. Until closed, ratings are written "unmeasured" and only the review *count* (3, newest 2026-05-31) is usable |

## Recipe — reading Apple's install / delete / session series

Verified 2026-08-18. Apple already collects this; nothing needs building. The ONGOING analytics
request for app `6749648401` is `372de8e4-ef14-4173-8889-6635687573f2` and carries 156 reports.
Set `ASC_TIMEOUT=180s` — the default times out on these endpoints.

```bash
# 1. list the reports (r6 = App Store Installation and Deletion Standard, r8 = App Sessions Standard)
ASC_TIMEOUT=180s asc analytics view --request-id 372de8e4-ef14-4173-8889-6635687573f2

# 2. list a report's instances, then check each one's granularity + processingDate
ASC_TIMEOUT=180s asc analytics reports links --report-id r6-372de8e4-ef14-4173-8889-6635687573f2 --paginate
ASC_TIMEOUT=180s asc analytics instances view --instance-id <uuid>

# 3. download (TSV.gz): Date, Event, Download Type, App Version, Territory, Counts, Unique Devices
ASC_TIMEOUT=180s asc analytics download --request-id 372de8e4-… --instance-id <uuid> --output out.tsv.gz
```

**Caveats that decide how the numbers may be read:**

- A WEEKLY instance may contain the **whole weekly history**, not one week — check the `Date`
  column before reporting a total as "this week". The 2026-08-14 instance held 2025-12-29 → 2026-08-03.
- `Unique Devices` is per row, and rows are split by app version. Summing across rows counts one
  device once **per version it installed** — in July, 144 update events spread over 22 versions.
  Never report that sum as a headcount; the largest single-version figure (19) is the safer floor.
- Session/crash data covers only devices whose users allowed sharing with developers; install and
  delete data is far denser. Use ratios and trends, not absolute headcounts.
- `App Opt In` (r189) has no instances for this app, so the sampling rate cannot be quantified.

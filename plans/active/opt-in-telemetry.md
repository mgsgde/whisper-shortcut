# Opt-in Anonymous Usage Statistics — Counts From Real Users, Off by Default

**Status:** **Slices A–E implemented (2026-09-29); ships with 8.30, submitted to App Store review 2026-10-02.** Server deployed
(`whisper-telemetry`, europe-west1; request-log exclusion and BigQuery sink live, verified end to
end with test pings `app: "0.0"`). Client in `WhisperShortcut/Telemetry/`, UI in
`Settings/Components/UsageStatisticsSection.swift`, 14 tests in `TelemetryTests.swift`, report in
`scripts/telemetry-report.sh`, review-growth Phase 1 reads it.

**Before the release ships (human steps) — all three verified done 2026-10-02:** DNS resolves and `/health` answers 204; App Privacy label published; web privacy/FAQ live.
1. DNS at IONOS: `t` CNAME → `ghs.googlehosted.com.` (the app posts to `https://t.whispershortcut.com/v1/ping`;
   the Cloud Run domain mapping exists and waits for it). Until then every send fails silently and is retried.
2. App Store Connect → App Privacy: change the label as in the table below.
3. Parent repo: `web/app/privacy/page.tsx` and `web/app/faq.ts`.

**Deviations from the plan, found while building:**
- Schema gained count name `started` (Read Aloud, meetings) and milestone `telemetry.enabled`,
  which — not `dayIndex = 0` daily pings — is the cohort denominator: a day-0 user who quits and
  never relaunches never sends their day-0 daily, but did send `telemetry.enabled` on the spot.
- Failed daily sends are retried on the hourly flush, not once per launch: the app is a menu-bar
  app that runs for weeks, so "per launch" would mean "almost never".
- The server stores counts as `{key, n}` rows, not as the wire's keyed maps: a BigQuery log sink
  turns every distinct key into a column. The sink also lowercases field names and adds a column
  only once a row carried it, so `telemetry-report.sh` reads through JSON functions.
- `promptRetry` is still detected only when "Save usage data" is on (detection lives behind
  `ContextLogger`'s guard); every other signal is counted regardless.
- Not built: the one-time notice for existing users. They find the switch in Settings only.
**Audience:** LLM implementing the feature end-to-end
**Decision (Magnus, 2026-09-29):** build opt-in telemetry, **off by default**.
**Closes:** `plans/instrumentation-gaps.md` gap #2 (customer feature-level behavior is unmeasured —
*"closing that further is a product decision (opt-in sharing)"*). This is that decision.

---

## Why, and why the existing mechanisms are not enough

Every product decision is currently made from the developer's own usage logs. Customer behavior
is visible only through:

- **Apple App Analytics** — install/delete counts are dense, but sessions and crashes cover only
  devices that opted into sharing with developers. Too thin to rank features or locate drop-off.
- **The Usage Report** (`plans/active/usage-report-sharing.md`, shipped 2026-08-03) — correct and
  private, but it needs the user to open Settings, press a button and send a mail. In practice no
  reports arrive. A mechanism that depends on the user doing something extra produces no data.
- **App Store reviews and support mail** — useful for finding out *what* went wrong, rare, and
  biased toward extremes.

What none of them can answer, and what this plan must answer:

1. **Where new users drop out of onboarding and activation.** They might stop at the API key, at
   permissions, at the first dictation, or after a failed first dictation. This is the key
   question, and every other metric is less important.
2. **Retention by weekly cohort:** Day 1, Day 7 and Day 30.
3. **Which features are actually used,** and how often each one fails and why (error class, not text).
4. **Which models and providers are used,** and their failure rates.

---

## Non-negotiable constraints

1. **Off by default.** Nothing is sent until the user turns the switch on. Declining leaves no
   trace: no "declined" ping and no counter.
2. **Counts only, no content.** Never transcripts, prompts, replies, audio, clipboard, screenshots,
   file names, window titles, **target app bundle IDs**, or any text the user typed.
   Unlike the Usage Report, which the user reads before sending, this sends in the background,
   so it gets the stricter rule: `targetBundleId` is excluded.
3. **No identifier.** No install UUID, no hardware ID, no IP retained. Retention is computed from
   cohort fields (see "Retention without an ID"). This keeps the App Store label at
   *Not Linked to You* without argument.
4. **Our own endpoint, source public.** No SDK and no third party (no TelemetryDeck, PostHog,
   Sentry, Firebase). The receiving service lives in this repo (`server/telemetry/`), so the
   privacy claim can be audited like the app.
5. **Hard off in regulated settings.** Offline Mode forces telemetry off and hides the switch.
   An admin key (`defaults write` / MDM managed preference) forces it off permanently. This is
   required before any practice rollout.
6. **Nothing depends on Smart Improvement logging.** `ContextLogger.logSignal` returns early when
   `isLoggingEnabled` is false (`ContextLogger.swift:362`). Telemetry must count independently,
   otherwise it only sees users who also opted into Smart Improvement.

---

## What is sent

One JSON document per **active day** per install, plus immediate small pings for onboarding
milestones (see "Send schedule"). Every field is an enum value, a bool, or an integer count.
Free-form strings are rejected by the type system, not by review.

```json
{
  "v": 1,
  "app": "8.27",
  "build": "appstore",            // appstore | direct
  "os": "26",                     // macOS major only
  "cohortWeek": "2026-W40",       // ISO week of first launch
  "dayIndex": 3,                  // whole days since first launch (0 = install day)
  "kind": "daily",                // daily | milestone
  "setup": {
    "providers": ["gemini", "openai"],   // which keys are configured, never the key
    "offlineWhisperModel": true,
    "smartImprovement": false,
    "autoPaste": false
  },
  "counts": {
    "dictation.started": 14,
    "dictation.delivered": 12,
    "dictation.restart": 1,
    "dictation.cancelledWhileProcessing": 0,
    "dictation.noSpeech": 1,
    "dictation.noInputSignal": 0,
    "prompt.run": 3,
    "prompt.retry": 1,
    "prompt.noSelection": 0,
    "chat.turn": 6,
    "chat.retry": 0,
    "chat.stopped": 0,
    "chat.abandoned": 1,
    "readAloud.run": 0,
    "meeting.started": 0,
    "request.timedOut": 0
  },
  "models": { "transcription": { "gemini-3.5-flash": 12, "whisper-base": 2 },
              "chat": { "claude-opus-5-5": 6 } },
  "errors": { "transcription.http401": 1, "transcription.network": 0 }
}
```

- **Model IDs** are sent only if they appear in the app's own model enums (`TranscriptionModel`,
  `PromptModel`, `TTSModel`, the chat provider lineup). Custom endpoint and OpenRouter model
  strings are user-typed, so they are bucketed as `custom` / `openrouter`.
- **Error classes** come from an enum built from `AppErrors.swift` (HTTP status family, network,
  timeout, quota, invalid key, permission denied). Never an error *message*, because provider
  error bodies can echo input.
- **Milestone events** (`kind: "milestone"`, sent once per install):
  `onboarding.step.<WelcomeStep>` for each step reached, `onboarding.completed`,
  `activation.firstDictationDelivered`, `activation.firstDictationFailed.<errorClass>`,
  `activation.firstPrompt`, `activation.firstChat`.

The key set is a closed Swift enum (`TelemetryEvent`). Adding a key is a code change that passes
the leak test below, never a string built at a call site.

## Retention without an ID

Each daily ping carries `cohortWeek` and `dayIndex`, computed locally from a first-launch date
stored on the Mac. The client sends **at most one `daily` ping per calendar day**. So:

- cohort size = count of `dayIndex = 0` pings for that `cohortWeek`
- D1 / D7 / D30 retention = pings with `dayIndex` = 1 / 7 / 30 (or a window like 7–13) ÷ cohort size

This measures aggregates without ever linking two pings to one person. What is lost: individual
paths (e.g. "users who failed dictation on day 0 and still came back"). Milestone pings recover
the most important version of that, because `activation.firstDictationFailed.*` is counted per
cohort.

**The first-launch date must be recorded at first launch regardless of consent.** It is a local
date only, never sent unless the user opts in. Otherwise a user who opts in on day 5 would report
`dayIndex: 0`. Store it in `UserDefaults` (`firstLaunchDate`). For existing installs, fall back to
the earliest file in `UserContext/` or, failing that, the upgrade date, and flag
`cohortWeek: "pre-telemetry"` so they do not distort new-install cohorts.

---

## Consent UX

**Where:** the `privacy` step of onboarding (`WelcomeStep.privacy`, `WelcomeSteps.swift`
`WelcomePrivacyStep`), directly below the Offline Mode card. It must come **before** `apiKeys`,
because the API key step is the most likely drop-off point. Asking at the end would only
measure people who already made it through.

```
[ ] Share anonymous usage statistics
    Counts only — how often features are used and whether they worked.
    Never your words, audio, or which apps you use. No ID, no tracking.
    Helps a solo developer fix what actually breaks. [See exactly what is sent]
```

- Toggle defaults to **off**. Neutral wording: no dark patterns, no pre-checked box, no nagging
  later. It is asked **once** in onboarding. Existing users see it once as a single dismissible
  row in the next release's "What's new" or a Settings banner. After that there are no more prompts.
- Hidden and forced off while Offline Mode is on.
- **Settings → Privacy & Permissions:** the same toggle plus **"Show what's sent"**. It opens a
  sheet with the exact pending JSON, pretty-printed, and the last sent payload. Reuse the
  presentation pattern of `UsageReportSheet`.
- **Turning it off** deletes the pending buffer immediately. It does not delete the local
  first-launch date, because that date was never sent.

### Buffering before consent

Onboarding milestones before the toggle (only `onboarding.step.intro`) are held in memory.
If the user turns the toggle on during onboarding, they are sent with the rest. If they do not,
they are discarded. Nothing is written to disk before consent.

---

## Send schedule

- **Milestones:** sent immediately (best effort, one retry on next launch). Onboarding and
  day-0 activation are exactly the sessions that end with the app quit forever. A daily batch
  would never send them.
- **Daily counts:** the previous active day's counts are sent on the first launch or wake of
  a new day, and in `applicationWillTerminate` (`FullApp.swift:186`) as a fire-and-forget
  attempt with a ~2 s cap.
- Pending counts are persisted in a small JSON file in Application Support. Add it to
  `Docs/data-directories.md`. Days older than 7 that were never sent are dropped, not piled up.
- Transport: `URLSession` ephemeral configuration, no cookies, no cache, 10 s timeout. Failures
  are silent (DebugLogger only). No retry storm, at most one attempt per launch per pending day.
- Sending **never** blocks the main thread or any user-facing request.

---

## Server (`server/telemetry/`)

A tiny Cloud Run service in GCP project `whisper-shortcut`, same region as `web/deploy.sh`.

- `POST /v1/ping` accepts `application/json` ≤ 4 KB and returns `204`. Anything else returns `400`.
- Validates against the same closed key set (a shared JSON schema file checked into the repo,
  used by both the Swift tests and the server). Unknown keys are **dropped**, not stored.
- Writes the validated document as one structured JSON line to stdout. It never logs headers,
  IP or user agent.
- **Cloud Logging:**
  - Log **exclusion** filter on `run.googleapis.com/requests` for this service, so the
    platform request log (which records client IP) is never stored.
  - Log **sink** from the service's stdout to BigQuery dataset `telemetry`, table expiration
    400 days.
- `min-instances=0`, `max-instances=2`, no authentication (the data is anonymous counts; abuse
  can only pollute, not leak). Add a per-IP in-memory rate limit (e.g. 30/h) against accidental
  client loops. The IP lives in memory only and is never persisted.
- Language: whatever builds smallest on Cloud Run (Go or Node, ~100 lines). Include a
  `deploy.sh` mirroring `web/deploy.sh`.
- Custom domain: `t.whispershortcut.com` or a path on the existing domain. **Not** the raw
  `*.run.app` URL, so the app does not depend on a Google-generated hostname.

App side: the App Store build is sandboxed and already has `com.apple.security.network.client`
(needed for cloud models). Verify rather than assume.

---

## Implementation slices

### Slice A — Server
`server/telemetry/` with the service, `deploy.sh`, schema file, log exclusion, BigQuery sink.
**Done when:** a `curl` POST lands a row in BigQuery, the request log shows no stored entry for
the service, and a payload with an unknown key is stored without that key.

### Slice B — Client core (`WhisperShortcut/Telemetry/`)
- `TelemetryEvent` (closed enum), `TelemetryPayload` (Codable, only enum/int/bool fields).
- `TelemetryStore`: in-memory counters, persisted pending days, first-launch date.
- `TelemetryService`: consent state, kill switches, send schedule, injectable transport.
- UserDefaults keys in `UserDefaultsKeys.swift`: `telemetryEnabled` (default false),
  `firstLaunchDate`, admin override `telemetryForceDisabled` (read via `UserDefaults.standard`,
  which picks up managed preferences).
- Effective state = `telemetryEnabled && !offlineMode && !telemetryForceDisabled`.

### Slice C — Wiring
- Feed outcome signals into telemetry **before** the `isLoggingEnabled` guard in
  `ContextLogger.logSignal`: one line, `TelemetryService.shared.count(kind, mode:)`. This makes
  every existing and future `OutcomeSignal` count automatically. `TelemetryService` maps signal
  kinds to `TelemetryEvent` itself and drops the `detail` dictionary entirely.
- Starts and runs: at the same call sites that call `ContextLogger.logTranscription` /
  `logPrompt` / `logChat` (model ID only, never the text arguments), plus Read Aloud and meeting
  start.
- Errors: at the point where errors are shown to the user, map to the error-class enum.
- Onboarding milestones: `WelcomeView` step changes and completion.
- Activation milestones: first delivered / failed dictation, first prompt, first chat.

### Slice D — UI
Onboarding toggle in `WelcomePrivacyStep`, Settings toggle and "Show what's sent" sheet in
`PrivacyPermissionsTab`, and the one-time notice for existing users.

### Slice E — Docs, privacy, label, analysis
See the table below, plus `scripts/telemetry-report.sh` (bq queries for the funnel, cohort
retention, feature usage and error classes). Wire it into the `review-growth` Phase 1 and
`analyze-user-interactions` so the loops read it instead of assuming blindness. Update gap #2 in
`plans/instrumentation-gaps.md` to `BUILT`, then `CLOSED` once data flows.

**Order:** A → B → C → D → E. E's privacy label change is a **manual** App Store Connect step
and must be done **before** the release that contains B–D is submitted.

---

## Privacy text and disclosure changes (Slice E — do not skip)

Everything that currently says "no telemetry" / "we don't run a server" becomes false with this
feature, even though it is opt-in. Every sentence must be rewritten, not just added to.

| File | Change |
|---|---|
| `WhisperShortcut/PrivacyCopy.swift:9` | Replace with: *"No third-party tracking. Optional anonymous usage statistics (off unless you turn them on): counts only — never your words, audio, or which apps you use — sent to our own small server, whose code is public."* |
| `WhisperShortcut/PRIVACY.md:7` | Rewrite the "no telemetry … no server" sentence. Add a section **"Anonymous usage statistics (optional)"** listing every field category above, what is never sent, retention (400 days), no IP storage, how to turn it off, and the admin key. |
| `privacy.md:15` | Same change as `PRIVACY.md`, plus keep the Usage Report paragraph. |
| `plans/active/usage-report-sharing.md` | Its App Store label section says *"Re-check only if the app ever gains an automatic or background send path."* This is that path. Add a line pointing here. |
| `README.md` `## Features` | Mention the opt-in statistics toggle (the in-app Chat reads this README). |
| `../web/app/privacy/page.tsx`, `../web/app/faq.ts` | Both mention telemetry; update them to match `privacy.md`. This is the parent repo, so a separate commit. |
| **App Store Connect → App Privacy** (manual, Magnus) | Change from *Data Not Collected* to: **Usage Data → Product Interaction** and **Diagnostics → Other Diagnostic Data**, both *Not Linked to You*, *Not used for Tracking*, purpose **Analytics**. The optional-disclosure exemption does **not** apply, because background sending fails Apple's "provided by the user in the app's interface each time" criterion. |

Marketing implication worth knowing before shipping: the store listing loses "Data Not Collected".
That is the price. The counter-message is that it is off by default and the server code is public.

---

## Tests (`WhisperShortcutTests/TelemetryTests.swift`)

1. **Leak test:** run every `ContextLogger` entry point with sentinel strings as transcript,
   prompt, reply, bundle ID and error message. Encode the payload and assert that no sentinel
   occurs. Mirrors the Usage Report leak test.
2. **Off means silent:** with the toggle off, Offline Mode on, or `telemetryForceDisabled`, the
   injected transport records zero calls across a full simulated day and onboarding.
3. **Decline discards:** milestones buffered before consent are gone after declining. No file
   is written.
4. **One daily ping per day:** multiple launches on one day produce one `daily` payload.
   A day with no activity produces none.
5. **dayIndex / cohortWeek:** correct across DST and year boundaries (ISO week 53).
6. **Model bucketing:** a custom-endpoint model string becomes `custom`.
7. **Size:** a payload with every event and every known model stays under 4 KB.
8. **Schema parity:** the Swift `TelemetryEvent` cases equal the keys in the shared schema file
   the server validates against.

---

## How we will know it worked

Four weeks after the release reaches users:

- **Opt-in share** ≈ `dayIndex = 0` milestone pings ÷ Apple first-time downloads over the same
  window. Below ~10 % means the consent wording is failing. Revise the wording before drawing
  conclusions from the data. Never change the default to get a higher share.
- The onboarding funnel names **one step** where most drop-off happens. That step becomes the
  next growth-review bottleneck candidate.
- Treat all numbers as a **self-selected sample.** People who opt in are more engaged than
  average. Trust ratios within the sample (e.g. which step loses people) more than absolute
  retention.

## Risks

- **Positioning loss** from the label change (see above). Accepted by the decision.
- **Sample bias:** see above.
- **Regulated users:** a practice install with Offline Mode off and the toggle turned on by a
  curious user. Mitigation: `telemetryForceDisabled` in the rollout checklist for every managed
  install, not only Offline Mode.
- **Schema drift:** a new feature ships without a telemetry event and stays invisible.
  Mitigation: signals are counted automatically through `logSignal`, so only new
  *start* events need a manual line.

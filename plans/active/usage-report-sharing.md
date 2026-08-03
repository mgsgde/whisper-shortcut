# Share Usage Report — Let a User Hand Over What the App Learned About Itself

**Status:** **Slices A–D implemented (2026-08-03).** Slice D landed together with outcome-signals
Slice 2: the Chat block now carries a retry rate and a stop count. 157 tests pass.

Three rules the chat lines follow, each of them a correction to something that was wrong first:

1. **Stops are a count, never a rate.** A send killed mid-stream never reaches `logChat` and never
   becomes a logged turn, so `stops / turns` divides by a set that excludes exactly the events
   being counted.
2. **Rates are clipped to the window on both sides.** Numerator and denominator share one start,
   or the rate exceeds 100%.
3. **Unattributable verdicts are counted, not rated.** Verified against real logs — see below.

**Status:** **Slices A–C implemented (2026-08-03).** `UsageReport.swift`, `UsageReportSheet.swift`,
the button in `SupportFeedbackSection`, `UsageReportTests.swift` (7 tests), and the disclosure text
in `privacy.md` / `PRIVACY.md` / `README.md`. Build and 153 tests pass; the sheet was driven and
screenshotted against real logs. Slice D (chat retry/stop lines) waits on outcome-signals Slice 2.

One correction the plan did not anticipate, found by reading the first real report rather than by
testing: rates must be measured over the dictations that *could* have produced a signal, not over
every dictation in the window. Signals shipped weeks after interaction logging, so the naive
denominator rendered a near-perfect delivery rate as `2.7% delivered`. The window is anchored on
`refTs` — the interaction each signal judges — not on the signal's own `ts`; anchoring on `ts` puts
the first judged dictation outside the denominator while its verdict stays in the numerator, which
produced `102% delivered`. Every future signal will reintroduce this skew on the day it ships.

A third correction came from the first `chatRetry` signals a real machine ever produced: all four
carried `refTs: null`, because the user pressed Retry on an answer from before an app relaunch and
the marker is in-memory only. Both obvious readings are wrong. Requiring `refTs` discards them and
removes the Chat rate line entirely. Counting them against a window anchored on their own
timestamps divides by a denominator that excludes the very turns they judge — on that data it read
as a **33% retry rate** for a machine whose real rate was far lower. Unattributable verdicts are
therefore reported as a bare count with no rate attached, which is the only form that is true.
This is not an edge case: it recurs after every app update.
**Audience:** LLM implementing the feature end-to-end
**Goal:** Give the developer real usage data from real users *without* running a server, without
background transmission, and without weakening the privacy promise the app already ships.

Depends on: `plans/active/outcome-signals.md` Slice 1 (implemented). Chat metrics need its Slice 2.

---

## Why this shape and not analytics

The app already tells users, in text they see:

- `WhisperShortcut/PrivacyCopy.swift:9` — *"No hidden telemetry and no third-party tracking — we don't run a server."*
- `privacy.md:15` — *"No analytics or tracking."*
- `privacy.md:131-132` — no personal information for analytics, no usage analytics

That is a feature, not a footnote, for a dictation tool. So the design constraint is absolute:
**the app never transmits anything by itself.** The report is composed locally, shown to the user
in full, and leaves the Mac only when the user presses Send in *their own* Mail or WhatsApp client.
Every word of the promise above stays literally true, and no server, no SDK, and no third party
enters the picture.

The data already exists. `UserContext/signals-YYYY-MM-DD.jsonl` was built content-free on purpose
(`ContextLogger.swift:34-36`: *"That is the property that makes the stream safe to aggregate"*).
This plan is the first consumer that cashes in that property.

---

## What the report looks like

Plain text, deliberately short — it has to survive a `mailto:` / `wa.me` URL, which is where
`FeedbackLinks` puts its payload. Target ≤ 1200 characters; hard-cap enforced in code.

```
WhisperShortcut usage report — last 30 days
App 7.97 (App Store build) · macOS 26.1 · report v1

Dictation
  1284 dictations · 96% delivered · 4.1% restarted (52)
  median restart gap 8.2 s
  models: gemini-3.5-flash 71% · whisper-base 24% · gpt-4o-transcribe 5%

Dictate Prompt
  212 runs · 6 cancelled while processing (2.8%) · screenshot attached in 38%

Chat
  431 turns · models: gemini-3.1-pro 62% · claude-opus-5 21% · grok-5 17%

Pasted into
  com.tinyspeck.slackmacgap 41% · com.apple.mail 22% · com.microsoft.VSCode 18%

Active on 24 of 30 days
---
Counts and timings only — no transcripts, prompts, replies, or audio.
```

Rules for the content:

- **Omit, never fake.** A section with no data is left out entirely. Chat retry/stop rates do not
  exist until outcome-signals Slice 2 ships — do not print `0%` for them.
- **Percentages plus absolute counts.** `4.1%` alone is unreadable when n = 12.
- Round timings to 0.1 s; never emit a raw `gapMs` list (a timing sequence is a behavioural
  fingerprint, an aggregate is not).

---

## Design

### 1. `UsageReport` — the aggregator

New file `WhisperShortcut/UsageReport.swift`. One `enum UsageReport` with a single public entry
point:

```swift
static func build(lastDays: Int = 30) -> String
```

It reads through the existing accessors — `ContextLogger.shared.signalLogFiles(lastDays:)` and
`interactionLogFiles(lastDays:)` — and returns the rendered string. No file writing, no state.

**The privacy guarantee is a type, not a promise.** The interaction stream is full of user text.
The aggregator must decode it through its own narrow struct, so content fields are never even
materialised in memory:

```swift
/// Deliberately narrow. Decoding through this instead of `InteractionLogEntry` means the report
/// physically cannot leak content — not even if someone later adds a field upstream.
/// Never add `result`, `selectedText`, `userInstruction`, `modelResponse`, `text`, or `audioRef`.
private struct InteractionMetaEntry: Decodable {
  let ts: String
  let mode: String
  let model: String?
  let transcriptionModel: String?
  let hadScreenshot: Bool?
}
```

Signals decode through the existing `SignalLogEntry` — it is already content-free by contract.

### 2. Metrics and how each is computed

| Line | Source | Computation |
|---|---|---|
| dictations | `interactions-*.jsonl` | count of `mode == "transcription"` |
| delivered % | `signals-*.jsonl` | `pasted` count ÷ dictations |
| restarted % | `signals-*.jsonl` | `dictationRestart` ÷ dictations, **only over signals whose `detail["autoPasteAvailable"] == "true"`** |
| median restart gap | `signals` | median of `gapMs` on `dictationRestart` |
| transcription model mix | `interactions` | histogram of `transcriptionModel`, top 3, `%` of total |
| Dictate Prompt runs | `interactions` | count of `mode == "prompt"` |
| prompt cancel % | `signals` | `cancelledWhileProcessing` with `mode == "prompt"` ÷ prompt runs |
| screenshot % | `interactions` | `hadScreenshot == true` ÷ prompt runs |
| chat turns | `interactions` | count of `mode == "geminiChat"` |
| chat model mix | `interactions` | histogram of `model` for chat rows, top 3 |
| pasted into | `signals` | histogram of `detail["targetBundleId"]` on `pasted`, top 3 |
| active days | both | distinct `ts` dates present |
| header | `AppConstants.appVersion`, `ProcessInfo`, `#if APP_STORE` | build variant matters — see caveat below |

**The App Store caveat, restated because it decides how useful this is.** `autoPasteIfEnabled()`
returns `false` under `#if APP_STORE`, so `pasted` never fires there and `dictationRestart` is
gated out with it (`ContextLogger.noteDictationStart` requires an unpasted marker). In an App Store
build the report therefore has *no* delivery and *no* restart line, and the "Pasted into" section
is empty. That is most of your users. Handle it honestly:

- Print `delivery/restart metrics unavailable in App Store builds (no auto-paste)` instead of
  silently dropping the section, so a thin report is self-explaining rather than looking like low usage.
- Do **not** invent a substitute signal from `NSPasteboard.changeCount` — outcome-signals already
  ruled that out, and a wrong signal is worse than a missing one.
- The real fix is a build-independent verdict affordance (see Open questions).

### 3. The review sheet

New `WhisperShortcut/Settings/Components/UsageReportSheet.swift`.

- Shows the **complete** report text in a selectable, scrollable monospaced view. Not a summary of
  the report — the literal string that will be sent. Consent means seeing the payload.
- Buttons: `Copy`, `Send via Email`, `Send via WhatsApp`, `Cancel`.
- Send buttons call `FeedbackLinks.open(.email, context: report)` / `.whatsApp`. That reuses the
  existing prefill path, so the report arrives with app version and macOS version attached
  (`FeedbackLinks.environmentBlock`) and the user still presses send in their own client.
- One line of copy under the text: *"Nothing is sent automatically. This text is composed on your
  Mac; pressing Send opens your mail app with it prefilled."*

### 4. Entry point

In `SupportFeedbackSection.swift`, a fourth button in the existing stack — same
`Image + Text + Spacer` row style as its neighbours, `chart.bar.doc.horizontal` icon — labelled
**"Share Usage Report"**, with help text *"See and share an anonymous summary of how you use the app"*.

Gating: the report needs `UserDefaultsKeys.contextLoggingEnabled`. When it is off, keep the button
visible but disabled with help text *"Turn on 'Save usage data' in Improvement settings to collect
this."* — invisible-when-off would just make the feature undiscoverable.

Do **not** add it to the menu bar `Send Feedback` submenu in this slice. That submenu is the
"something is broken right now" path; a usage report is a considered act, and mixing them makes the
error path longer.

---

## Slices

| Slice | Content | Done when |
|---|---|---|
| **A** | `UsageReport.swift` + `InteractionMetaEntry` + tests | `run-tests.sh` green, including the leak test |
| **B** | `UsageReportSheet` + button in `SupportFeedbackSection` + gating | `rebuild-and-restart.sh` green, sheet visually verified |
| **C** | Privacy + docs text (below) | all four files updated |
| **D** | *later* — chat retry/stop lines, once outcome-signals Slice 2 ships | report gains a Chat quality line |

A is worth doing alone: `UsageReport.build()` is immediately useful from a debug menu or a test,
and it is the part with the privacy-critical property.

---

## Tests (`WhisperShortcutTests/UsageReportTests.swift`)

Swift Testing, mirroring `FeedbackLinksTests.swift`'s style and its rationale comment.

1. **The leak test — the reason this file exists.** Write fixture `interactions-*.jsonl` rows whose
   `result` / `userInstruction` / `modelResponse` contain unmistakable sentinels
   (`"SENTINEL-TRANSCRIPT-9F2A"` etc.), build the report, assert none appear in the output. This is
   the test that has to survive every future edit to the report.
2. **Percentages match hand-computed fixtures** — 10 dictations, 8 `pasted`, 1 `dictationRestart`
   with `autoPasteAvailable=true` → `80% delivered`, `10% restarted`.
3. **Restart signals with `autoPasteAvailable=false` are excluded** from the restart rate.
4. **Empty sections are omitted**, not rendered as `0%`.
5. **Length cap** — a fixture with 40 distinct models and 60 bundle IDs still yields ≤ 1200 chars,
   and the resulting `mailto:` URL builds (`FeedbackLinks.url(for: .email, context: report)` non-nil).

---

## Privacy and docs changes (Slice C — do not skip)

| File | Change |
|---|---|
| `privacy.md:15` | Keep *"No analytics or tracking."*, append: *"The app never sends usage data anywhere on its own. The optional Usage Report is composed on your Mac, shown to you in full, and only leaves your machine if you press Send in your own mail or WhatsApp client."* |
| `privacy.md:131-132` | Add a short **"What you can choose to send"** section naming exactly the fields listed in the metrics table, and stating that transcripts, prompts, replies and audio are never included. |
| `WhisperShortcut/PRIVACY.md` | Mirror both edits — this is the copy bundled into the app. |
| `WhisperShortcut/PrivacyCopy.swift:9` | **Leave unchanged.** "No hidden telemetry and no third-party tracking — we don't run a server" remains true: nothing here is hidden, third-party, or server-backed. Changing it would weaken a true claim. |
| `README.md` `## Features` | Add the feature. Required by the workspace rule: the in-app Chat reads this README via `read_whisper_shortcut_doc`, so an unlisted feature is one the app itself denies having. |

**App Store privacy label — checked 2026-08-03, no change needed.** Apple's optional-disclosure
criteria (developer.apple.com/app-store/app-privacy-details) require *all* of: not used for
tracking; not used for third-party advertising, the developer's own advertising/marketing, or
"Other Purposes" (analytics is **not** on that exclusion list, so product improvement is fine);
collected only infrequently, outside the app's primary functionality, and optional for the user;
and provided by the user in the app's interface, with what is collected made clear and the user
affirmatively choosing to provide it each time.

The report meets these. The one clause worth naming is "the user's name or account name is
prominently displayed in the submission form" — here the submission form is the user's own mail
composer or WhatsApp thread, where their identity is unavoidably visible, and the sheet says so
before they get there.

The stronger argument is that this introduces no new mechanism at all: the app already prefills
error text (`PopupNotificationWindow` → Contact Support) and chat excerpts (`/feedback`) into the
same `mailto:` / `wa.me` flow and ships today with "Data Not Collected". The usage report changes
what is prefilled, not how anything is transmitted. Re-check only if the app ever gains an
automatic or background send path — that would fail criterion 3 immediately.

---

## Risks and open questions

- **App Store builds produce a thin report.** Covered above; the honest-label approach ships, but it
  means the headline quality metric is missing for the majority of users. Open: add a build-
  independent verdict affordance (an explicit "that was wrong" shortcut, or treating a Dictate Prompt
  re-run as a verdict) so restart-rate exists everywhere. Belongs in outcome-signals, not here.
- **`targetBundleId` names the user's apps.** This is the single most actionable product datum
  (where dictation actually gets used) and the user reads it in the sheet before sending, so the
  recommendation is to include the top 3. If that ever feels wrong, dropping the section is one
  line — keep it isolated in its own render function so it stays that way.
- **Selection bias.** Only engaged users will send a report, and their numbers will look better than
  reality. Treat it as qualitative evidence for *what breaks*, never as a population estimate.
- **`detail` drift.** The report reads `detail` keys directly. If a future signal puts user text in
  `detail`, the leak test does not catch it (fixtures only cover known keys). Mitigation: the report
  reads only an explicit allow-list of keys — `autoPasteAvailable`, `targetBundleId`, `phase`,
  `chars` — and ignores everything else. State this in a comment at the read site.

---

## Touch points summary

| File | Change |
|---|---|
| `WhisperShortcut/UsageReport.swift` | new — aggregator + narrow decoder |
| `WhisperShortcut/Settings/Components/UsageReportSheet.swift` | new — review + send sheet |
| `WhisperShortcut/Settings/Tabs/General/SupportFeedbackSection.swift` | "Share Usage Report" button, gated on `contextLoggingEnabled` |
| `WhisperShortcutTests/UsageReportTests.swift` | new — leak test + arithmetic + cap |
| `privacy.md`, `WhisperShortcut/PRIVACY.md`, `README.md` | disclosure + feature listing |

# Outcome Signals — Record Whether an Interaction Actually Worked

**Status:** **Slice 1 implemented (2026-08-02)** — `SignalLogEntry` + `OutcomeSignal` + `logSignal` / `noteDictationStart` / `signalLogFiles` in `ContextLogger.swift`, `AppConstants.outcomeSignalRestartWindow` (20 s), `AppState.signalPhase`, and the three dictation call sites in `MenuBarController`. Build and 97 tests pass. Stream lands in `UserContext/signals-YYYY-MM-DD.jsonl`. Slices 2–4 open.

Two deviations from the plan as written, both deliberate:

- The marker that `refTs` reads from is set **synchronously** at the top of `writeEntry`, not inside its `queue.async` block. Auto-paste posts its ⌘V 50 ms later; with the marker still queued behind disk I/O the `pasted` flag could land on nothing and turn the next dictation into a phantom `dictationRestart`.
- Live-meeting dictation segments do **not** emit `dictationRestart`. Speaking repeatedly into a meeting is normal use, not a retry, and would drown the signal. They still log interactions and still emit `pasted`.

**Slice 2 implemented (2026-08-03)** — `chatStopped` + `chatRetry` in `OutcomeSignal`, emitted from
`ChatViewModel.cancelSend()` / the `CancellationError` arm and from `retryMessage(id:)`. The
user-vs-watchdog split is done with a `userCancelledSessions: [UUID: Int]` dictionary written in
`cancelSend` and consumed once in the catch arm: by the time `CancellationError` is caught the two
cancellation sources are indistinguishable, so the verdict has to be stamped at the only place that
knows a human pressed Stop. `chatAbandoned` remains offline-derived; Slice 3 is open.

Confirmed live: `chatRetry` fires in real use. The first four ever recorded all carried
`refTs: null`, because the user pressed Retry on an answer from before an app relaunch and the
marker is in-memory only. That is the documented behaviour, but it means unattributable verdicts
are **normal after every update**, not an edge case — consumers must handle them (see
`plans/active/usage-report-sharing.md`, which reports them as a count rather than a rate).

Open before tuning: the 20 s window is a guess. Leave it collecting for a week, then check the `gapMs` distribution in the stream before changing it.
**Audience:** LLM implementing the feature end-to-end
**Goal:** Make it possible to tell, from data alone, whether a dictation / Dictate Prompt / chat turn *helped the user*. Today the logs record what happened, never whether it was any good.

---

## Why this exists (the problem it solves)

`InteractionLogEntry` (`ContextLogger.swift`) stores input, output, and model for three modes. It stores no verdict. Every downstream consumer therefore has to *guess quality from the text*:

- `/analyze-user-interactions` reads transcripts and judges them by re-reading the prose ("did 'korrigiere' actually correct?"). That is an LLM's opinion about its own output — the weakest possible evidence.
- `ContextDerivation` / Smart Improvement needs ≥2 recurrences of a *textual* pattern before it will change anything, which is exactly why it starves (memories: *smart-improvement-sample-starvation*, *smart-improvement-name-not-learned*).
- After shipping a change, nothing can say whether it made things better.

Meanwhile the app already *knows* when things went wrong and throws that knowledge away. The user restarts a dictation two seconds after a bad transcript. They hit Stop mid-stream. They press Retry on a chat answer. Every one of those is an unambiguous, content-free verdict, available at a call site that already exists.

This plan captures those verdicts as a **second, append-only signal stream** alongside the interaction log.

Non-goal: judging quality with a model. Signals are behavioural facts only.

---

## Design

### A separate stream, not a new field

Outcomes are known *after* the interaction row is written — sometimes minutes after. JSONL is append-only, so mutating the original line is out. Instead:

```
UserContext/signals-YYYY-MM-DD.jsonl
```

```jsonc
{"ts":"2026-08-02T10:14:03Z","kind":"dictationRestart","refTs":"2026-08-02T10:13:51Z","mode":"transcription","gapMs":12400,"detail":{"chars":213}}
```

| Field | Meaning |
|---|---|
| `ts` | when the signal fired |
| `kind` | see catalogue below |
| `refTs` | `ts` of the interaction being judged; `null` if none is known |
| `mode` | `transcription` \| `prompt` \| `geminiChat` |
| `gapMs` | ms between `refTs` and `ts`, when meaningful |
| `detail` | small kind-specific dictionary; **never** user text |

Why this shape:

- **No schema break.** `InteractionLogEntry` is untouched, so `ContextDerivation`, `GlossaryFastLearner` and every existing analysis keep working unchanged.
- **No content.** Signals hold counts and timings only. They are safe to summarise, aggregate, and eventually send in a bug report in a way the interaction log never will be.
- **Correlatable.** `refTs` joins back to the interaction row.

### How `refTs` is known

`ContextLogger` keeps an in-memory `lastEntryTs: [String: String]` (mode → ts), set inside `writeEntry`. `logSignal` defaults `refTs` to `lastEntryTs[mode]`. Not persisted across launches — a signal that fires after a relaunch simply carries `refTs: null`, which is honest and costs nothing.

### Gating and retention

Gated by the same `isLoggingEnabled` check ("Save usage data") as everything else in `ContextLogger`. Same 90-day `rotationDays`. Deleted by `deleteAllContextData()` for free, because it lives in the same directory — verify the reset path still covers it.

---

## Signal catalogue and exact call sites

Line numbers are as of 2026-08-02; find the function, not the line.

### Slice 1 — the dictation loop

| kind | Fires when | Call site |
|---|---|---|
| `pasted` | the synthetic ⌘V was actually posted | `MenuBarController.autoPasteIfEnabled()` :2146 — inside the `asyncAfter` block right after `simulatePaste()`, next to the existing `AUTO-PASTE: Pasted … chars` log. Reuse `chars` and the frontmost bundle id as `detail`. |
| `dictationRestart` | a new dictation starts soon after a completed one with no `pasted` in between | `MenuBarController.toggleTranscription()`, the `.none` arm (~:970) — the branch that calls `appState.startRecording(.transcription)`. Compare `now` against `ContextLogger.lastEntryTs["transcription"]`. Emit only when the gap is under the threshold. |
| `cancelledWhileProcessing` | the user killed a job before seeing a result | `cancelInFlightTranscription()` :1142 and `cancelInFlightPrompt()` :1155. `detail: {"phase": "<appState mode>"}`. |

**Threshold:** 20 s. Long enough to cover reading a bad transcript and re-pressing, short enough that a deliberate second dictation in a different context rarely lands inside it. Put it in `AppConstants` (`outcomeSignalRestartWindow`), not inline — it will need tuning against real data.

**App Store caveat — read before implementing.** `autoPasteIfEnabled()` returns `false` immediately under `#if APP_STORE`; there is no synthetic paste in that build. So `pasted` never fires there, and `dictationRestart` would fire on every normal back-to-back dictation. Two consequences:

1. `dictationRestart` must record `autoPasteAvailable: Bool` in `detail` so analysis can discard the signal where it is meaningless.
2. Do **not** try to detect a manual ⌘V. Watching `NSPasteboard.changeCount` tells us someone *wrote* to the pasteboard, never that the user pasted from it. A wrong signal is worse than a missing one.

### Slice 2 — chat

| kind | Fires when | Call site |
|---|---|---|
| `chatStopped` | the user pressed Stop mid-stream | `ChatViewModel.cancelSend()` :673. The `catch is CancellationError` arm :1027 already computes `partialChars` — emit there instead if the partial length is wanted, and keep `cancelSend` for the `dropped` queue count. Watch out: cancellation also arrives from `StallCancellationRegistry` (watchdog), which is *not* a user verdict — pass an explicit `reason: "user" \| "stall"` so the two never merge. |
| `chatRetry` | the user re-sent the same message | `ChatViewModel.retryMessage(id:)` :480. The strongest negative signal in the app: an explicit "that answer was not good enough". `detail: {"model": …}` so a model that gets retried disproportionately is visible. |
| `chatAbandoned` | a session got exactly one turn and was never returned to | Derived offline from `ChatSessionStore` timestamps. No code change. |

### Slice 3 — model switching and metrics

| kind | Fires when | Call site |
|---|---|---|
| `modelSwitched` | the selected model changes shortly after a result | wherever `selectedPromptModel` / `TranscriptionModel.loadSelected`'s counterpart is written — Settings save path (`SettingsViewModel`) and `ChatModelCommandResolver` for `/grok`-style commands. `detail: {"from": …, "to": …, "mode": …}`. Only emit when within a few minutes of a logged interaction; a switch made cold in Settings carries no verdict. |

Then `scripts/usage-metrics.py`: reads `interactions-*.jsonl` + `signals-*.jsonl`, appends one row per week to `plans/usage-metrics.csv`:

```
week, dictations, restartRate, pasteRate, promptRuns, promptCancelRate, chatTurns, chatRetryRate, chatStopRate, errorCount, p50LatencyMs
```

This is the file that makes shipped changes measurable — a change that was supposed to reduce restarts either moves `restartRate` or it did not work.

### Slice 4 — teach the analysers to use it

- `.cursor/skills/analyze-user-interactions/SKILL.md`: add the signal stream as **primary** data source, above the JSONL prose. New procedure step: rank clusters by signal weight first, *then* read the text of the flagged interactions. Change the ≥2-examples rule to "≥2 examples **or** one negative signal plus one example" — an explicit `chatRetry` is worth more than two guesses about prose.
- `ContextDerivation`: feed `dictationRestart` into candidate selection so audio verification prioritises transcripts the user visibly rejected. This directly attacks the sample-starvation failure mode — the sample stops being "the last 15 entries" and becomes "the entries the user was unhappy with".

---

## Implementation order and why

1. **Slice 1 first** — highest event volume, and dictation is the core loop. Also the smallest surface: one new method on `ContextLogger`, three call sites.
2. **Slice 2** — chat, where `chatRetry` is the single highest-quality signal in the whole system.
3. **Slice 3** — needs a few weeks of Slice 1+2 data before the metrics mean anything.
4. **Slice 4** — only worth doing once the stream has real volume.

Ship Slice 1, then leave it collecting for a week before tuning the 20 s threshold. The threshold is the one number here that cannot be reasoned out in advance.

---

## Risks

- **Threshold false positives.** Someone who dictates in rapid bursts into a chat window generates `dictationRestart` constantly. Mitigation: `autoPasteAvailable` + `pasted` in `detail` lets analysis separate the cases; revisit after real data.
- **Signal inflation.** If every user action becomes a signal, the stream stops meaning anything. Keep the catalogue at the size above; each entry must map to an action a user only takes when something went right or wrong.
- **Watchdog cancellations polluting `chatStopped`.** Handled by the explicit `reason` field — do not skip it.
- **Privacy drift.** `detail` must never accumulate text. Add a comment on `logSignal` saying so; the first person to put a transcript snippet in there will break the "safe to aggregate" property that makes this stream useful.

---

## Touch points summary

| File | Change |
|---|---|
| `ContextLogger.swift` | `SignalLogEntry` struct, `logSignal(...)`, `lastEntryTs` bookkeeping in `writeEntry`, `signals-` prefix in rotation + `interactionLogFiles`-style accessor |
| `AppConstants.swift` | `outcomeSignalRestartWindow` |
| `MenuBarController.swift` | `autoPasteIfEnabled()`, `toggleTranscription()` `.none` arm, `cancelInFlightTranscription()`, `cancelInFlightPrompt()` |
| `ChatView.swift` | `cancelSend()`, `CancellationError` arm, `retryMessage(id:)` |
| `SettingsViewModel.swift` / `ChatModelCommandResolver.swift` | `modelSwitched` (Slice 3) |
| `scripts/usage-metrics.py` | new (Slice 3) |
| `.cursor/skills/analyze-user-interactions/SKILL.md` | signal stream as primary source (Slice 4) |
| `ContextDerivation.swift` | signal-weighted candidate selection (Slice 4) |

# Implementer Queue

Input queue of the autonomous implementer (`scripts/implementer/run-implementer.sh`,
architecture: `plans/agent-loops.md`). Rows arrive two ways: **you** write one by hand, or
`scripts/implementer/groom-queue.py` files one from a loop's proposal. The hourly tick
(`scripts/implementer/tick.sh`) grooms the queue and then builds the **topmost** eligible row
(`Flag=BUILD`, `Status=OPEN`), one per run.

The runner never edits this file in the main checkout — it flips the row to
`Status=BRANCH <name>` (or `PR <url>`) **on its own branch**, so the bookkeeping travels with
the code and your merge closes the loop. The groomer is the one exception: it commits its rows
on `main`, because a proposal filed on a branch nobody merges is a proposal nobody sees.

**The four lanes — the difference is who may release a row**

| Flag | Meaning |
| ---- | ------- |
| `BUILD` | builds unattended on the next tick. Written by the groomer for gate-covered classes only (`instrumentation`), or by you for anything. |
| `VETO` | announced by mail with a **Deadline**, then promoted to `BUILD` on silence. Your only job is to stop it: `bash scripts/implementer/veto.sh <#>` moves it to `ASK`. Silence is a yes. |
| `ASK` | not released. The groomer files everything it cannot justify here; it never drops a proposal. **Which of them is actually yours to answer is the Status, not the Flag** — see below. |
| `HOLD` | parked by you. The groomer never touches a `HOLD` row. |

`veto.sh <#>` takes any released or parked row back to `ASK`/`OPEN`; `keep.sh <#> [BUILD|VETO]`
is its inverse and parks an `ASK` row in a lane until a build slot frees. One verb each way, so
the moment you reach for the stop button is not a moment you have to think about lanes.

**Why a VETO lane.** Two lanes made you the gate: every proposal the machinery could not prove
landed on your desk, and the rows below show what that produced — row 2 has sat `OPEN` since
2026-08-20. Sabaki hit the same wall on 2026-08-27 (20 undecided rows in one day) and answered
it the same way: do not ask for approval, make disagreement possible. Adding this lane loosened
a gate, so per `plans/agent-loops.md` it was a human decision, taken 2026-09-03.

**Status says who a row is waiting for.** It used to say only `OPEN`, and `OPEN` answered four
different questions with one word: the weekly would have called all of them "waiting on you"
while most were waiting on a build slot or a scope allowlist. Ported from Sabaki on 2026-09-05,
where that lane reached 34 rows of which three actually needed a human.

| Status | waiting for | who acts |
| ------ | ----------- | -------- |
| `OPEN` | your judgement — or, with `Flag=BUILD`, the next tick | you |
| `DEFERRED` | a free build slot. It cleared every gate and met a full queue; it keeps the lane it earned and the groomer releases it when capacity returns | nobody, it resolves itself |
| `BLOCKED` | reach the runner does not have (outside `IMPLEMENTER_SCOPE`). This is the evidence for widening the scope, not a decision to make row by row | you, once, for all of them |
| `DEFECT` | the loop that wrote it — the `class` or the falsifier could not be read. The fix is in that loop's skill file | the loop's author |

A `DEFECT` row is the one status a later proposal may supersede: blocking on it would mean a
loop that once wrote a bad falsifier can never file that finding again, however well it words
it the second time. Everything else still blocks the duplicate check.

Then the runner writes the row's later life: `BRANCH <name>` · `PR <url>` · `MERGED` ·
`DROPPED`. Those cells are written **on the branch**, so `main`'s copy of a row keeps saying
`BUILD`/`OPEN` until the branch lands — which is why the merge window lives in
`~/.local/state/whispershortcut-implementer/merge-windows/` and not in this table.

**The merge window.** A run that passes every gate and the reviewer opens one: the branch build
is left running so you live in the change, and `scripts/implementer/release-merges.sh` merges it
into `main` two days later unless `bash scripts/implementer/veto.sh <#>` stopped it. Stopping
closes the window and **keeps** the branch and worktree — a stopped merge is not a rejected
change — and sets the row to `ASK` so no tick rebuilds it. Merging is not releasing: the
release scripts, the App Store submission and the parent repo's submodule pointer are all still
yours, which is what makes an unattended merge a revert-sized risk rather than a shipped one.

**Eligibility rules**

- Rows must fit the scope allowlist (`IMPLEMENTER_SCOPE`, default `app`:
  `WhisperShortcut/`, `WhisperShortcutTests/`, `plans/implementer-`).
- **A proposal without a falsifier that is measurable on ship day is not eligible.** If the
  metric does not exist yet, the build must add the instrumentation in the same branch
  (`DebugLogger` / interaction-log / outcome-signal write) and name the exact query that will
  grade it. Otherwise it belongs in `plans/instrumentation-gaps.md` first.
- **Measurable here means measurable on ONE user's logs.** The app ships to strangers, but the
  only person this repo collects data about is the operator: every falsifier is graded from his
  own interaction logs and outcome signals. A falsifier that rests on what other users do —
  adoption of a feature, a rate across the install base, anything an App Store number would
  have to answer — cannot be graded and is not a question for anyone's desk; it is a `DEFECT`
  the writing loop has to re-word. This is a rule for the loops, not a check the groomer can
  run: no regex can tell whose behaviour a sentence is about. The consequence for a proposal
  worth building anyway is that its falsifier must be restated as something the operator's own
  usage produces, or it needs a new instrumentation gap first.
- **No model decides a lane.** `groom-queue.py` contains lookups and regexes, never a judgement
  call — a loop says what its proposal *is* (`class`), the groomer decides what that class is
  allowed to do. Widening `AUTO_CLASSES` or the veto windows is a human commit.
- **The in-flight cap (`IMPLEMENTER_MAX_INFLIGHT`, 3) delays; it does not demote.** A qualified
  proposal that meets a full queue is filed `DEFERRED` in the lane it earned, and the release
  sweep at the top of each groom run gives the oldest parked rows the free slots — before new
  proposals are judged, so a row that waited does not lose its place to one filed this morning.
  A released `VETO` row's window starts on release, never on filing: a window you could not
  have acted on is not a window. No gate moves either way — a parked row still passes class,
  scope, falsifier and review before it builds.

| #   | Source | Proposal (one line) | Falsifier | Flag | Status | Deadline |
| --- | ------ | ------------------- | --------- | ---- | ------ | -------- |
| 1 | improvement-ledger I2 (run 2, 2026-08-17) | Find and fix the transcription hang: the `transcribing` phase can sit for 3.5–12.8 min before the user cancels manually — add/repair the request timeout on the OpenAI GPT-Transcribe path so a stalled round-trip fails fast with a visible error instead of an unresponsive UI | No `cancelledWhileProcessing` signal with `mode=transcription`, `detail.phase="transcribing"` and `gapMs > 120000` in the next two usage-review windows (baseline: 3 such signals between 2026-08-10 and 2026-08-18, worst 12.8 min) | BUILD | MERGED |  |
| 2 | improvement-ledger I3 + instrumentation-gaps #8 (investigated 2026-08-20) | Close instrumentation gap #8: make `noSpeechDetected` visible to the outcome-signal stream. Add an `OutcomeSignal.noSpeechDetected` case (`ContextLogger.swift`) and emit it from BOTH paths — the local silence gate (`MenuBarController.swift:2432`, which skips the API call) and the API-empty path (`SpeechService.swift:2002`/`:2012`) — carrying `detail.source` (`localSilenceGate` or `apiEmptyResult`), `detail.peakDb`, `detail.durationMs` and `detail.logPrefix`. Follow the `requestTimedOut` precedent from PR #45. **Instrumentation only — do not change the gate threshold or any recording behaviour** | Over the next two usage-review windows, every `noSpeechDetected` occurrence counted in `errors-*.log` has a matching `noSpeechDetected` record in `interactions-*.jsonl` with all four fields non-null, and `detail.logPrefix` separates the `MEETING-SEGMENT` occurrences from the dictation ones. Falsified if the two counts still diverge, if any field is absent, or if the meeting/dictation split still cannot be read. Baseline: 39 error-log occurrences vs 0 interaction records (2026-07-22…2026-08-20); 30 dictation / 9 meeting | HOLD | OPEN |  |
| 3 | improvement-plan F15 (parked 2026-09-02) | Streaming local Dictate: admit Whisper in `DictateStreamingSession.makeIfEligible` so Offline Mode transcribes chunks while recording, with the existing merged-WAV fallback. **Do not add a Parakeet-class model in this row.** See `plans/active/streaming-dictate.md` slice 4. | A ≥20 s Offline Whisper dictation logs `SPEED: STREAMING-DICTATE: Transcript ready` and stop-to-clipboard is closer to last-chunk time than to full-file Whisper; a failed in-flight chunk still pastes via the merged-WAV fallback. Falsified if WhisperKit hangs/OOM during recording, or if chunk seams hallucinate after F14's peak gate. | BUILD | BRANCH claude/local-speech-to-text-optimize-0da93d |  |
| 4 | model-audit 2026-09-03 — Recommended migrations (seeded by hand: that run predates the proposal sidecar) | Add gemini-3.8-flash as a PromptModel and TranscriptionModel case and make it the default for Chat and Smart Improvement; point gemini35Flash.chatReplacement and gemini36Flash.chatReplacement at gemini37Flash, and move the migrateLegacyPromptRawValue pointers for gemini-2.5-flash and gemini-3-flash-preview from 3.5-flash to 3.7-flash so nobody is migrated onto a hidden model (SettingsConfiguration.swift, TranscriptionModels.swift, ChatModelCommandResolver.swift). Do NOT set gemini37Flash.chatReplacement = .gemini38Flash — the audit's own probe measured 3.8 slower, and that decision waits for an interleaved latency run. | On the branch build: a Chat message and a Smart Improvement run both resolve to gemini-3.8-flash and return HTTP 200 (`bash scripts/logs.sh -t 5m` shows the model ID with no fallback), the /3.8 chat command selects it, and a profile still on gemini-3.5-flash or gemini-3.6-flash comes up on gemini-3.7-flash after relaunch. Falsified if any of those still sends 3.7 where 3.8 is the default, errors, or leaves a user on a hidden model. Longer horizon: the 2026-10 audit must rank gemini-3.8-flash at or above gemini-3.7-flash on glossary adherence (baseline: the 2026-09-03 measurements) — falsified if it ranks below. | VETO | OPEN | 2026-09-06 |

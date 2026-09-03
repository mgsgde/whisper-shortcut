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
| `ASK` | needs your decision — irreversible, out of scope, or no falsifier a checker can parse. The groomer files everything it cannot justify here; it never drops a proposal. |
| `HOLD` | parked by you. The groomer never touches a `HOLD` row. |

**Why a VETO lane.** Two lanes made you the gate: every proposal the machinery could not prove
landed on your desk, and the rows below show what that produced — row 2 has sat `OPEN` since
2026-08-20. Sabaki hit the same wall on 2026-08-27 (20 undecided rows in one day) and answered
it the same way: do not ask for approval, make disagreement possible. Adding this lane loosened
a gate, so per `plans/agent-loops.md` it was a human decision, taken 2026-09-03.

Status: `OPEN` · `BRANCH <name>` · `PR <url>` · `MERGED` · `DROPPED`.

**Eligibility rules**

- Rows must fit the scope allowlist (`IMPLEMENTER_SCOPE`, default `app`:
  `WhisperShortcut/`, `WhisperShortcutTests/`, `plans/implementer-`).
- **A proposal without a falsifier that is measurable on ship day is not eligible.** If the
  metric does not exist yet, the build must add the instrumentation in the same branch
  (`DebugLogger` / interaction-log / outcome-signal write) and name the exact query that will
  grade it. Otherwise it belongs in `plans/instrumentation-gaps.md` first.
- **No model decides a lane.** `groom-queue.py` contains lookups and regexes, never a judgement
  call — a loop says what its proposal *is* (`class`), the groomer decides what that class is
  allowed to do. Widening `AUTO_CLASSES` or the veto windows is a human commit.

| #   | Source | Proposal (one line) | Falsifier | Flag | Status | Deadline |
| --- | ------ | ------------------- | --------- | ---- | ------ | -------- |
| 1 | improvement-ledger I2 (run 2, 2026-08-17) | Find and fix the transcription hang: the `transcribing` phase can sit for 3.5–12.8 min before the user cancels manually — add/repair the request timeout on the OpenAI GPT-Transcribe path so a stalled round-trip fails fast with a visible error instead of an unresponsive UI | No `cancelledWhileProcessing` signal with `mode=transcription`, `detail.phase="transcribing"` and `gapMs > 120000` in the next two usage-review windows (baseline: 3 such signals between 2026-08-10 and 2026-08-18, worst 12.8 min) | BUILD | MERGED |  |
| 2 | improvement-ledger I3 + instrumentation-gaps #8 (investigated 2026-08-20) | Close instrumentation gap #8: make `noSpeechDetected` visible to the outcome-signal stream. Add an `OutcomeSignal.noSpeechDetected` case (`ContextLogger.swift`) and emit it from BOTH paths — the local silence gate (`MenuBarController.swift:2432`, which skips the API call) and the API-empty path (`SpeechService.swift:2002`/`:2012`) — carrying `detail.source` (`localSilenceGate` or `apiEmptyResult`), `detail.peakDb`, `detail.durationMs` and `detail.logPrefix`. Follow the `requestTimedOut` precedent from PR #45. **Instrumentation only — do not change the gate threshold or any recording behaviour** | Over the next two usage-review windows, every `noSpeechDetected` occurrence counted in `errors-*.log` has a matching `noSpeechDetected` record in `interactions-*.jsonl` with all four fields non-null, and `detail.logPrefix` separates the `MEETING-SEGMENT` occurrences from the dictation ones. Falsified if the two counts still diverge, if any field is absent, or if the meeting/dictation split still cannot be read. Baseline: 39 error-log occurrences vs 0 interaction records (2026-07-22…2026-08-20); 30 dictation / 9 meeting | HOLD | OPEN |  |
| 3 | improvement-plan F15 (parked 2026-09-02) | Streaming local Dictate: admit Whisper in `DictateStreamingSession.makeIfEligible` so Offline Mode transcribes chunks while recording, with the existing merged-WAV fallback. **Do not add a Parakeet-class model in this row.** See `plans/active/streaming-dictate.md` slice 4. | A ≥20 s Offline Whisper dictation logs `SPEED: STREAMING-DICTATE: Transcript ready` and stop-to-clipboard is closer to last-chunk time than to full-file Whisper; a failed in-flight chunk still pastes via the merged-WAV fallback. Falsified if WhisperKit hangs/OOM during recording, or if chunk seams hallucinate after F14's peak gate. | BUILD | BRANCH claude/local-speech-to-text-optimize-0da93d |  |

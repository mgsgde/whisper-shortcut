# Improvement Ledger

Running record of product-improvement ideas mined from **actual usage**. Written by the weekly
usage-review routine and by any session that acts on one of its entries.

Long-lived by design: like `refactor-ledger.md`, this file is not deleted when a piece of work
finishes — entries change status instead. IDs are stable and never reused.

**Read this file before proposing anything.** Its main job is not to remember good ideas; it is to
remember the *rejected* ones. An autonomous weekly reviewer that cannot see what was already turned
down will propose the same three things forever, and the first thing to erode is your trust in it.

## Rules for entries

- **Evidence or it doesn't go in.** Every proposal names the signal or interaction pattern behind it,
  with counts. `dictationRestart ×7 in 5 days` is an entry; "the UI could be nicer" is not.
- **Max 3 new entries per run.** A list nobody reads is the same as no list.
- **Rejections keep their reason.** Status `rejected` without a `Why not` note is not a rejection,
  it is an invitation to re-propose.
- **Shipped entries get measured.** Once `plans/usage-metrics.csv` exists (outcome-signals Slice 3),
  a `shipped` entry moves to `measured` only when the metric it was supposed to move actually moved —
  or is honestly marked as having not moved.

Status values: `proposed` · `accepted` · `shipped` · `measured` · `rejected` · `superseded`.

## Ideas

| ID  | Idea | Evidence | Status | Run | Notes |
| --- | ---- | -------- | ------ | --- | ----- |
| I2 | `[code]` Investigate why transcription gets stuck in the `transcribing` phase for 3.5–4 minutes before the user gives up and manually cancels — check for a missing/too-long network timeout on the OpenAI GPT Transcribe request path | 2 `cancelledWhileProcessing` signals in a 4-day window (2026-08-10 and 2026-08-12), both `mode: transcription`, both `detail.phase: "transcribing"`, `gapMs` 211598 and 234394 (3.5min / 3.9min) between the interaction starting and the user cancelling. GPT Transcribe was the sole transcription model active all week (567/567 interactions), so this isn't a model-switch artifact. | proposed | 2 | Both cancels happened in otherwise-normal sessions (no error-log entry at either exact timestamp), consistent with a hung/very slow round-trip rather than a server error response. Rate is low (~0.35% of transcription attempts) but severity is high — several minutes of unresponsive UI before the user has to notice and intervene manually. |
| I3 | `[investigate]` `TranscriptionError.noSpeechDetected` ("error 21" in `errors-*.log`) fired 11 times across all 4 days of the window — every day had at least one. Understand whether these are expected (accidental/very brief mic triggers) or point to over-eager recording starts, and whether the user should get feedback beyond a silent failure | 11 occurrences in `errors-2026-08-10.log` (6), `errors-2026-08-11.log` (1, live-meeting segment), `errors-2026-08-12.log` (3), `errors-2026-08-13.log` (1) — confirmed via empirical Swift NSError-code bridging test that `TranscriptionError error 21` maps to `.noSpeechDetected`, not `.textTooShort` (`TextProcessingUtility.swift:403` is dead code today since `AppConstants.minimumTextLength == 1` makes it unreachable — the empty-string check fires first). Not visible in the outcome-signal stream at all: a `noSpeechDetected` failure produces no interaction record, so it cannot emit `pasted` or `dictationRestart` — a blind spot in the signal design worth noting. | proposed | 2 | Only 1 of the 690 interactions this week directly evidences a related restart (the "Ähm." filler-word case, single anecdote, not counted toward the bar). The 11 errors themselves clear the ≥2 bar on their own; root cause and user-facing severity still need a read of `SpeechErrorFormatter.swift`'s handling before proposing a fix — flagged as `[investigate]`, not yet a concrete fix. |
| I1 | `[code]` Move `ChunkedDictateRecorder`'s `AVAudioRecorder.record()`/`.stop()` off the main thread — `beginSession()` (start) and `rotateChunk()` (mid-recording rotation) call them synchronously, and both are the culprit in a captured hang | 2 watchdog hangs this week, both ≥4s, both with `ChunkedDictateRecorder` on top of the main-thread stack: `hang-20260728-165723.txt` (`rotateChunk` → `AVAudioRecorder.stop()` → `AQ::API::Queue::AwaitAllPendingCallbacks`) and `hang-20260802-170842.txt` (`beginSession`/`startChunkRecording` → `AVAudioRecorder.record()` → `AudioQueueXPC_Bridge::Start`). Same root cause both times. | shipped | 2026-08-03 | Not in the rejected table. Fits `analyze-chat-freeze`'s "main-thread hang" pattern but is a dictation-recording hang, not a chat one — new variant. Shipped 2026-08-03: `record()`/`stop()` now run on a serial `audioQueue`; state is committed on main first, `onChunkFinalized` waits for `stop()` so the WAV is closed before it is read. Same fix applied to `LiveMeetingRecorder` in the same pass — identical defect (main-thread `record()`/`stop()`, `didFinishChunk` firing before the WAV was closed) in a live path, found by structural sweep, **no captured hang of its own**; meetings rotate far more often than dictations so exposure is higher. `AudioRecorder` has the defect too but is the dead branch of `useChunkedDictateRecorder = true` — deliberately left alone. Verify by absence — no new `hang-*.txt` naming either recorder in the next review window. |

## Rejected — do not re-propose

| ID  | Idea | Why not | Run |
| --- | ---- | ------- | --- |
| _(empty)_ | | | |

## Run log

| Run | Date | Window reviewed | Signals seen | Entries added |
| --- | ---- | --------------- | ------------ | ------------- |
| 1 | 2026-08-03 | 2026-07-27 → 2026-08-02 (1109 interactions) | 28 (all `pasted`; signal stream only live ~1.5h on 08-02) | I1 |
| 2 | 2026-08-17 | 2026-08-10 → 2026-08-13 (690 interactions) | 588 (585 `pasted`, 2 `cancelledWhileProcessing`, 1 `dictationRestart`) | I2, I3 |
| 3 | 2026-08-18 | 2026-08-11 → 2026-08-18 (554 interactions; 08-11–08-13 overlap Run 2's window, only 08-18 is new data) | 455 (453 `pasted`, 2 `cancelledWhileProcessing`, 0 `dictationRestart`) | _(none — see digest: 1 new `cancelledWhileProcessing` on 08-18, gapMs 766397, reinforces I2 but doesn't independently clear the bar for a new entry)_ |

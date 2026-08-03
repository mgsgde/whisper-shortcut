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
| I1 | `[code]` Move `ChunkedDictateRecorder`'s `AVAudioRecorder.record()`/`.stop()` off the main thread — `beginSession()` (start) and `rotateChunk()` (mid-recording rotation) call them synchronously, and both are the culprit in a captured hang | 2 watchdog hangs this week, both ≥4s, both with `ChunkedDictateRecorder` on top of the main-thread stack: `hang-20260728-165723.txt` (`rotateChunk` → `AVAudioRecorder.stop()` → `AQ::API::Queue::AwaitAllPendingCallbacks`) and `hang-20260802-170842.txt` (`beginSession`/`startChunkRecording` → `AVAudioRecorder.record()` → `AudioQueueXPC_Bridge::Start`). Same root cause both times. | shipped | 2026-08-03 | Not in the rejected table. Fits `analyze-chat-freeze`'s "main-thread hang" pattern but is a dictation-recording hang, not a chat one — new variant. Shipped 2026-08-03: `record()`/`stop()` now run on a serial `audioQueue`; state is committed on main first, `onChunkFinalized` waits for `stop()` so the WAV is closed before it is read. Same fix applied to `LiveMeetingRecorder` in the same pass — identical defect (main-thread `record()`/`stop()`, `didFinishChunk` firing before the WAV was closed) in a live path, found by structural sweep, **no captured hang of its own**; meetings rotate far more often than dictations so exposure is higher. `AudioRecorder` has the defect too but is the dead branch of `useChunkedDictateRecorder = true` — deliberately left alone. Verify by absence — no new `hang-*.txt` naming either recorder in the next review window. |

## Rejected — do not re-propose

| ID  | Idea | Why not | Run |
| --- | ---- | ------- | --- |
| _(empty)_ | | | |

## Run log

| Run | Date | Window reviewed | Signals seen | Entries added |
| --- | ---- | --------------- | ------------ | ------------- |
| 1 | 2026-08-03 | 2026-07-27 → 2026-08-02 (1109 interactions) | 28 (all `pasted`; signal stream only live ~1.5h on 08-02) | I1 |

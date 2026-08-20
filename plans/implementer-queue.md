# Implementer Queue

Input queue of the autonomous implementer (`scripts/implementer/run-implementer.sh`,
architecture: `plans/agent-loops.md`). **You** add a row and set `Flag=BUILD` to release it;
the runner takes the **topmost** eligible row (`Flag=BUILD`, `Status=OPEN`), one per run.

The runner never edits this file in the main checkout — it flips the row to
`Status=BRANCH <name>` (or `PR <url>`) **on its own branch**, so the bookkeeping travels with
the code and your merge closes the loop.

**Eligibility rules**

- Rows must fit the scope allowlist (`IMPLEMENTER_SCOPE`, default `app`:
  `WhisperShortcut/`, `WhisperShortcutTests/`, `plans/implementer-`).
- **A proposal without a falsifier that is measurable on ship day is not eligible.** If the
  metric does not exist yet, the build must add the instrumentation in the same branch
  (`DebugLogger` / interaction-log / outcome-signal write) and name the exact query that will
  grade it. Otherwise it belongs in `plans/instrumentation-gaps.md` first.
- Flagging is a deliberate human act. No loop and no agent may set `BUILD` — they propose into
  the ledgers, you decide what gets built.

Flags: `HOLD` (parked, needs your decision) · `BUILD` (released to the runner).
Status: `OPEN` · `BRANCH <name>` · `PR <url>` · `MERGED` · `DROPPED`.

| #   | Source | Proposal (one line) | Falsifier | Flag | Status |
| --- | ------ | ------------------- | --------- | ---- | ------ |
| 1 | improvement-ledger I2 (run 2, 2026-08-17) | Find and fix the transcription hang: the `transcribing` phase can sit for 3.5–12.8 min before the user cancels manually — add/repair the request timeout on the OpenAI GPT-Transcribe path so a stalled round-trip fails fast with a visible error instead of an unresponsive UI | No `cancelledWhileProcessing` signal with `mode=transcription`, `detail.phase="transcribing"` and `gapMs > 120000` in the next two usage-review windows (baseline: 3 such signals between 2026-08-10 and 2026-08-18, worst 12.8 min) | BUILD | MERGED |
| 2 | improvement-ledger I3 + instrumentation-gaps #8 (investigated 2026-08-20) | Close instrumentation gap #8: make `noSpeechDetected` visible to the outcome-signal stream. Add an `OutcomeSignal.noSpeechDetected` case (`ContextLogger.swift`) and emit it from BOTH paths — the local silence gate (`MenuBarController.swift:2432`, which skips the API call) and the API-empty path (`SpeechService.swift:2002`/`:2012`) — carrying `detail.source` (`localSilenceGate` or `apiEmptyResult`), `detail.peakDb`, `detail.durationMs` and `detail.logPrefix`. Follow the `requestTimedOut` precedent from PR #45. **Instrumentation only — do not change the gate threshold or any recording behaviour** | Over the next two usage-review windows, every `noSpeechDetected` occurrence counted in `errors-*.log` has a matching `noSpeechDetected` record in `interactions-*.jsonl` with all four fields non-null, and `detail.logPrefix` separates the `MEETING-SEGMENT` occurrences from the dictation ones. Falsified if the two counts still diverge, if any field is absent, or if the meeting/dictation split still cannot be read. Baseline: 39 error-log occurrences vs 0 interaction records (2026-07-22…2026-08-20); 30 dictation / 9 meeting | HOLD | OPEN |

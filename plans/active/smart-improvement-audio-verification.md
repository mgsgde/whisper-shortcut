# Smart Improvement Audio Verification (Dictation)

## Goal

Make Smart Improvement use a small audio sample to verify text-based suggestions for the two dictation-related focuses — the Gemini dictation system prompt and the Whisper Glossary. Audio is treated strictly as a **verifier**, never as the primary evidence source. The capture applies to both dictation backends (Gemini cloud transcription and offline Whisper). The Dictate Prompt and Chat focuses are explicitly untouched. There is no new opt-in setting — audio capture is gated by the existing "Save usage data" master switch (`contextLoggingEnabled`) that already gates all interaction logging.

## Context

- Smart Improvement is implemented in `WhisperShortcut/ContextDerivation.swift`. The dictation system prompt focus and the Whisper Glossary focus are two of four focuses; both ultimately influence speech-to-text quality. Dictate Prompt and Chat focuses concern intent/style and are out of scope.
- Interaction logging happens in `WhisperShortcut/ContextLogger.swift`. `logTranscription(result:model:)` writes one JSONL line per transcription with `mode = "transcription"` and the model identifier; no audio is captured today. Logs rotate after 90 days.
- Transcription audio is produced by `AudioRecorder.swift` (24 kHz, mono, 16-bit WAV). The same WAV is consumed by both backends:
  - **Gemini cloud transcription**: WAV uploaded via `GeminiAPIClient.swift`.
  - **Offline Whisper**: WAV decoded locally by the Whisper runner.
  Today the WAV is discarded after transcription completes in both cases.
- The existing master toggle `UserDefaultsKeys.contextLoggingEnabled` ("Save usage data") gates all `ContextLogger` writes. Audio capture must respect the same toggle — when the user has disabled usage data logging, no audio is captured or stored.
- The Smart Improvement model is selected via `UserDefaultsKeys.selectedImprovementModel` and resolved in `ContextDerivation.analysisEndpoint`. The transcription model is selected separately and may be different.
- Same-family bias matters when the transcription was done by Gemini and Smart Improvement also runs on Gemini: a stronger Gemini re-listening to the same audio often reproduces the same misrecognition. Verification only adds information when the verifier is strictly stronger than the original Gemini transcription model, OR when the original transcription was done by Whisper (different family, so any Gemini verification adds signal).
- Audio is materially more sensitive than text, so retention must be tight: audio is held only between the moment of transcription and the next Smart Improvement run, then deleted.

## Non-Goals

- Do NOT add a new opt-in setting. Use the existing `contextLoggingEnabled` toggle as the gate.
- Do NOT capture audio for Dictate Prompt, Chat, or Live Meeting interactions. The verifier pattern only applies to single-shot dictation audio.
- Do NOT use audio as primary evidence. A glossary term or dictation rule must already be supported by the recurring-pattern threshold from text logs; audio only confirms or rejects.
- Do NOT add a non-Gemini cross-checker (e.g. local Whisper) for verification in this plan. Verification stays on the Smart Improvement Gemini model.
- Do NOT change the existing 3-distinct-interactions threshold from `smart-improvement-pattern-validation.md`. This plan layers on top of it.
- Do NOT change the interaction log schema in a backward-incompatible way. New fields must be optional.
- Do NOT auto-apply audio-verified suggestions. Output still flows through the existing diff review UI.

## Implementation Plan

1. **Capture audio after every successful dictation** in `SpeechService.swift`, gated by `ContextLogger.isLoggingEnabled` (the existing master toggle). Apply to both backends:
   - Gemini cloud transcription: capture happens after the cloud response is received and committed.
   - Offline Whisper: capture happens after the local decode succeeds.
   - Skip Dictate Prompt, Chat, and Live Meeting code paths.
   Copy the WAV produced by `AudioRecorder` into a new directory `UserContext/audio-samples/` with a stable id (ISO8601 timestamp + short random suffix).
2. **Bound the sample pool** before each write: if the directory already contains more than `audioSampleMaxFiles` (start with 20), delete the oldest by filename until under the cap. This avoids unbounded growth between Smart Improvement runs and survives crashes.
3. **Extend `InteractionLogEntry`** in `ContextLogger.swift` with two new optional fields:
   - `audioRef: String?` — filename inside `audio-samples/`, only set when a WAV was successfully copied.
   - `transcriptionModel: String?` — the actual transcription model identifier used for this entry (separate from the existing `model` field, which stays as-is for backward compatibility with rotated logs). For Whisper, use a stable value like `whisper-local`.
   Update `logTranscription(...)` to accept and persist these values. Both fields must remain optional so decoding older lines keeps working.
4. **Decide whether to attach audio for a given log entry** during Smart Improvement, per entry:
   - If `transcriptionModel` indicates Whisper (different family from Smart Improvement's Gemini): **always informative**, attach when selected.
   - If `transcriptionModel` is a Gemini model: only informative when the Smart Improvement model is strictly stronger (different model ID AND higher tier — Pro vs. Flash, Flash vs. Flash-Lite). When the SI model is equal or weaker than the transcription model, skip the audio for that entry (re-listening adds no information and only burns tokens).
   - Centralize the comparison in a small helper on `TranscriptionModels.swift`.
5. **Targeted sampling for the Whisper Glossary focus** in `ContextDerivation.swift`:
   - Build the text-only glossary candidate list using the existing recurring-pattern pipeline.
   - For each candidate term, select up to `audioSamplesPerCandidate` (start with 2) audio clips whose `result` contains a token close to the candidate (case-insensitive substring match — no fuzzy logic in this plan), filtered through the asymmetry rule from step 4.
   - Cap total audio attachments per focus per Smart Improvement run at `audioSamplesPerRun` (start with 6).
   - Random sampling is explicitly avoided.
6. **Targeted sampling for the dictation system prompt focus** in `ContextDerivation.swift`:
   - Identify candidate dictation rules generated by the existing text pipeline (e.g. a suggested rule about punctuation, filler-word handling, or a domain term).
   - For each candidate, select up to `audioSamplesPerCandidate` clips whose `result` exhibits the pattern the candidate rule talks about, filtered through the asymmetry rule from step 4.
   - Same `audioSamplesPerRun` cap (default 6) applies per run.
7. **Prompt updates** in `ContextDerivation.swift` for both focuses:
   - Add a clearly labeled `AUDIO EVIDENCE (VERIFIER ONLY)` section to the user message, listing each candidate and its attached audio clips.
   - Instruct Gemini: *"Audio is a verifier, not a primary source. Reject a candidate if the audio clearly does not contain the relevant signal. Confirm a candidate only when at least one clip clearly supports it. Do NOT introduce new candidates that came only from audio — they must already appear in the text-stage candidate list."*
   - When no audio is attached for a focus (no eligible clips after asymmetry filtering), fall back verbatim to today's text-only prompt for that focus.
8. **Aggressive TTL**: at the **start** of every Smart Improvement run, after the audio attachments have been read into the request, delete the entire `audio-samples/` directory contents (success or failure). On failure paths (network error, cancel, crash), the next run's startup cleanup will still wipe the directory before new attachments are collected. Audio is not retained across runs.
9. **Cleanup hooks and disclosure**:
   - Wire `ContextLogger.deleteAllContextData()` and `ContextLogger.deleteAllData()` to also remove `audio-samples/`.
   - Update the existing description for the "Save usage data" setting to mention that, when enabled, recent dictation audio is also retained briefly for Smart Improvement verification and deleted after each run.
10. **Logging and observability** (see dedicated section below for full spec): every phase of the audio-verification pipeline emits structured `AUDIO-VERIFY:` log lines via `DebugLogger` so the feature can be validated end-to-end from logs alone, without needing a debugger or breakpoints.
11. **Rebuild** with `bash scripts/rebuild-and-restart.sh` after each substantive change and verify the data flow end-to-end.

## Logging and Observability

All new log lines use `DebugLogger` and share the prefix `AUDIO-VERIFY:` so they can be filtered with `bash scripts/logs.sh -f 'AUDIO-VERIFY'`. Use `DebugLogger.logAudio` for capture-side lines and `DebugLogger.log` for derivation-side lines. The line format below is the **contract** — the validation skill (`validate-audio-verification`) depends on the exact tokens.

### Capture phase (`SpeechService.swift`)

After every dictation call site, emit exactly one line describing the outcome:

- Success: `AUDIO-VERIFY: capture(done) ref=<filename> backend=<gemini|whisper> transcriptionModel=<id> sizeBytes=<n>`
- Skip because master toggle is off: `AUDIO-VERIFY: capture(skip) reason=logging-disabled`
- Skip because mode is not dictation: `AUDIO-VERIFY: capture(skip) reason=non-dictation-mode mode=<promptMode|chat|liveMeeting>`
- Failure copying the WAV: `AUDIO-VERIFY: capture(error) reason=<short message>`
- Pool eviction: `AUDIO-VERIFY: pool-trim deleted=<n> remaining=<n> capacity=<audioSampleMaxFiles>`

The existing `USER-CONTEXT: Logged interaction (mode: transcription)` line stays unchanged — `AUDIO-VERIFY:` lines are additive, not replacements.

### Smart Improvement run phase (`ContextDerivation.swift`)

For each Smart Improvement invocation:

- Run start: `AUDIO-VERIFY: run(start) samplesOnDisk=<n>`
- Cleanup before request: `AUDIO-VERIFY: cleanup(start)` then `AUDIO-VERIFY: cleanup(done) deleted=<n>` — emitted at the **start** of the run, after attachments have been read into memory.
- For each affected focus (dictation system prompt, Whisper Glossary):
  - `AUDIO-VERIFY: focus=<dictation|glossary> text-candidates=<n>`
  - For each candidate: `AUDIO-VERIFY: focus=<…> candidate=<short term or rule id> matchingClipsOnDisk=<n>`
  - Asymmetry decision per clip: `AUDIO-VERIFY: asymmetry entryTs=<iso> transcriptionModel=<id> smartModel=<id> informative=<true|false> reason=<different-family|stronger-tier|same-or-weaker>`
  - Attach decision: `AUDIO-VERIFY: focus=<…> attach candidate=<…> selectedClips=<n>`
  - Skip decision: `AUDIO-VERIFY: focus=<…> skip-attach candidate=<…> reason=<no-eligible-clips|cap-reached>`
- Run end per focus: `AUDIO-VERIFY: focus=<…> run(end) attachedTotal=<n> capPerRun=<audioSamplesPerRun>`
- Overall run end: `AUDIO-VERIFY: run(end) totalAttached=<n>`

### What the logs must allow you to answer

Without opening any files in a debugger, the logs alone should answer:

1. Was audio captured for the last N dictations? (`AUDIO-VERIFY: capture(done|skip|error)` lines)
2. How many WAVs were on disk when Smart Improvement started? (`run(start) samplesOnDisk=<n>`)
3. For each text-stage candidate, how many matching clips existed and how many passed the asymmetry rule? (`matchingClipsOnDisk`, `asymmetry … informative`)
4. Which candidates got audio attached and which did not, and why? (`attach` / `skip-attach reason=…`)
5. Was the directory cleaned up after the run? (`cleanup(done) deleted=<n>`)

The validation skill (`.claude/skills/validate-audio-verification/SKILL.md`) operationalizes these checks.

## Acceptance Criteria

- No new setting is added. Audio capture is fully gated by the existing `contextLoggingEnabled` toggle.
- Disabling "Save usage data" stops new audio captures immediately; existing samples are removed at the next Smart Improvement run startup (or via the existing delete-all-data action).
- Audio is captured for both dictation backends (Gemini cloud, offline Whisper) and only for dictation — never for Dictate Prompt, Chat, or Live Meeting.
- `InteractionLogEntry` lines for dictation include `audioRef` and `transcriptionModel` when a clip was captured. Older lines without these fields still decode without errors.
- `audio-samples/` never exceeds `audioSampleMaxFiles` (default 20) WAV files at rest.
- Audio attachments only appear on the dictation system prompt focus and the Whisper Glossary focus, only for entries that pass the asymmetry rule, and never more than `audioSamplesPerRun` clips per focus per run (default 6).
- Each affected focus prompt is extended with audio-verifier wording only when audio is actually attached. The text-only prompt is unchanged otherwise.
- `audio-samples/` is emptied at the start of every Smart Improvement run, regardless of outcome.
- All new logging goes through `DebugLogger` and uses the `AUDIO-VERIFY:` prefix following the contract in the Logging and Observability section. No `print`, `NSLog`, or `os_log`.
- A user (or future Claude session) can answer all five validation questions listed in the Logging and Observability section using only `bash scripts/logs.sh -f 'AUDIO-VERIFY'`.
- `ContextLogger.deleteAllContextData()` and `deleteAllData()` remove `audio-samples/` along with the rest of the user context directory.

## Verification

- Rebuild with `bash scripts/rebuild-and-restart.sh`.
- With "Save usage data" off: run several dictations (both Gemini and Whisper backends), confirm `audio-samples/` is not created and interaction logs contain no `audioRef`. Trigger Smart Improvement and confirm payload shape is identical to current behavior.
- With "Save usage data" on, Gemini transcription model = `gemini-2.5-flash-lite`, Smart Improvement model = `gemini-3-pro-preview`: run several dictations including at least one with an intentionally misrecognized term ("Visper" instead of "Whisper"). Confirm WAV files appear under `audio-samples/`, interaction log lines include `audioRef` and `transcriptionModel`, and the directory respects `audioSampleMaxFiles`.
- Trigger Smart Improvement: confirm via `bash scripts/logs.sh -t 5m -f 'USER-CONTEXT'` that audio attachments are tied to text-stage candidates for both the dictation and Whisper Glossary focuses, capped per run, and that the directory is cleared at run start.
- With "Save usage data" on, transcription model = Smart Improvement model = `gemini-3-pro-preview`: confirm no audio is attached to either focus (asymmetry rule), even though clips exist on disk.
- With Whisper as the dictation backend and any Gemini Smart Improvement model: confirm audio IS attached (different-family asymmetry), and the Whisper Glossary focus prompt shows the verifier section.
- Confirm the Smart Improvement review UI still works and that suggestions remain text-based (audio is internal to the derivation step, not surfaced in the diff).
- Click "Reset to Defaults" / equivalent delete-all flow and confirm `audio-samples/` is removed along with other context data.
- User runs any Xcode tests manually if needed.

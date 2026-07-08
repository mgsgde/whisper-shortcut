# Streaming Dictate — Overlap Transcription with Recording

**Status:** Planned, not started (2026-07-08)
**Audience:** LLM implementing the feature end-to-end
**Goal:** Make Dictate feel near-instant regardless of dictation length by transcribing speech *while the user is still talking*, so pressing Stop only leaves the final tail chunk to process — the pattern that makes Wispr Flow feel fast (their budget: full result ≤700 ms after end of speech).

---

## Context: what already shipped (2026-07-08)

Two smaller latency slices landed before this plan and are prerequisites/context:

1. **Connection pre-warm** — `ConnectionPrewarmer.swift` fires a HEAD request to the provider host when recording starts (all 4 `audioRecorder.startRecording()` call sites in `MenuBarController`), so TLS setup hides inside the recording window. Log marker: `PREWARM:`.
2. **AAC upload transcoding** — `AudioTranscoder.aacData(for:)` re-encodes the recorded PCM WAV to 32 kbps AAC (m4a, MIME `audio/aac`, verified accepted by the live Gemini API) before inline upload. ~10× smaller payload. Wired into: `SpeechService.transcribeWithGeminiInline`, the Gemini Dictate Prompt inline branch, `transcribeAudioForHistory`, and `ChunkTranscriptionService.transcribeChunk`. Recording stays WAV (local Whisper, `AudioChunker`, Smart Improvement audio verification all expect PCM). Log marker: `SPEED: AAC transcode`.

Remaining latency after those slices is dominated by **Gemini processing time, which grows with audio duration** — a 60 s dictation still takes several seconds after Stop. This plan removes that proportionality.

## Core idea

While recording, cut the audio at silence boundaries into chunks and transcribe each chunk immediately in the background. On Stop, only the last partial chunk goes to the API; merge all chunk transcripts and deliver. Perceived latency becomes ~constant (last chunk + merge) instead of O(total duration).

All the building blocks exist:

| Piece | Existing component | Reuse notes |
|---|---|---|
| Silence-boundary chunk capture during recording | `LiveMeetingRecorder.swift` | Double-buffer AVAudioEngine recorder with silence-based chunk finalization. Today it's meeting-only; extract/generalize the chunking capture so Dictate can use it without meeting semantics. |
| Parallel per-chunk transcription with retry/rate-limit | `ChunkTranscriptionService.swift` | Already transcribes chunks concurrently against Gemini with `RateLimitCoordinator` backoff and per-chunk AAC transcoding. Needs a mode where chunks *arrive over time* (AsyncStream) instead of from a pre-split file — `AudioChunkStream` is already an `AsyncThrowingStream`, so the shape fits. |
| Transcript joining | `TranscriptMerger.swift` | Handles overlap-aware merging for the >45 s batch path today. |
| State machine | `AppState.swift` | `.recording(.transcription)` → `.processing(.transcribing)` unchanged; processing phase just gets much shorter. |

## Design decisions (made; revisit only with evidence)

- **Activation threshold:** only stream for recordings that pass ~10–15 s. Short dictations stay on the current single-shot path (simpler, one API call, no merge risk). Implementation: start recording normally; when the running duration crosses the threshold, finalize the first chunk and enter streaming mode retroactively is NOT possible with AVAudioRecorder — so instead: Dictate always records via the chunk-capable recorder, and the *decision* is made at Stop: if total duration < threshold and no chunk was finalized yet, send single-shot as today.
- **Chunk boundaries:** silence-based (reuse LiveMeetingRecorder's detector) with a max-length fallback (~30 s) so continuous speech still chunks.
- **Prompt/glossary:** each chunk gets the same transcription instruction (dictation prompt + glossary) that `SpeechService.geminiTranscriptionInstruction` builds — identical to how the >45 s batch chunking path works today, so quality risk is the same, already-accepted risk.
- **Recorder unification risk:** Dictate currently uses `AVAudioRecorder` (`AudioRecorder.swift`); LiveMeetingRecorder uses `AVAudioEngine`. Moving Dictate onto the engine-based recorder touches mic permission flow, metering/silence detection (`hasRecentlyBeenSilent`), and the `audioRecorderDidFinishRecording` delegate contract in `MenuBarController`. This is the riskiest part — do it as its own commit with the single-shot path proven unchanged before adding streaming.
- **Smart Improvement audio capture:** `ContextLogger` keeps getting the full concatenated WAV (merge chunk WAVs with `AudioMerger` or keep a parallel full-file writer) — audio verification needs the complete take.
- **Failure semantics:** if any in-flight chunk ultimately fails after retries, fall back to single-shot transcription of the full merged WAV (we still have all audio on disk) rather than delivering a transcript with holes.

## Implementation slices (each independently shippable)

1. **Recorder swap behind a flag** — Dictate records through the engine-based chunk recorder but always delivers one WAV at Stop (no behavior change). Verify metering, silence-skip of tail delay, meeting-segment interplay, permission prompts.
2. **In-flight chunk transcription** — chunks stream into `ChunkTranscriptionService` during recording; at Stop, tail chunk + `TranscriptMerger` + deliver. Threshold gate + single-shot fallback.
3. **Tune & instrument** — `SPEED:` logs for per-chunk latency and stop-to-clipboard time; compare against pre-change baseline (`SPEED: [model] API call completed`); tune threshold/max-chunk length from real usage via `analyze-user-interactions`.

## Non-goals

- No partial-text UI during recording (result still lands in the clipboard as one piece; menu-bar icon behavior unchanged).
- No provider work beyond Gemini (OpenAI/xAI keep the single-shot path; local Whisper untouched).
- No change to Dictate Prompt mode (audio→prompt is a single multimodal call; chunked transcription doesn't apply).

## Verification

- Manual: 5 s, 20 s, 60 s, 3 min dictations; compare `SPEED:` stop-to-result times before/after; check merge seams for dropped/duplicated words at chunk boundaries (dictate a numbered list spanning a boundary).
- Regression: meeting recording, Dictate-during-meeting segment, cancel-mid-processing, silent-recording detection, Smart Improvement audio verification (`/validate-audio-verification`).

# Streaming Dictate — Overlap Transcription with Recording

**Status:** Slice 1 implemented (2026-07-08) — `ChunkedDictateRecorder` behind `AppConstants.useChunkedDictateRecorder`, externally identical behavior (chunks merged to one WAV on stop). Slice 2 shipped (`DictateStreamingSession.swift`, wired in `MenuBarController`). Slice 3 pending.

**Correction to the original plan:** `LiveMeetingRecorder` is NOT AVAudioEngine-based — it is a double-buffer of two `AVAudioRecorder`s rotated at silence boundaries. Slice 1 therefore copied that proven pattern instead of introducing an engine-based recorder, which removes the recorder-swap risk (mic permission flow, metering, delegate contract all stay on `AVAudioRecorder` semantics) and the meeting-interplay concern (the app already runs multiple concurrent `AVAudioRecorder`s during meeting + dictation segments). Dictate rotation is silence-only (no max-duration cut): continuous speech grows the current chunk, so seams only ever sit inside real pauses.
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
| Silence-boundary chunk capture during recording | `ChunkedDictateRecorder.swift` (new, slice 1) | Double-buffer `AVAudioRecorder`s with silence-only rotation, modeled on `LiveMeetingRecorder`. Exposes `onChunkFinalized(url, index)` for slice 2; merges chunks to one WAV on stop in slice 1. |
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

1. **Recorder swap behind a flag** — ✅ DONE (2026-07-08). Dictate records through `ChunkedDictateRecorder` (flag: `AppConstants.useChunkedDictateRecorder`) but always delivers one WAV at Stop (chunks merged via AVAudioFile concat; single-chunk sessions delivered untouched). Rotation: silence ≥ `dictateChunkSilenceDuration` (1.0s) after `dictateChunkMinDuration` (10s). Log markers: `AUDIO: Rotated dictate chunk`, `AUDIO: Merged N dictate chunks`.
2. **In-flight chunk transcription** — ✅ DONE (2026-07-08). `DictateStreamingSession` (new file) transcribes rotated-out chunks immediately via the regular `SpeechService.transcribe` pipeline (cancellable:false → no cancellation-slot interference; AAC transcode + retries for free). Created per recording in `MenuBarController` when the Dictate model is cloud Gemini with credential (`makeIfEligible`); prompt recordings and other providers stay single-shot. Tail chunk arrives via `ChunkedDictateRecorder.onFinalChunk` before the merge; transcripts are joined in index order with " " (chunks are gap-free, no overlap → no `TranscriptMerger` needed). Silent chunks skip the API call. Fallbacks: any chunk error / missing chunk / all-silent → `finalTranscript()` returns nil → single-shot transcription of the merged WAV; session cancellation (indicator ✕, cancel shortcut, silent gate, long-recording safeguard, recorder failure) throws `CancellationError` so no fallback call runs. ContextLogger/Smart-Improvement still get the full merged WAV. Log markers: `STREAMING-DICTATE:`, `SPEED: STREAMING-DICTATE: Transcript ready Nms after stop`.
3. **Tune & instrument** — `SPEED:` logs for per-chunk latency and stop-to-clipboard time; compare against pre-change baseline (`SPEED: [model] API call completed`); tune threshold/max-chunk length from real usage via `analyze-user-interactions`.
4. **Offline Whisper in-flight (F15 next slice) — parked 2026-09-02, not started.** Cloud streaming is live; Offline Mode still waits for the finished file (`LocalSpeechService.transcribe` is one-shot). The next build is *not* a new ASR stack: admit Whisper in `DictateStreamingSession.makeIfEligible` (same chunk recorder, same fallback to the merged WAV if a chunk fails). Measure `SPEED: STREAMING-DICTATE:` stop-to-clipboard on a ≥20 s Offline dictation against the one-shot baseline. Watch for: WhisperKit concurrency while recording (today untested), seam hallucinations after F14's peak gate (chunk starts), RAM vs F13 idle-unload. **Do not pull a Parakeet-class model into this slice** — that stays a later, separate L (new download, quality vs Whisper, no `promptTokens` glossary). Queue: `plans/implementer-queue.md` row 3 (`HOLD`). Plan row: `plans/improvement-plan-2026-09.md` F15.

## Measuring the offline path before building slice 4 (added 2026-09-02)

Slice 4 is only worth building if Whisper's decode is fast relative to the speech it decodes, and
the numbers depend entirely on the Mac — the target here is a *Praxis* machine, not the developer's,
and nobody dictates offline day to day, so there is no passive telemetry to wait for. Two changes
landed to make a deliberate three-minute test produce the answer:

1. **Realtime factor per transcription** — `LocalSpeechService.transcribe` emits
   `SPEED: LOCAL-SPEECH rtf model=… audioS=… decodeS=… totalS=… rtf=…`. `decodeS` spans the
   prompt-retry decode too, so the factor is not flattered.
2. **Cold vs. warm weights** — `LocalSpeechService.initializeModel` emits
   `SPEED: LOCAL-SPEECH load model=… loadMs=…`; `SpeechService` emits
   `SPEED: LOCAL-SPEECH coldStart …` / `warmStart …` depending on whether the load landed *after*
   Stop, on the critical path. `ConnectionPrewarmer` emits `SPEED: PREWARM offline model=… readyMs=…`.

**Test recipe:** select an offline model, then dictate once for ~5 s, ~20 s and ~60 s, and read:

```bash
bash scripts/logs.sh -t 15m | grep -E "SPEED: (LOCAL-SPEECH|PREWARM offline)"
```

**How to read it:** `rtf` well below ~0.3 means in-flight chunks decode far faster than they arrive
and slice 4 pays off; `rtf` approaching 1 means chunks would queue behind the speech and streaming
would make things *worse*, not better — that is the falsifier for slice 4 on that hardware. A
`coldStart` line after the prewarm shipped means the warm-up did not reach in time (or the model was
absent); every `warmStart waitMs=0` is load latency that no longer sits after Stop.

**First baseline (M1 Pro / 16 GB, Turbo, 2026-09-02, `OfflineWhisperBenchmarkTests`, synthesized
German dictation):**

| audio | chars out | decode | rtf |
|---|---|---|---|
| 24.5 s | 362 | 4.25 s | 0.173 |
| 68.2 s | 1011 | 12.66 s | 0.186 |
| 1.0 s of noise | 0 | 0.086 s | — |
| 24.5 s, first decode after a load | 362 | 7.29 s | 0.297 |

Cold weight load: 3.7–6.1 s across runs. Warm run-to-run spread on the same clip: 3.8–4.7 s — read
single numbers with that in mind.

Three things fall out, and two of them contradict what this plan assumed before the measurement:

1. **Decode cost tracks the tokens produced, not the audio duration and not 30 s windows.** 11.7 and
   12.5 ms per output character for the two clips above; one second of noise, which yields no
   tokens, decodes in 86 ms. The earlier worry that sub-30 s chunks would each pay a full encoder
   pass is **wrong** — the encoder is cheap here, the autoregressive decoder is the cost, and
   chunking does not multiply it. Chunk length is therefore a free parameter for slice 4, to be
   chosen for seam quality rather than for compute.
2. **Streaming can keep up comfortably.** At rtf ≈ 0.18 on dense synthetic speech — real dictation
   has pauses and sits lower — a chunk decodes roughly five times faster than it was spoken, so
   in-flight chunks cannot pile up behind the speaker on this class of hardware. `whisper-large` on
   a weaker Mac is where that assumption needs re-checking; the benchmark takes
   `WHISPERSHORTCUT_BENCH_OFFLINE_MODEL` for exactly that.
3. **The first decode that produces text after every model load costs ~4 s extra**, and the penalty
   returns after each unload rather than being paid once per process. It *is* absorbable — three
   arms from a freshly reloaded model, same probe clip:

   | warm-up first | its own cost | probe decode |
   |---|---|---|
   | none | — | 8.13 s |
   | a real 16 kHz recording (80 chars out) | 6.42 s | 4.21 s |
   | an `AVSpeechSynthesizer` clip (69 chars out) | 6.20 s | 4.05 s |

   An earlier round concluded the opposite and was wrong: those warm-ups (silence 6 ms, a noise
   buffer 10 ms, a noise file 86 ms, synthesized speech 0.85–1.58 s) produced no text, and a decode
   that emits no tokens does no work and warms nothing. The transcript was discarded without being
   checked — the experiment tested a broken clip, not the hypothesis. **Any warm-up must assert
   that it decoded something.**

   Exploiting it is a trade, because the warm-up costs the ~6 s it absorbs: run inside the
   recording window it is free only for recordings longer than roughly 12 s (weights load first,
   then the warm-up), and for shorter ones it delays the real transcript by a couple of seconds,
   since `LocalSpeechService` is an actor and the real call queues behind it. The alternative is to
   stop creating the cold state at all — keep the *selected* offline model loaded instead of idle-
   unloading it after five minutes (F13), which removes the load *and* the penalty for every
   dictation at the cost of ~1.6 GB resident. Whether that is acceptable depends on the machine.

Cold path for a 25 s dictation, end to end: ~5 s load + ~7.3 s first decode ≈ **12 s**, against
~4.3 s warm. The preload below removes the first half of that reliably; the second half is item 3.

## Preload instead of streaming (shipped 2026-09-02)

`ConnectionPrewarmer.prewarm(for: TranscriptionModel)` now warms offline Whisper's weights at
recording start, the way it already warmed cloud connections and local LLMs. Whisper was previously
warmed only at launch and on model selection, which stopped being sufficient when F13 added the
five-minute idle unload and the memory-pressure unload: the first dictation after a pause paid the
~1.6 GB load *after* Stop. This is the cheap half of slice 4's benefit with none of its seam risk,
and it should be measured (recipe above) before slice 4 is built at all. It never downloads a
missing model and never touches the network — Offline Mode's guarantee is unchanged.

## Non-goals

- No partial-text UI during recording (result still lands in the clipboard as one piece; menu-bar icon behavior unchanged).
- ~~No provider work beyond Gemini~~ Extended 2026-07-08: streaming covers all cloud STT providers (Gemini, OpenAI, xAI) — usage data showed dictation alternates between OpenAI and Gemini week to week, and the session already routed chunks through the provider-agnostic `SpeechService.transcribe`, so the gate widening was ~3 lines. Self-hosted endpoints stay excluded. Offline Whisper is **no longer a non-goal** — it is slice 4 above, parked.
- No change to Dictate Prompt mode (audio→prompt is a single multimodal call; chunked transcription doesn't apply).
- No Parakeet / FastConformer / other local ASR in this plan. That is F15's second half and a new model ecosystem, not a streaming-Dictate slice.

## Verification

- Manual: 5 s, 20 s, 60 s, 3 min dictations; compare `SPEED:` stop-to-result times before/after; check merge seams for dropped/duplicated words at chunk boundaries (dictate a numbered list spanning a boundary).
- Regression: meeting recording, Dictate-during-meeting segment, cancel-mid-processing, silent-recording detection, Smart Improvement audio verification (`/validate-audio-verification`).

# Streaming Dictate — Overlap Transcription with Recording

**Status:** Slices 1, 2 and 4 shipped; slice 3 (tuning) pending. Slice 1 implemented (2026-07-08) — `ChunkedDictateRecorder` behind `AppConstants.useChunkedDictateRecorder`, externally identical behavior (chunks merged to one WAV on stop). Slice 2 shipped (`DictateStreamingSession.swift`, wired in `MenuBarController`). Slice 4 shipped 2026-09-02 (offline Whisper admitted). 2026-09-03 stage timings: Whisper's ~3 s floor is the 30 s-padded encoder, not the tail length — see "Where the fixed cost per call goes".

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
4. **Offline Whisper in-flight** — ✅ BUILT 2026-09-02 (see "Slice 4 as built" below).
   Original text, kept because its stated risks are what the build had to answer:
   **parked 2026-09-02, not started.** Cloud streaming is live; Offline Mode still waits for the finished file (`LocalSpeechService.transcribe` is one-shot). The next build is *not* a new ASR stack: admit Whisper in `DictateStreamingSession.makeIfEligible` (same chunk recorder, same fallback to the merged WAV if a chunk fails). Measure `SPEED: STREAMING-DICTATE:` stop-to-clipboard on a ≥20 s Offline dictation against the one-shot baseline. Watch for: WhisperKit concurrency while recording (today untested), seam hallucinations after F14's peak gate (chunk starts), RAM vs F13 idle-unload. **Do not pull a Parakeet-class model into this slice** — that stays a later, separate L (new download, quality vs Whisper, no `promptTokens` glossary). Queue: `plans/implementer-queue.md` row 3 (`HOLD`). Plan row: `plans/improvement-plan-2026-09.md` F15.

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

   > **Overturned 2026-09-03.** Stage timings on real recordings show the encoder is half to two
   > thirds of every call, paid per 30 s-padded window. The 1 s noise clip produced no tokens *and*
   > was measured before encoder time was visible. See "Where the fixed cost per call goes" below.
   > Shrinking the tail chunk cannot lower Whisper's floor.
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

## VAD chunking measured, shipped, and taken back out (2026-09-02)

Before slice 4, the cheaper question: WhisperKit can already parallelise a *finished* file.
`DecodingOptions.chunkingStrategy = .vad` cuts audio longer than one 30 s window at voice-activity
boundaries and hands the pieces to `concurrentWorkerCount` workers (16 on macOS); the app passed
nil, so windows were walked in sequence. Measured with
`OfflineWhisperBenchmarkTests.chunkingStrategyComparison` (M1 Pro / 16 GB, Turbo, warm model, two
runs per arm, `say`-synthesised German):

| audio | sequential | `.vad` | chars (seq vs vad) |
|---|---|---|---|
| 68.2 s | 10.03 s / 10.20 s | 8.92 s / 9.25 s | 1011 vs 1011 |
| 127.1 s | 18.83 s / 18.36 s | 17.25 s | 1881 vs 1880 |

> **Reverted the same day — the measurement below was on the wrong material.** See "What real
> speech showed" at the end of this section. The numbers here stand; the conclusion drawn from
> them did not.

**~7–10 % faster, transcript unchanged** — no seam damage on this material, and no coverage risk:
`VADAudioChunker.chunkAll` splits in the middle of the longest silence and still covers the whole
array, so nothing is dropped. It is inert below 30 s (a single window is not chunkable), which is
most dictations. Shipped as the default in `LocalSpeechService.transcribe`.

The number is small for a reason worth writing down, because it also bounds slice 4's alternative:
**CoreML serialises on the GPU, so 16 "concurrent workers" do not buy 16×** — what overlaps is
CPU-side work around the decode, not the decode itself. Parallelism inside one finished file is
therefore not the lever. Moving the work *before* Stop is, which is exactly slice 4: the decode
still costs rtf ≈ 0.15, it just no longer happens while the user waits.

Two incidental findings from the run:

- The benchmark's documented invocation never ran anything. `WHISPERSHORTCUT_BENCH_OFFLINE_WHISPER`
  does not reach the sandboxed macOS test host from the command line (the `TEST_RUNNER_` prefix is a
  simulator mechanism), and a Swift Testing `-only-testing` selector needs its trailing `()`. Both
  failure modes report **"0 tests in 1 suite passed"** — green, and meaningless. The corrected recipe
  is in the suite's doc comment; the flag has to come from the test plan.
- The model was unloaded out from under the last arm ("WhisperKit not initialized") inside a 108 s
  test process — far short of the five-minute idle timer, so the memory-pressure source fired. Worth
  knowing before slice 4 keeps the model resident *and* decodes during recording on a 16 GB Mac.

### What real speech showed, and the bug underneath it

The user ran the A/B, and the transcript came back with `Cursor "Gigawats"), BNI, "Gigawatt")`
repeated. Decoding their retained 64 s recording four ways, twice each, separated two problems —
neither of them a streaming seam:

| prompt | sequential | `.vad` |
|---|---|---|
| none | 958 chars, correct | 945 chars, "is twice" dropped at a seam |
| glossary, verbatim | **51** chars one run, 560 another | 1190 chars: `"Guardian"),` ×20 |
| glossary, sanitised | **975 / 975, correct** | 688 / 676 — ~30 % missing |

1. **The Whisper Glossary was destroying offline dictation, and had been all along.** It is passed
   to `promptTokens`, which is not an instruction channel but *example text the decoder continues*.
   `Claude (not "Cloud")` therefore reads as a writing sample full of parentheses and quotes, and
   Whisper reproduces that shape and loops. One run returned 51 characters for 64 seconds of
   speech. This predates streaming, predates VAD chunking, and hit every offline dictation with a
   non-empty glossary. Fixed in `LocalSpeechService.sanitizeGlossaryForWhisper` — drop a leading
   `Terms:`, drop parenthesised asides, drop quotes, keep every term untouched. Verified through
   the production path: 975 chars, twice, deterministic. Covered by
   `WhisperGlossarySanitizerTests`.

2. **`.vad` is not safe with a prompt, and loses words without one.** Chunks decode independently,
   so each re-applies `promptTokens` with no carried context. Reverted to sequential. The synthetic
   benchmark missed this because `say` produces clean pauses and the arms were run without a
   glossary — a reminder that a benchmark is only as good as the material it runs on.

**A third correction, to the numbers this plan is built on:** real `rtf` on this recording is
**0.34–0.54**, not the 0.15 measured on synthetic German. A chunk decodes roughly twice as fast as
it was spoken, not six times. Streaming still keeps up comfortably, and the A/B confirms the win
(4.0 s and 5.5 s after Stop with pauses, against 32.2 s single-shot on 64 s of audio) — but the
margin on slower hardware or with `whisper-large` is much thinner than this plan assumed.

## Slice 4 as built (2026-09-02)

`DictateStreamingSession.makeIfEligible` now admits offline Whisper, so Offline Mode transcribes
chunks while the user is still speaking. Everything downstream was already in place — the chunked
recorder runs for every dictation, chunks route through `SpeechService.transcribe`, and the
merged-WAV fallback is unchanged — so the feature is a gate change plus the three things the gate
change makes newly reachable.

**The gate.** Split into a pure `isEligible(model:hasCredential:offlineModelDownloaded:)`, the way
`OfflineMode.shouldBlock(_:offlineMode:)` is split, because its real inputs are the Keychain and a
model folder on disk. Offline streams **only when the weights are already downloaded** — an
in-flight chunk must never be what starts a multi-gigabyte download mid-recording. Undownloaded
models keep the single-shot path, where `SpeechService` still offers the download with progress.
Covered by `DictateStreamingEligibilityTests` (4 tests, every model case).

**The concurrency risk the row raised does not exist.** `LocalSpeechService` is an actor, so chunk
decodes serialise behind one another rather than running WhisperKit re-entrantly. At the measured
rtf ≈ 0.15 a chunk decodes ~6× faster than it was spoken, so a queue cannot build up behind the
speaker.

> **Overturned 2026-09-03.** The actor suspends at `await whisperKit.transcribe`, so a rotated
> chunk and the tail *do* overlap on the GPU and slow each other down. Serialising the decodes is
> now a listed lever, not a property we already have.

**Two things the gate change made reachable, both fixed here:**

- A background chunk could throw the modal "Offline Dictation — loading model…" popup over the
  screen *mid-sentence*, because `performTranscription` showed it unconditionally when the weights
  were cold. It is now gated on `reportsProgress`, which streaming chunks already pass as false:
  the popup belongs to the foreground transcription the user is waiting on, not to background work
  during a recording.
- Cancelling a dictation left the GPU finishing a decode whose transcript is already discarded.
  `performWhisperTranscription` passed `{ _ in true }` as WhisperKit's decode callback — harmless
  when the only decode ran after Stop, wrong now that decodes run during recording. It returns
  `!Task.isCancelled`, which stops the decode at the next token.

**Not changed, deliberately:** `ContextLogger` / Smart Improvement still receive the full merged
WAV; the fallback semantics (chunk failure or missing chunk → single-shot; cancellation → no
result at all) are untouched; `dictateChunkMinDuration` stays at 10 s.

**Measured end to end (2026-09-02), and it found a bug.** `OfflineWhisperBenchmarkTests`
`streamingVersusOneShot` drives the real `DictateStreamingSession` / `SpeechService` /
`LocalSpeechService` with pre-cut chunks handed over **in real time** — each only after its own
audio duration has elapsed, which is when the recorder would have rotated it out. It stands in for
the microphone and for `ChunkedDictateRecorder`'s silence detection, nothing else.

73 s of German dictation, five chunks, 14 s tail, M1 Pro / Turbo:

| run | after Stop, streamed | after Stop, one-shot | ratio |
|---|---|---|---|
| 1 | *fell back* | 24.7 s | — |
| 2 | 5.89 s | 18.75 s | 3.2× |
| 3 | 13.08 s | 20.57 s | 1.6× |
| 4 | 5.02 s | 16.89 s | 3.4× |

Streaming wins every time it runs, but the spread is wide — the decode competes with whatever else
the Mac is doing — so read the range, not a single number.

**Run 1 is the interesting one.** A chunk failed with `fileError("WhisperKit not initialized")`,
which made the session discard every chunk's work and fall back to the merged WAV: correct output,
streaming benefit silently gone. The cause is a check-then-use race — `SpeechService` asks
`isLoaded` and then calls `transcribe`, two hops into the actor, and the memory-pressure source can
unload in between. Before slice 4 that was nearly unreachable (one decode per dictation, started
right after the check); slice 4 makes it one call per chunk across the whole recording. Fixed by
reloading inside the actor (`lastLoadedModelType`), where check and decode cannot be separated.

Two instrumentation defects fell out of the same run and are fixed: the fallback logged
`error.localizedDescription`, which renders every `TranscriptionError` payload as "The operation
couldn't be completed" — the one log line nobody could act on — and the benchmark's `print`
diagnostics were lost to stdout buffering whenever the test failed.

**Ship-day falsifier** (queue row 3) — dictate ≥20 s offline with at least one pause, then:

```bash
bash scripts/logs.sh -t 15m | grep -E "SPEED: (STREAMING-DICTATE|LOCAL-SPEECH)"
```

Expected: `STREAMING-DICTATE: Transcribing chunk N in flight` lines *during* the recording, and
`SPEED: STREAMING-DICTATE: Transcript ready Nms after stop` where N is close to the tail chunk's
decode (~1.5–2.5 s for a 10–15 s tail at rtf 0.15) rather than the ~0.15 × total the single-shot
path costs. Falsified if chunk seams hallucinate after F14's peak gate, or if the fallback rate
rises.

**Two known residuals, neither a blocker:**

- **The tail is the floor.** Rotation needs 1.0 s of silence *and* a ≥10 s chunk, so the last chunk
  is typically 10–15 s and costs ~1.5–2.5 s after Stop. Shrinking `dictateChunkMinDuration` would
  shrink it, and the earlier finding that decode cost tracks output tokens rather than windows says
  that is compute-free — but it is a seam-quality trade, so it belongs in slice 3 tuning against
  real usage, not in this slice.
- **Memory pressure can still unload mid-session.** The benchmark run saw the memory-pressure source
  drop Turbo inside a 108 s process, far short of the five-minute idle timer. A mid-recording unload
  now costs a ~5 s reload on the next chunk instead of failing, so it degrades rather than breaks —
  but on a 16 GB Mac also running MLX it is worth watching.

## The chunk ceiling: proposed, measured, rejected (2026-09-02)

Slice 1 rotates on silence only, with no maximum chunk length — a deliberate departure from this
plan's original design, which called for "a max-length fallback (~30 s) so continuous speech still
chunks". A real dictation made the cost visible: after one early pause the user spoke for 64.8 s
straight, so everything after it sat in the tail chunk, and the tail is the one piece you wait
through after Stop. 16.2 s of it, against ~21 s for not streaming at all — a 22 % win where a
five-chunk dictation had given 4.0 s.

So the ceiling was built (`dictateChunkMaxDuration`, rotate at 30 s regardless of silence) and
measured before being kept. The same 82.8 s recording, cut outside the app at exact boundaries so
the cuts land mid-sentence, each piece decoded through the production path with the glossary and
joined the way `DictateStreamingSession` joins:

| | chars | tail decode | transcript |
|---|---|---|---|
| whole file | 771 | 21 s | correct and complete |
| forced 30 s cuts | 1032 | 13.5 s | duplication at the seam ("is, in fact, **In fact,**"), dropped words ("and you _know_ that", "in **work** to have"), a leading `...`, and the tail looped: *"I think that's a really important thing."* six times |
| forced 45 s cuts | 355 | 8.1 s | **over half the content gone** — jumps from "the things that we do," straight to "Intelligence. Through universities…" |

**Rejected and reverted.** A cut inside continuous speech costs Whisper the context it needs on
both sides of the seam, and the damage is not a missing word here and there — it is duplication,
loss of more than half the transcript, and repetition loops. Slice 1's silence-only rule was right,
and the original plan's max-length fallback was wrong. Do not re-propose this without new evidence.

The consequence stands and should be stated plainly rather than engineered around: **streaming's
benefit is a function of how the speaker pauses.** Five chunks gave 4.0 s after Stop; two chunks
gave 16.2 s. Both are better than not streaming, neither is a constant, and the floor is whatever
the speaker leaves in the tail.

## Where the fixed cost per call goes (measured 2026-09-03)

The app's logs from a morning of real offline dictation showed every WhisperKit call costing
**3.0–3.4 s whether the chunk held 1.8 s or 16 s of speech** (`SPEED: LOCAL-SPEECH rtf` lines:
1.83 s → 3.17 s, 2.58 s → 3.05 s, 4.14 s → 3.25 s, 15.5 s → 3.42 s). A floor like that is what the
user waits through after Stop once streaming has taken everything else, and the "decode cost
tracks output tokens" model above cannot produce it. `LocalSpeechService` now logs WhisperKit's
own stage timings (`SPEED: LOCAL-SPEECH timings …`) on branch
`claude/whisper-transcription-speed-f4fcfe` (commit `54399e7`), and
`OfflineWhisperBenchmarkTests.realRecordingBreakdown` decodes the user's retained recordings at
five lengths, with and without the Whisper Glossary (137 chars, 52 tokens), twice each. M1 Pro /
16 GB, Turbo on `.cpuAndGPU`, warm model, the Mac also building in another worktree — so read the
structure, not the third digit:

| audio | windows | glossary | decode | of which encoder | decoder loops | fallbacks |
|---|---|---|---|---|---|---|
| 2.0 s | 1 | yes | 7.4–8.0 s | 5.3–5.8 s | 65 | 0 |
| 2.0 s | 1 | no | 6.1–7.1 s | 5.0–5.2 s | 12 | 0 |
| 5.0 s | 1 | yes | 5.2–5.5 s | 3.1 s | 81 | 0 |
| 5.0 s | 1 | no | 3.4–4.3 s | 2.4–2.8 s | 30 | 0 |
| 15.0 s | 1 | yes | 5.0–5.9 s | 2.2–2.6 s | 114 | 0 |
| 15.0 s | 1 | no | 4.1–6.6 s | 1.8–4.9 s | 62 | 0 |
| 30.4 s | 2 | yes | 15.0–18.4 s | 6.9 s | 338–468 | **2** |
| 30.4 s | 2 | no | 12.1–13.1 s | 7.8–8.9 s | 83 | 0 |
| 60.8 s | 3 | yes | 20.0–22.0 s | 11.7–12.6 s | 315 | 0 |
| 60.8 s | 3 | no | 10.9–16.6 s | 6.0–11.5 s | 169 | 0 |

Wispr Flow is **not** fast because it has a local model. It is cloud-only: audio goes to their
servers, a small ASR model plus a Llama cleanup pass (hosted at Baseten), quoted **≤700 ms p99
after end of speech**. There is no on-device stack to copy. Our local path is slow because Whisper
pays a fixed ~3 s socket per call, and that socket is in the model architecture, not in our code.

Three conclusions, two of which overturn what this plan said before:

1. **The encoder is not cheap — it is half to two thirds of every call.** Whisper pads every
   window to 30 s and runs the full large-v3 encoder over it, so a 2 s tail chunk pays the same
   2–5 s encoder pass as a 15 s one. Consequence: **shrinking `dictateChunkMinDuration` cannot
   lower the floor** for Whisper; the floor is one encoder pass plus the prefill, ~3 s on this Mac
   with the GPU otherwise idle, and it is paid per window, not per second of speech.
2. **The glossary doubles the decoder loops.** WhisperKit feeds `promptTokens` through the
   decoder one token at a time before the first real token (52 prompt tokens → 65 loops for a
   12-token transcript), at 7–25 tokens/s on the GPU that is +1.5–3 s per window, and on the 30 s
   recording it also triggered two temperature fallbacks (+3–5 s) that the no-glossary arm did
   not need. Same characters out either way. The glossary is worth its accuracy, but it is a
   speed cost on every chunk, and a shorter glossary is a direct win.
3. **Decoder throughput is 7–25 tokens/s** on `.cpuAndGPU`, and it drops when two decodes run at
   once — which they do: `LocalSpeechService` is an actor, but `transcribe` suspends at
   `await whisperKit.transcribe`, so a rotated chunk and the tail decode *overlap* on the GPU
   (logged 2026-09-03 13:26: a 16 s chunk took 4.3 s instead of 3.3 s while the tail ran
   beside it). The plan's "the actor serialises chunk decodes" claim is wrong.

What this means for the goal ("as fast as Wispr Flow"): on-device, the floor is the model
architecture. Whisper's 30 s-padded encoder plus autoregressive decoder cannot get under ~2–3 s
per call on an M1 Pro GPU. A FastConformer/TDT model (Parakeet TDT 0.6B v3 via FluidAudio,
CoreML, ANE, 25 European languages incl. German, FLEURS de WER 5.9 %) encodes a 15 s window in
~20 ms and decodes 1 min of audio in ~0.5 s on an M4 Pro (~110× realtime; an M1 Pro is slower but
in the same order) — a 2 s tail would cost ~100 ms, not 3 s. That is the lever that reaches
Wispr-class latency offline, and it is F15's second half in `plans/improvement-plan-2026-09.md`.
Open point: no `promptTokens` glossary. FluidAudio has CTC vocabulary boosting (works with v3,
+97 MB); whether that holds German osteopathy terms needs a test.

Cheaper steps that keep Whisper, in order of expected payoff, none measured yet:

- **Encoder on the ANE with the `_632MB` turbo variant.** The GPU encoder is the biggest single
  item. `OfflineModelType.usesNeuralEngine` keeps large models off the ANE because the first-load
  compile ran >14 min across nine attempts on 2026-08-31 — attempts that were each killed by the
  next rebuild-and-restart, so it is not known whether the compile finishes if left alone. The
  ANE specialisation is cached per model after the first success. Test it once in the test host
  (not the app), with `openai_whisper-large-v3-v20240930_turbo_632MB`, which is the variant Argmax
  quantised for the ANE, and read `encodeS` from the timings line. Falsifier: encoder still >1 s
  warm.
- **Serialise chunk decodes** so the tail never shares the GPU with a still-running chunk (a
  queue inside `LocalSpeechService`, or `DictateStreamingSession` awaiting the previous chunk
  before starting the next).
- **Shorter glossary.** Keep the terms that actually get misheard; do not drop the glossary on
  in-flight chunks (those chunks would then mishear the same terms the user added it for).

Instrumentation to re-run the measurement lives on `claude/whisper-transcription-speed-f4fcfe`
(`54399e7`): `SPEED: LOCAL-SPEECH timings …` in `LocalSpeechService`, opt-in test
`realRecordingBreakdown` in `OfflineWhisperBenchmarkTests` (numbers only, no transcripts).

Sources: [Parakeety: Wispr Flow does not run locally](https://www.parakeety.com/resources/does-wispr-flow-run-locally),
[Willow Voice Review](https://willowvoice.com/blog/wispr-flow-review-voice-dictation),
[Spokenly Review](https://spokenly.app/blog/wispr-flow-review),
[FluidAudio Benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md),
[Parakeet TDT v3 CoreML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml),
[FluidAudio](https://github.com/FluidInference/FluidAudio),
[WhisperKit Paper](https://arxiv.org/html/2507.10860v1),
[WhisperKit CoreML models](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main).

## Non-goals

- No partial-text UI during recording (result still lands in the clipboard as one piece; menu-bar icon behavior unchanged).
- ~~No provider work beyond Gemini~~ Extended 2026-07-08: streaming covers all cloud STT providers (Gemini, OpenAI, xAI) — usage data showed dictation alternates between OpenAI and Gemini week to week, and the session already routed chunks through the provider-agnostic `SpeechService.transcribe`, so the gate widening was ~3 lines. Self-hosted endpoints stay excluded. Offline Whisper is **no longer a non-goal** — it is slice 4 above, built 2026-09-02.
- No change to Dictate Prompt mode (audio→prompt is a single multimodal call; chunked transcription doesn't apply).
- No Parakeet / FastConformer / other local ASR in this plan. That is F15's second half and a new model ecosystem, not a streaming-Dictate slice.

## Verification

- Manual: 5 s, 20 s, 60 s, 3 min dictations; compare `SPEED:` stop-to-result times before/after; check merge seams for dropped/duplicated words at chunk boundaries (dictate a numbered list spanning a boundary).
- Regression: meeting recording, Dictate-during-meeting segment, cancel-mid-processing, silent-recording detection, Smart Improvement audio verification (`/validate-audio-verification`).

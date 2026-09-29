# Local ASR benchmark

Offline speech-to-text bake-off for `plans/improvement-plan-2026-09.md` F15: which on-device
engine should replace (or sit beside) WhisperKit for Offline Mode. It measures the two things a
dictating user feels — **accuracy on German** and **the wait after Stop** — for:

| engine | what it is |
|---|---|
| `whisper-turbo`, `whisper-turbo+glossary` | today's Offline Mode: WhisperKit 1.1.0, large-v3 turbo, configured as `LocalSpeechService` (GPU, `de`, 2 fallbacks, glossary as `promptTokens`) |
| `parakeet-v3`, `parakeet-ultra`, `parakeet-redux` | NVIDIA Parakeet TDT 0.6B v3 and Moondream's two retrains, via FluidAudio 0.17.4 (CoreML, ANE) |
| `parakeet-ultra+vocab` (`parakeet-v3+vocab`) | the same plus FluidAudio's CTC vocabulary boosting with the glossary terms — Parakeet's only stand-in for Whisper's glossary |
| `apple`, `apple+ctx` | macOS 26 `SpeechAnalyzer` / `SpeechTranscriber` (system model, nothing to ship), with and without `contextualStrings` |
| `whisper-small`, `whisper-base` | opt-in via `--engines` |

It is a standalone Swift package rather than a test in the Xcode project so candidates can be
measured before any of them becomes an app dependency, and because the unsandboxed CLI can run
`say` and read the app container.

## Run

```bash
cd benchmarks/local-asr
swift build -c release
.build/release/LocalASRBench                         # everything, 60 real clips
.build/release/LocalASRBench --skip-real --engines parakeet-ultra,apple
```

Flags: `--engines a,b,…`, `--real-limit N`, `--max-seconds S` (default 120; real clips above it are dropped after picking), `--skip-real`, `--skip-synthetic`, `--out DIR`.

First run downloads the Parakeet models from HuggingFace (~500 MB v3, ~630 MB ultra, ~220 MB
redux, ~100 MB CTC) into FluidAudio's cache and the German `SpeechTranscriber` asset through
`AssetInventory`; `load s` for that engine then includes the download and is not a load time.
Whisper uses the model the app already downloaded — the run fails that engine if it is missing.

## Data

- **synthetic** — ten clips of German practice dictation spoken by `say -v Anna` (16 kHz), ~3 s
  to ~70 s, reference = the source text. Clean TTS, so absolute WER is optimistic; the ranking
  and the latency are what it is for. Term recall is scored on 15 medical/osteopathy terms,
  which are also the vocabulary the `+glossary`/`+vocab`/`+ctx` arms receive.
- **real** — `--real-limit` recordings from `UserContext/audio-samples`, spread evenly across the
  duration range, each paired with the transcript the cloud model (GPT-4o Transcribe / GPT
  Transcribe) produced for it at the time. That reference is not ground truth, so "WER real" reads
  as *distance from the cloud transcript the user accepted*. Numbers written as digits by one side
  and as words by the other count as errors against every engine alike. Term recall uses the
  user's Whisper Glossary, counted only where the reference contains the term.

## Output

- stdout: one `BENCH-SUMMARY` row per engine as it finishes, and the full table at the end.
- `--out` (default `~/Library/Caches/whispershortcut-bench/local-asr/<timestamp>/`):
  `summary.md` and `rows.jsonl` with every clip's hypothesis and reference. **The real set is
  private dictation — never commit `rows.jsonl`.** Only aggregate numbers go into plans.

Columns: `load s` (process-once cost), `1st decode s` (first call after load, kept out of the
per-clip numbers), `WER synth` / `WER real` (corpus-level: total edits ÷ total reference words,
lower-cased, punctuation stripped), `terms` (hit/present), `p50 <5s` … (median decode seconds per
audio-length bucket — `<5s` is the post-Stop tail in streaming Dictate), `p90 all`, `errors`.

Engines run one after another, never side by side, so none competes with another for the GPU/ANE.

## Results

### 2026-09-29 — M1 Pro / 16 GB, macOS 26.6.2

65 clips every engine decoded: 10 synthetic, 55 real (1–73 s; one 11-minute meeting recording was
dropped after Whisper+glossary sat on it until the process was killed — hence `--max-seconds`).
Decode seconds are medians per audio-length bucket, warm, first decode after load excluded.

| engine | WER synth | WER real | terms synth | terms real | <5 s | 5–15 s | 15–30 s | >30 s | worst |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| whisper-turbo (today) | 4.7 % | 8.4 % | 19/24 | 8/11 | 1.89 | 2.16 | 3.90 | 10.11 | 15.61 |
| whisper-turbo+glossary (today, glossary on) | 9.8 % | 19.3 % | 24/24 | 9/11 | 3.40 | 3.82 | 4.95 | 13.65 | 19.72 |
| parakeet-v3 | 5.1 % | 10.8 % | 20/24 | 10/11 | 0.11 | 0.16 | 0.32 | 0.51 | 0.79 |
| **parakeet-ultra** | 5.8 % | **8.1 %** | 18/24 | 10/11 | **0.10** | **0.14** | 0.30 | **0.46** | 0.81 |
| parakeet-redux | 8.1 % | 10.4 % | 12/24 | 10/11 | 0.19 | 0.23 | 0.46 | 0.86 | 1.53 |
| **parakeet-ultra+vocab** | **3.7 %** | 8.3 % | **23/24** | 10/11 | 0.27 | 0.36 | 0.73 | 1.54 | 2.42 |
| apple-speechanalyzer | 7.8 % | 12.2 % | 14/24 | 9/11 | 0.10 | 0.14 | 0.27 | 0.53 | 0.64 |
| apple-speechanalyzer+ctx | 7.8 % | 12.2 % | 14/24 | 9/11 | 0.10 | 0.13 | 0.28 | 0.52 | 0.66 |

Load with warm caches: Whisper turbo 4.6 s (33 s cold) and ~7–10 s on the first decode;
Parakeet ultra 0.4 s, ultra+vocab 0.7 s, first decode 0.2–0.5 s; Apple 0.2 s. Redux's ANE compile
fails on the M1 Pro (`ANECCompile() FAILED`) and it reloads in 32 s every time — first run 726 s.

What the numbers say:

- **Parakeet Ultra matches Whisper turbo on the user's real German (8.1 % vs 8.4 %) at 1/19 of
  the wait on short clips and 1/22 on long ones.** Whisper's ~2 s floor on a <5 s tail becomes
  0.1 s. It is also the best real-set WER of all eight arms.
- **CTC vocabulary boosting works on German medical terms** even though its CTC encoder is the
  English 110M model: synthetic terms 18/24 → 23/24 and synthetic WER 5.8 → 3.7 %, real WER
  unchanged (8.1 → 8.3 %, within noise), for ~0.2 s extra on a short clip. That is the stand-in
  for Whisper's glossary the plan was missing.
- **Whisper's glossary as used today breaks long dictations.** Under 30 s it is WER-neutral
  (7.0 → 7.1 %) and lifts terms; over 30 s WER goes 9.4 → 34.8 %: on multi-window audio the
  conditioned decode dropped or garbled whole 30 s windows (one 73 s clip kept only its tail).
- **Apple SpeechAnalyzer** is as fast as Parakeet with no download, but less accurate on both
  sets and misses half the practice terms; `contextualStrings` changes nothing for
  `SpeechTranscriber` (identical output).
- **Redux** trades too much accuracy for its 220 MB and does not compile for the ANE on M1.

Caveats: one Mac; synthetic audio is clean TTS; the real reference is GPT-4o Transcribe, not
ground truth; the synthetic term arms get the exact term list, which flatters every biased arm
equally.

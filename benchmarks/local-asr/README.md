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

Flags: `--engines a,b,…`, `--real-limit N`, `--skip-real`, `--skip-synthetic`, `--out DIR`.

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

VERDICT: Nemotron Unified is not worth it, neither offline nor streaming. Measured 2026-11-08: offline it loses to Ultra again (pilot 10.4 % vs 7.1 %); streaming at 560 ms gives text 0.4 s behind speech, but with more errors (pilot 10.0 % vs 7.1 %), 0.58× real time of compute on an M1 Pro, and an extra download. The live preview stays on SlidingWindow over Ultra as planned.

# Nemotron Unified ASR 0.6B as offline (and streaming) dictation, 2026-11-08

Candidate: `FluidInference/nemotron-labs-unified-asr-0.6b-coreml`, a Core ML conversion of
`nvidia/nemotron-labs-unified-asr-0.6b`. Why it matters: Parakeet Ultra does not stream
(`plans/active/parakeet-offline.md` D2), and live dictation (`plans/active/live-dictate-preview.md`)
is what holds the practice pilots back on offline. This model claims one checkpoint for both
offline and streaming, in 25 European languages.

**Correction (same day):** the first version of this file said nothing was measured. That was
wrong. The offline arms `nemotron-unified` and `nemotron-unified+vocab` were already run on
2026-11-04 (M1 Pro, FluidAudio 0.18.2, int8), see `benchmarks/local-asr/README.md`:

| engine | WER real | WER pilot | pilot without spoken-mark words | p50 <5 s |
|---|---:|---:|---:|---:|
| parakeet-ultra | **5.5 %** | 17.1 % | **6.3 %** | **0.09** |
| nemotron-unified | 6.5 % | 18.3 % | 9.8 % | 0.16 |
| nemotron-unified+vocab | 11.8 % | 20.2 % | 12.2 % | 0.19 |

So offline replacement of Ultra is off the table, and Glossary boosting on this family inserts
terms that were never said. What remains is streaming: buffered streaming can only be as good as
the offline decode or worse, so the question is narrower — is Nemotron's live text good and fast
enough for the opt-in live preview (`live-dictate-preview.md`), compared with the planned
`SlidingWindowAsrManager` over Ultra, which needs no extra download? The model facts below come
from the cards and FluidAudio's source.

## What the model is

Sources: <https://huggingface.co/nvidia/nemotron-labs-unified-asr-0.6b>,
<https://huggingface.co/FluidInference/nemotron-labs-unified-asr-0.6b-coreml>.

- **Architecture:** Unified FastConformer (24 layers) + **RNNT**, not TDT. 600M parameters. The
  encoder was initialised from parakeet-tdt-0.6b-v3, the same base as Ultra.
- **Languages:** 25, including German. The language goes to the encoder as `prompt_id` (`de` = 9,
  `auto` = 127). The card recommends naming the language for low-latency streaming: under ~560 ms,
  `auto` can get the first chunks' language wrong.
- **Output:** "includes punctuation and capitalization".
- **Streaming is buffered, not cache-aware.** Each step re-encodes `[left | chunk | right]`, and
  only the RNNT decoder state carries over. The Core ML port ships three streaming bundles:
  - `70_13_13`: 2.08 s latency
  - `70_7_7`: 1.12 s
  - `70_2_5`: 0.56 s

  The offline encoder takes a 15 s window.
- **Encoder cost (M5 Pro, ANE):** 11–12 ms per 0.56 s streaming step, 26 ms per 15 s offline window.
- **Sizes:** encoder fp16 ~1.1 GB, int8 ~570 MB, per variant. Offline and each streaming context
  are separate encoders, so offline + one streaming bundle ≈ 2.2 GB fp16 / 1.1 GB int8, plus a
  small decoder and joint.
  - For comparison, Ultra is ~630 MB.
  - The card: int8 matched fp16 WER in 5 of 6 languages (French got worse), "fp16 is the safer
    default". It gives no German figure for the Core ML build.
- **NVIDIA's German WER** (FLEURS/MCV/MLS average, explicit language prompt):

  | Offline | 1.12 s | 0.56 s | 0.32 s | 0.16 s |
  |---|---|---|---|---|
  | 4.32 | 5.45 | 6.30 | 7.47 | 10.01 |

  These are read-speech academic sets. They say nothing about medical dictation, our glossary, or
  the "Nur gesprochen" punctuation mode. NVIDIA claims it beats parakeet-tdt-0.6b-v3 offline (4.61
  vs 4.68 on its multilingual subset). It makes no claim against Ultra.
- **Minimum OS:** macOS 14 / iOS 17. We already require more.

## Does our FluidAudio support it? Yes, in the version we pin

`WhisperShortcut.xcodeproj` pins FluidAudio **exactVersion 0.18.2** (`e396cf78`). Support arrived
in v0.18.0 (2026-10-28, PR #1071). I checked the source at the pinned commit with `git grep`:

- `Sources/FluidAudio/ASR/Parakeet/Unified/UnifiedConfig.swift:65`:
  `case nemotronMultilingual(NemotronUnifiedLanguage)` in `UnifiedModelFamily` (repo
  `.nemotronUnified`, blank 4095, `promptId` from the language).
- Offline: `public actor UnifiedAsrManager` (`UnifiedAsrManager.swift:49`).
- Streaming: `public actor StreamingUnifiedAsrManager` (`StreamingUnifiedAsrManager.swift:16`).
  It has `appendAudio(_ AVAudioPCMBuffer)` and a partial-transcript callback /
  `getPartialTranscript()`, with `finish()` for the tail.
- Configuration: `UnifiedConfig(family: .nemotronMultilingual(.de))` plus a precision (fp16/int8)
  and a context.
- Not to be confused with `StreamingNemotronMultilingualAsrManager`, which is the cache-aware
  Nemotron 3.5 streaming model (8 languages), a different checkpoint.

No version bump is needed. v0.18.3 (2026-11-07) only adds an opt-in raw-encoder callback.

## Does the Glossary boosting work with it? Mechanically yes, with two caveats

Both Unified managers expose
`configureVocabularyBoosting(vocabulary:ctcModels:config:thresholds:)`:
`UnifiedAsrManager.swift:213`, `StreamingUnifiedAsrManager.swift:233`.

It is the same CTC-rescoring pipeline `ParakeetBackend` uses today: `VocabularyBooster` with
`CtcModels` `.ctc110m`, which we already download. So the Glossary plumbing can be reused. Two
caveats:

- **Streaming:** rescoring runs on word-aligned segments, and corrections surface
  **retroactively** through the partial transcript. FluidAudio's CustomVocabulary doc says
  cross-chunk detection is "not supported", and multi-word terms only partly. In a live preview
  that inserts text, a retroactive correction means rewriting text already shown. That is a
  design question for `live-dictate-insert.md`, not only a model question.
- **Unproven on this family:** the docs show English-only boosting benchmarks, and the default
  config is `VocabularyBoostingSession.itnDefaultConfig` (rescue floors 0.30 / 0.50), tuned on the
  English Unified model. Our German medical glossary terms (GdB, VersMedV, …) must be measured
  (see the benchmark).

## Licence: OpenMDW-1.1 is compatible with App Store distribution

Full text: the `LICENSE.md` in the HF repo (Copyright 2026 NVIDIA).

- Grant: "deal in the Model Materials without restriction", commercial use included.
- No copyleft, no revenue or user caps, no field-of-use or acceptable-use clause. Outputs are
  unrestricted.
- **Condition:** anyone distributing any portion must "retain … a copy of this agreement, and all
  copyright notices and other notices of origin". We download the weights at runtime rather than
  bundling them, the same as Parakeet. Still, for parity with the CC BY credit we must add an
  OpenMDW line and a licence link to `AboutSettingsTab.acknowledgementsSection`.
- The patent/copyright retaliation clause terminates the grant only if *we* sue claiming the model
  infringes. That does not affect normal use.
- The App Store guidelines have nothing against it. It is less restrictive than CC BY 4.0, which we
  already ship under.

## Benchmark plan (runs on the Mac, Apple Silicon)

Goal: answer three questions with numbers.

1. **Offline:** does Nemotron Unified beat or match Parakeet Ultra on German dictation? (It would
   then replace Ultra and give us one model for both modes.)
2. **Streaming:** at which latency bundle is German streaming good enough for live dictation?
3. **Glossary:** does the CTC boosting still lift our terms on this family?

### Harness

Extend `benchmarks/local-asr` (standalone Swift package, today on FluidAudio 0.17.4).

- Bump its `Package.swift` to `exact: "0.18.2"`, the same as the app.
- Add these engines:
  - `nemotron-unified` (offline, `UnifiedAsrManager`, `.nemotronMultilingual(.de)`, fp16)
  - `nemotron-unified-int8`
  - `nemotron-unified+vocab` (glossary through `configureVocabularyBoosting` with `.ctc110m`)
  - `nemotron-stream-{2080,1120,560}` (`StreamingUnifiedAsrManager`, audio fed in 80 ms
    buffers at real-time pace, recording the time each word first appears in the partial
    transcript, and the final transcript after `finish()`)
- Keep `parakeet-ultra` and `parakeet-ultra+vocab` as the reference arms. They are today's
  shipping configuration.

Then run the app-level check, `bash scripts/dictation-benchmark.sh --model <new case>`. It scores
the app's post-processing too (spoken punctuation, "Nur gesprochen", glossary casing). This needs
a throwaway `TranscriptionModel` case on a branch, never on main before the decision.

### Data

- The 60 real clips plus the synthetic `say -v Anna` set already in `benchmarks/local-asr`.
- The pilot corpus (`--pilot-corpus`, `business/pilot-praxis/benchmark-audio/magnus`): German
  medical dictation with glossary terms (GdB, VersMedV, Befund, beidseits …).
- `benchmarks/dictation/corpus.json` cases for "Nur gesprochen" (spoken Komma / Punkt / Semikolon
  / Absatz / Schrägstrich).

### Metrics and pass bars

| Metric | Measured how | Pass bar to switch offline from Ultra |
|---|---|---|
| WER, real + pilot clips | normalized, same scorer as today | ≤ Ultra's, or ≤ Ultra + 0.5 pt if streaming passes too |
| Glossary hit rate (pilot terms) | exact-term recall, `+vocab` arms | ≥ `parakeet-ultra+vocab` |
| Wait after Stop, offline | wall clock, 3 s / 20 s / 70 s clips | ≤ Ultra + 20 % |
| "Nur gesprochen" exact | `dictation-benchmark.sh` spokenOnly | no case below baseline |
| Silence / hallucination | silence clips, `ParakeetVocabularyGuard` path | 0 invented text |
| Streaming: first-word latency | time from speech to first partial word | ≤ 1.2 s at the chosen bundle |
| Streaming: final vs offline WER | final transcript vs offline arm | ≤ +1.5 pt at the chosen bundle |
| Streaming: partial rewrites | chars of shown partial text later changed | report it; it decides the insert design |
| Memory / disk | peak RSS, downloaded size | report it; fp16 2.2 GB vs int8 1.1 GB for offline + one stream |

### Decision rules

- **Offline and streaming both pass:** propose replacing Ultra with Nemotron Unified, Parakeet D2
  revisited with streaming on. This needs the owner's go, because it changes the download size and
  the default.
- **Only streaming passes:** offer it as the live-dictation engine beside Ultra (two downloads),
  but only if the pilots ask for live offline.
- **Glossary hit rate drops by more than 5 pt:** no switch. Glossary is the pilots' first
  complaint (queue rows 72, 73, 76).
- **Neither passes:** record it under "measured or ruled out" in `parakeet-offline.md` and stop.

Queue row: `plans/implementer-queue.md` #77. It is `ASK`, because it needs the Mac, model downloads
and minutes of ANE time, which the unattended runner should not take on its own.

## Results, 2026-11-08 (run on the Mac)

Run setup: M1 Pro, macOS 26.6.2, FluidAudio 0.18.2, int8 Nemotron encoders. The streaming arms
were added to `benchmarks/local-asr` on this branch.

Clips: 10 synthetic, 59 real, 46 pilot. The real reference is the cloud transcript the user
accepted. The pilot reference is the spoken corpus text; "words" drops the spoken
Komma/Punkt words.

Streaming arms were fed 80 ms buffers as fast as possible. Two reading notes:

- **Lag** is the audio position at which a word first appears in the partial text, minus that
  word's end time. It does not include compute time.
- **RTF** is total decode time ÷ audio time, so on this Mac the real live delay is roughly lag
  plus one step's compute.

| engine | WER real | WER pilot | pilot words | terms pilot | lag p50 / p90 | RTF |
|---|---:|---:|---:|---:|---:|---:|
| parakeet-ultra (offline, ships) | 5.1 % | 17.1 % | **7.1 %** | 10/12 | — | 0.025 |
| nemotron-unified (offline) | 5.8 % | 18.3 % | 10.4 % | 10/12 | — | 0.045 |
| parakeet-ultra-sliding (planned preview engine) | **4.8 %** | 17.1 % | **7.1 %** | 10/12 | not measured | 0.022 |
| nemotron-stream-2080 | 5.1 % | 18.7 % | 10.4 % | 10/12 | 1.28 / 1.84 s | 0.13 |
| nemotron-stream-1120 | 6.2 %* | 20.2 % | 11.8 % | 10/12 | 0.64 / 0.96 s | 0.24 |
| nemotron-stream-560 | 6.2 %* | 17.5 % | 10.0 % | 10/12 | 0.40 / 0.48 s | 0.58 |

\* Two real clips failed to open in each of these two arms (`ExtAudioFileOpenURL`). The app
container's recordings changed during the ~40 min run, so those arms are scored on 57 clips.

The WER figures above are the *final* text. For the sliding window that is the confirmed text,
which only firms up after ~11 s chunk + 2 s right context (`SlidingWindowAsrConfig.streaming`).
Its tentative hypothesis updates every 1 s, and the quality of that tentative text was not
measured.

**Reading:**

- **Offline:** the 2026-11-04 result holds. Nemotron's pilot error rate is ~3 points worse than
  Ultra's, and it mishears the user's voice more often.
- **Streaming:** Nemotron's one real advantage is a low, predictable delay, 0.4–0.6 s at the
  560 ms bundle. It pays for that in three ways:
  - ~40 % more word errors on the pilot dictation (10.0 % vs 7.1 %)
  - 0.58× real time of compute on an M1 Pro (~23× Ultra's)
  - a second ~570 MB+ download beside Ultra
- **The live preview** (`live-dictate-preview.md`) only shows text. Stop still pastes Ultra's
  offline decode, so the preview's accuracy matters less than its cost, and Nemotron's cost is the
  higher one. Keep the planned SlidingWindow over Ultra: no extra download, Ultra-level final
  text, 1 s tentative updates.

**What would reopen it:** pilots who use the preview complain that it lags (the 1 s tentative /
~13 s confirmed rhythm), *and* a newer Nemotron or FluidAudio cache-aware path cuts the compute.
Then re-run `--engines parakeet-ultra-sliding,nemotron-stream-560` with a lag metric for the
tentative sliding-window text.

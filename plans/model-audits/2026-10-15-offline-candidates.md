VERDICT: speech stays on Parakeet Ultra; for Dictate Prompt, benchmark Granite 4.2 3B, Gemma 4 E4B and LFM2.5 2.6B against Qwen3 4B Instruct 2507

# Offline candidates check, 2026-10-15

Shipped: Parakeet Ultra + CTC vocabulary (recommended) and the Whisper models for speech;
Qwen3 4B Instruct 2507 on MLX for offline Dictate Prompt. FluidAudio is pinned at 0.17.5.
Sources: `scripts/hf-offline-lineup.py`, the HF API per org (sorted by `createdAt`), FluidAudio
GitHub releases up to v0.17.7.

## Speech: nothing new to adopt

| Candidate | Decision | Why |
|---|---|---|
| FluidAudio v0.17.6 / v0.17.7 | **No upgrade needed** | Only TTS changes (Paradee-8M, Kokoro fixes). Nothing for ASR. |
| Phonon-2 | **No** (already decided 2026-10-12) | English only, less accurate than Ultra. |
| Qwen3-ASR 0.6B (`FluidInference/qwen3-asr-0.6b-coreml`) | **No** | German is supported, but the Core ML build runs at 2.8× real time on an M4 Pro (about 20 s for a 1-minute clip, against 0.5 s for Ultra) and has 4.4 % WER on test-clean vs 2.13 %. |
| Canary-1B-v2 (`FluidInference/canary-1b-v2-coreml`) | **No, for now** | Covers the same 25 EU languages as Ultra. It is an autoregressive AED model with a fixed 15 s window, has no FluidAudio manager or docs, and would be slower. Revisit only if the pilot debrief names misheard medical terms as a top complaint. |
| Nemotron streaming multilingual 0.6B | **No** | Has no HF repo; you have to convert it yourself (Linux + CUDA). It is streaming only, which is out of scope (D2). |
| Mistral Voxtral Mini 4B Realtime (Arabic, 2026-10-08) | **No** | Arabic only, and there is no Core ML or FluidAudio path. |

## Dictate Prompt (MLX): three untested candidates

None of these has been measured with `scripts/benchmark-offline-prompt.py` yet. The 2026-09-30
benchmark covered only Qwen3.5 and Gemma 4 **E2B**.

| Candidate | Why it is worth a run | Risk |
|---|---|---|
| **IBM Granite 4.2 3B** (2026-08-25, Apache 2.0, official `ibm-granite/granite-4.2-3b-*-mlx`) | Dense, so the prefix cache works. German is a tested language. `Granite.swift` already exists in mlx-swift-lm. | It is a reasoning model with `<think>`, so thinking must switch off cleanly. |
| **Gemma 4 E4B** (QAT 4-bit in mlx-community) | E2B scored 33/36 at the same latency as Qwen3 4B; E4B is the larger sibling. | E2B translated German to English (3/3). If E4B does the same, it is a no. |
| **LFM2.5 2.6B** (LiquidAI, `de` in its card) | Smaller and probably faster; `LFM2.swift` exists. | LFM Open License (free under a revenue cap). German quality is unknown. |

Ruled out without a benchmark:

- MiniCPM5 2B (en/zh only).
- Phi-4-mini (older than Qwen3 4B 2507).
- MiMo-V2.6-Distill-Qwen-9B and tmax-9b (9B reasoning models: too slow for a 1 s target).
- FrogNano-4B (a coding agent built on Qwen3.5 4B).
- Kolibri-1 (Aleph Alpha, German, but 78B).
- Qwen3.8 (no small dense size; Flash-Next is ~180B).
- LFM2.5-24B-A2B (24B weights, too large in RAM for a 16 GB Mac).

## Watcher gap

`hf-offline-lineup.py` seeded the five MLX entries on 2026-09-30 without anyone evaluating them.
It also does not list Granite 4.2, because its MLX builds come from `ibm-granite` and not
`mlx-community`.

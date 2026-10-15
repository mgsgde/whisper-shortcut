VERDICT: speech stays on Parakeet Ultra, Dictate Prompt stays on Qwen3 4B Instruct 2507; Granite 4.2 3B, Gemma 4 E4B and LFM2.5 2.6B measured, none adopted

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

## Benchmark result (same day)

`scripts/benchmark-offline-prompt.py`, M1 Pro 16 GB, app system prompt, temperature 0.6, thinking
off. Run 1 used 3 rounds on mlx-lm 0.31.3. Run 2 used 5 rounds on mlx-lm 0.32.0, which was needed
for LFM2.5. Raw output is in `build/model-audits/2026-10-15-offline-prompt{,-r5}.txt` (local).

| Model | Rules, 3 rounds | Rules, 5 rounds | Median latency | Peak RAM | Writing cases (read by Opus 5.5) |
|---|---|---|---|---|---|
| **Qwen3 4B Instruct 2507** (shipped) | 32/36 | 54/60 | 0.64–0.72 s | 3.0 GB | Still the best. The typo fix is clean, the bullets are clean and the English is natural. The mail still says "Sehr geehrte Sarah". |
| Granite 4.2 3B (`ibm-granite/granite-4.2-3b-q4-mlx`) | 33/36 | 53/60 | **0.54–0.64 s** | 2.8 GB | Weaker. The typo fix leaves almost everything lowercase and turns "aufschlüssen" into "aufschluss geben". The mail is a single bullet line using "Sie". Translate left the text German in 2 of 5 runs. |
| Gemma 4 E4B QAT (`mlx-community/gemma-4-E4B-it-qat-4bit`) | 32/36 | not run | 2.79 s (p90 9.6 s) | 6.5 GB | The writing is good (best typo fix), but it is 4× slower, needs twice the RAM and formalises casual text. |
| LFM2.5 2.6B (`LiquidAI/LFM2.5-2.6B-MLX-4bit`) | load failed¹ | 55/60 | 6.07 s (p90 14.5 s) | 2.4 GB | There is no prefix cache (its conv state cannot be trimmed), so every request prefills the system prompt again. It pads the bullets with "Verantwortlich: Team/Management", changes the deliberately wrong date and appends instead of editing. |

¹ `mlx-community/LFM2.5-2.6B-4bit` is a broken conversion: its weights carry a `language_model.`
prefix. LiquidAI's own MLX build loads.

The rule scores lie within the noise. Qwen itself moved from 34/36 on 2026-09-30 to 32/36 today,
which also makes the queue row's threshold of 34/36 too strict. What separates the models is
latency and the writing cases. Only Granite is faster, and it writes noticeably worse German.

Queue row 30 is marked DROPPED. Re-run when a new small dense instruct model with good German
appears.

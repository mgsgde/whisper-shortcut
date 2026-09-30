VERDICT: keep Qwen3 4B Instruct 2507 as the offline default; remove Qwen3 8B; no successor yet

# Offline Dictate Prompt benchmark — 2026-09-30

`scripts/benchmark-offline-prompt.py` (Python mlx-lm 0.31.3, M1 Pro 16 GB). The 9 rule cases of
`benchmark-dictate-prompt.py` × 3 rounds, instruction as text (the offline path transcribes
first), app system prompt, temp 0.6, thinking off, plus 4 judged writing cases read by Opus 5.5.
Raw output: `build/model-audits/2026-09-30-offline-prompt-*.txt` (local, gitignored).

| Model | Rules | Median latency | Peak RAM | Judged cases |
|---|---|---|---|---|
| **Qwen3 4B Instruct 2507** (shipped default) | **34/36** | **0.94 s** | 3.0 GB | Best typo fix, clean bullets, clean English; polite mail garbled ("Sehr geehrte Sarah" + "Ihre", placeholder) |
| Qwen3 8B (shipped, now removed) | 30/36 | 2.02 s | 5.3 GB | Appends instead of editing (3/3); no mail, just a sentence; bullets padded with "(Verantwortlich: Team)" |
| Qwen3.5 4B | 31/36 | 2.67 s¹ | 3.5 GB | Best polite mail; but translated English into German (2/3) and left typos unfixed |
| Qwen3.5 9B | 28/36 | 4.29 s¹ | 6.0 GB | Good mail and bullets; but formalises casual text (3/3), "fixed" 30. Feb → 29. Feb, translated EN→DE |
| Gemma 4 E2B | 33/36 | 0.95 s | 3.1 GB | Translated a German message to English (3/3); no mail; left "aufschlüssen" |

¹ No prefix cache: Qwen3.5's hybrid attention state is not trimmable in mlx-lm, so every request
re-prefills the ~2k-char system prompt. `MLXPromptCache` in the app may hit the same limit — check
before shipping any Qwen3.5 model.

Every model fails `preserve-tone` (capitalises a deliberately lowercase message); that case does
not separate them.

## Decisions

- Qwen3 8B removed from the catalogue (owner, 2026-09-30: „Dann Qwen3-8B aus dem Katalog nehmen").
- No new model added: the one breaking the language rule (Qwen3.5, Gemma) is worse than a clumsy
  mail — it silently rewrites a message in the wrong language.
- Re-run when `model-lineup-check.sh` reports a new `hf-mlx` base model.

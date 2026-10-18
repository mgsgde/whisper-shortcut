VERDICT: add Qwen3.5 9B as a Chat-only offline model (RAM floor 16 GB); Qwen3 4B Instruct stays the default and the only offline Dictate Prompt model. Qwen3-30B-A3B, Qwen3.6-35B-A3B, Gemma 4 12B and gpt-oss-20b rejected.

# Larger offline model for Chat, 2026-10-18

Question (Magnus, 2026-10-18): should offline Chat offer a stronger model than Qwen3 4B Instruct,
which garbled a yt-dlp command? Condition he added: „das lohnt sich aber nur wenn ich das stärkere
modell auch auf meinem mac ausführen kann" — his Mac is an **M1 Pro with 16 GB**, so anything that
does not run well there is out, however good it is.

## Candidates

| Candidate | Size (4-bit) | mlx-swift-lm 3.32.3 | Decision |
|---|---|---|---|
| `mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit` (brief) | 17.2 GB | `qwen3_moe` ✓ | **Not measured, does not fit 16 GB.** Also superseded by Qwen3.6-35B-A3B. |
| `mlx-community/Qwen3.6-35B-A3B-4bit` | 20.4 GB | `qwen3_5_moe` ✓ | Not measured: needs a 32 GB Mac. REAP-19B prune (14.9 GB) still too tight and pruning hurts general knowledge. |
| `mlx-community/gemma-4-26B-A4B-it-qat-4bit` | 15.6 GB | `gemma4` ✓ | Not measured: does not fit 16 GB. |
| `mlx-community/gpt-oss-20b-MXFP4-Q4` (brief) | 11.2 GB | `gpt_oss` ✓ | Measured, rejected. |
| `mlx-community/gemma-4-12B-it-qat-4bit` | 11.0 GB | `gemma4` ✓ | Measured, rejected. |
| `mlx-community/Qwen3.5-9B-MLX-4bit` | 5.6 GB | `qwen3_5` ✓ | Measured, **adopted for Chat**. |

## Measurement

`scripts/benchmark-offline-chat.py` (new): the app's `defaultOfflineChatSystemPrompt` (from PR #129,
read from the Swift source), ten real questions (6 German, 4 English: yt-dlp, port 8080, GmbH vs UG,
HTTPS validation, Westfälischer Frieden, "Atemlos durch die Nacht", CSV average, decline-a-meeting
mail, a casual DE→EN translation, a 20 % rent increase). Python mlx-lm 0.32.0, temperature 0.6,
thinking off (gpt-oss: reasoning effort low), one round, no prefix cache (full prefill per request,
which is what Qwen3.5 gets in the app anyway). M1 Pro 16 GB, other apps running. Raw output:
`build/chat-bench-*.txt` in the worktree (local).

| Model | Peak RAM | First token | First visible token | Decode |
|---|---|---|---|---|
| Qwen3 4B Instruct 2507 (shipped) | 2.9 GB | 0.94 s | 0.94 s | 42.1 tok/s |
| **Qwen3.5 9B** | 5.8 GB | 2.01 s | 2.01 s | 18.8 tok/s |
| Gemma 4 12B QAT | 11.5 GB | 3.50 s | 3.50 s | 12.9 tok/s |
| gpt-oss-20b MXFP4 | 11.6 GB | 1.28 s | 4.06 s | 48.1 tok/s |

## Answers (read by Opus 5.5)

| Question | 4B | 9B | Gemma 12B | gpt-oss-20b |
|---|---|---|---|---|
| yt-dlp mp3 | ✓ (plus an emoji against the prompt) | ✓ | ✓, mentions ffmpeg | ✓ |
| port 8080 | ✓ | ✓ | ✓ | ✓, rambling |
| GmbH vs UG | ✗ "Unternehmensgesellschaft", UG 1 000 € | ✓ 1 €, Rücklage (detail off) | ✓ best | ✗ "Notarzt", GmbH "two partners" |
| HTTPS | ✓ | ✓ terse | ✓ best | ✗ reasoning text leaks into the answer three times |
| Westfälischer Frieden | ✗ England and Brandenburg as parties | ✓ | ✓ | ~ "Dreißjährige", invented trade clauses |
| Atemlos (Helene Fischer, 2013) | ✗ Sido, 2004 | ✗ Modern Talking, 1987 | ✗ Andrea Berg, 1994 | says it does not know (best) |
| CSV average | ✓ | ✓ (manual split) | ✓ | ✓ |
| Decline mail | ✓ | ✓ | ✓ in a markdown block, as the prompt asks | ✓ |
| DE→EN translation | ✓ | ✓ | ✓ | ✓ |
| Rent +20 % | ✗ invents "Mietpreisbremse 3 % per year" | ~ right direction, misses the Kappungsgrenze | ~ closer, mixes up Neuvermietung | ✗ invents a 12-month rule; reasoning leaks again |

- **4B:** four clear factual errors out of ten, all in German knowledge questions — exactly the
  "weak answers" complaint.
- **9B:** one clear error (pop trivia, which every model except gpt-oss got wrong), two answers
  that are directionally right but miss a detail. Clearly better German, same concise style.
  Half the speed of the 4B, but 19 tok/s is still faster than reading, and the first token at 2 s
  is acceptable for chat (not for Dictate Prompt, where it also failed the language rules on
  2026-09-30 — so it stays out of Dictate Prompt).
- **Gemma 4 12B:** best knowledge answers, but 11.5 GB on a 16 GB Mac evicts everything else
  (Parakeet, the browser), 3.5 s to the first token, 13 tok/s, and stray `<image|>` tokens inside
  the text. Too heavy for the machine it would have to run on.
- **gpt-oss-20b:** fast decode, but the low-effort reasoning loops and its analysis channel spills
  into the visible answer (3 of 10), the German is broken ("Notarzt-Beglaubnis",
  "Dreißjährige"), and the app would need a harmony-channel parser. Rejected.

## What ships

Qwen3.5 9B as a second catalogue entry, `supportsDictatePrompt = false`, offered only on Macs with
≥ 16 GB physical RAM. Not the default; the 4B stays the onboarding download and the Offline Mode
fallback. Qwen3.5's hybrid attention cache cannot be trimmed, so `MLXPromptCache` falls back to a
plain session and every turn prefills the short offline prompt again — already included in the
2.0 s above.

### Checked through the app's own Swift loader

`LocalLLMBenchmarkTests.mlxChatAnswer` (opt-in, `WHISPERSHORTCUT_BENCH_LOCAL_LLM=1
WHISPERSHORTCUT_BENCH_MLX_MODEL=local-mlx-qwen3.5-9b`, passed via `TEST_RUNNER_` env vars to
`xcodebuild test`): mlx-swift-lm 3.32.3 loads the VLM-format `qwen3_5` checkpoint as text-only,
`enable_thinking: false` holds (no `<think>` in the stream), cold first token 7.2 s (weights from
disk), warm first token **1.8 s**, about 11.5 s for a ~200-word answer.

Honest caveat: the two GmbH/UG answers from that run still carry wrong details (an invented
"Gewerbesteuer" threshold, "UG … oder GmbH & Co. KG"). The 9B is better than the 4B, not
reliable; that is why it is an opt-in choice and not the default, and the cloud models stay the
answer for anything that matters.

Revisit when a 32 GB-class MoE should be offered to bigger Macs (Qwen3.6-35B-A3B is the candidate);
that needs a measurement on a 32 GB machine, which this Mac cannot provide.

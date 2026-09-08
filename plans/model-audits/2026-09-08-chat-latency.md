# Chat latency: gemini-3.7-flash vs gemini-3.8-flash — settled

The 2026-09-03 audit left exactly one question open about the Chat default. It measured 3.8
~12% slower than 3.7 (2958 vs 2640 ms, n=5, overlapping ranges) and said, correctly:

> Measurement beats the version number: add 3.8, then run a proper interleaved latency
> comparison before hiding 3.7.

This is that comparison. Run 2026-09-08 with `scripts/benchmark-chat-latency.py`.

## What the old probe got wrong

Not the arithmetic — the request. The audit's probe sent a bare `generateContent`. The app does
not:

- `GeminiAPIClient.swift:414` attaches `google_search` + `url_context` + `code_execution` to every
  chat turn, so a search round-trip lands **before** the first visible word.
- `PromptModel.geminiThinkingConfig` pins BOTH models to `thinkingLevel: low`
  (`SettingsConfiguration.swift:587`/`:591`), which the probe did not send.

A latency number measured without those is timing a code path no user reaches. Re-run with them,
and the gap disappears.

Two further changes, each of which can flip the sign on its own:

- **Interleaved, not batched.** A/B then B/A every round, so a slow minute of the API lands on
  both models rather than on whichever went second.
- **Time to first token, not total.** Chat streams into a bubble. Total time is mostly a function
  of how long an answer the model chose to write — 3.8 writes ~18% more, which is a verbosity
  difference wearing a speed difference's clothes.

Prompts come from the staged usage log, so the mix is the operator's own: 12 real questions from
25 to 3776 characters, spanning short factual, tool troubleshooting, opinion and one long paste.

## Result — 12 prompts × 3 rounds × 2 models, time to first token

| Model | Median | Mean | p25 | p75 | Errors |
|---|---|---|---|---|---|
| `gemini-3.7-flash` | 1603 ms | 2503 ms | 1046 ms | 2495 ms | 0/36 |
| `gemini-3.8-flash` | 1752 ms | 2457 ms | 980 ms | 3400 ms | 0/36 |

Paired per prompt: **3.7 faster on 7 of 12, 3.8 on 5.** Median paired delta 292 ms toward 3.7.

Total time favours 3.7 (3526 vs 4263 ms median) but answer length differs in the same direction
(1472 vs 1730 chars): **per character both are identical, 2.40 vs 2.46 ms**.

**Verdict: the difference is noise.** Means are within 2%, the sign flips depending on which
statistic you pick, and the per-prompt winner is close to a coin flip. The 12% claim does not
survive a measurement shaped like the app's own request.

## Quality and screenshots — the axis nothing had measured

5 real prompts plus one screenshot turn (`screenshots/images/chat.png`, "Was sehe ich hier? Wo
klicke ich, um das Modell zu wechseln?"). Screenshot turns are ~10% of real chat use — 14 of 142
messages in the 2026-09-07 window carried an image and no text at all.

- **Screenshot: tie.** Both locate the model dropdown bottom-right and additionally name the slash
  commands. No difference worth a sentence.
- **Factual: tie.** Both invent *different* Plaud subscription prices ($/€ per month) with
  grounding enabled, so one of them is wrong. Not an argument either way — but a caution against
  reading either model's numbers as sourced.
- **3.8 marginally better on under-specified questions.** Asked "Wenn ich hier auf verschieben
  drücke…" with no screenshot attached, 3.7 mostly asked back; 3.8 asked back *and* explained what
  "verschieben" means per platform. At a median question length of 98 characters this is the
  common case.
- **3.8 is ~18% more verbose.** Against a median wanted answer of 533 characters, that is a mild
  negative, not a feature.

## What follows

**No code change.** Do NOT set `gemini37Flash.chatReplacement = .gemini38Flash`: a tie does not
justify removing a model from the lineup. The condition the 2026-09-03 audit set was "3.8 measures
better", not "3.8 measures no worse".

`ChatDefaults.selectedChatModel` is already `gemini38Flash`, so fresh installs get the
current-generation model; an existing selection on 3.7 stays until the user types `/gemini38flash`.
That asymmetry is deliberate and correct.

**For the next audit:** this question is closed. Re-open it only if Google announces a shutdown
date for 3.7 (it is filed "previous-generation" today, with no date), or if a measurement using
`scripts/benchmark-chat-latency.py` shows a gap that survives the paired comparison.

# Lineup check 2026-10-12 (from the biweekly mail)

| New ID | Decision | Why |
|---|---|---|
| `gemini-nano-banana-2.1` | **Replaces** `gemini-3.1-flash-image` (`geminiImage`) | GA, better quality/typography, about half the price per image ($0.034 vs $0.067 at 1K). Input rate is higher ($1.50 vs $0.50 per 1M) but small for prompt-sized inputs. Probe: `:generateContent` with IMAGE returns inlineData. |
| `claude-haiku-5-5` | **Replaces** Haiku 4.5 (`claudeHaiku55`) | $0.10/$0.50 vs $1/$5, 1M context, adaptive thinking + effort. Dominates on every axis. Not probed live (no Anthropic key on this machine). |
| `gpt-6.1-sol` | **Not added** (same as 2026-10-03 audit) | Re-probed: still rejects `reasoning_effort: "none"` (breaks `/think minimal`), median ~3.1 s vs ~1.9 s for `gpt-6-sol`. Revisit when `gpt-6-sol` is deprecated. |
| `grok-imagine-video-1.5-lite` | **No** | The app has no video generation. `model-lineup-check.sh` now filters `imagine` ids. |
| `FluidInference/phonon-2-coreml` | **No** | English only (Ultra covers 25 languages, the user dictates in German). Less accurate than Ultra on every set the publisher reports (test-clean 2.47 % vs 2.13 %, test-other 4.62 % vs 3.81 %, long-form trails v3). Same speed as Ultra. Its only advantage is size (321 MB vs 595 MB). No benchmark needed. |

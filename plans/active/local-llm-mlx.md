# Local LLM without a server — Dictate Prompt on MLX

**Status:** Proposed, not started. Written 2026-08-31 against `main` at v8.02.
**Goal:** Make an offline LLM for Dictate Prompt as easy to pick as an offline Whisper model — select it, it downloads in the background, it works. No Ollama, no LM Studio, no port.
**Audience:** Whoever implements this. Read [The dependency blocker](#the-dependency-blocker-read-this-first) before estimating anything.

---

## Why

Today "local Dictate Prompt" means: install Ollama yourself, run it, pull a model, paste an endpoint
into Settings. The Settings page calls this the "fully offline recipe", and its step 3 is a different
program. Offline **dictation** has no such step — you pick Whisper Large v3 Turbo from a list and it
downloads itself (`ModelManager.ensureReady`). The asymmetry is the whole problem.

Three payoffs, and the third is the one that matters most for this app:

1. **The prerequisite disappears.** Same gesture as the Whisper model list.
2. **Offline Mode stops depending on a second program.** It moves Dictate Prompt onto the local
   model (`ModelSelectionReconciler.reconcileForOfflineMode`); today that only helps users who
   already run a server.
3. **It is faster, not just more convenient.** In-process means no HTTP, no SSE parsing, no port,
   no five-minute eviction, no `keep_alive`, and no guessing which server reads which thinking
   field. A good part of `ConnectionPrewarmer.warmLocalModel` and the two-spelling thinking switch
   in `LocalLLMChatProvider.requestBody` exists **only** because a foreign server sits in between.
   Token streaming becomes a callback instead of a byte-stream parser.

Ollama support stays. Someone running a 70B model on a big machine wants exactly that. It just
stops being the only local option and stops being the one we recommend.

---

## The dependency question — resolved 2026-08-31: no WhisperKit upgrade needed

An earlier draft of this plan opened with a blocker: WhisperKit as pinned constrains
`swift-transformers` to `<1.2.0`, while the MLX quick start asks for `>=1.3.0`, and the ranges do
not intersect. That would have made a WhisperKit upgrade step 0 — a risky change on the code path
of the app's core feature.

**It does not apply.** `mlx-swift-lm` 3.x declares exactly two package dependencies:

```swift
.package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.6")),
.package(url: "https://github.com/swiftlang/swift-syntax.git", "602.0.0" ..< "604.0.0"),
```

**`swift-transformers` is not among them.** `MLXLLM` depends on `MLXLMCommon` plus MLX products;
`MLXLMCommon` depends on MLX products alone. Decoupling from tokenizer and downloader packages *is*
the 3.x breaking change the package README calls out. The `swift-transformers from "1.3.0"` line in
its quick start is a dependency of **the example app**, chosen there to satisfy the `MLXHuggingFace`
convenience macros — not a constraint `mlx-swift-lm` imposes on consumers.

So the integration path is the first of the three the package documents: implement `Downloader`,
`Tokenizer` and `TokenizerLoader` ourselves. The docs describe these as "only a few properties and
methods [with] trivial mappings to the concrete implementation" and ship a worked `Downloader`
example. We already have `swift-transformers 1.1.9` resolved with its `Hub` and `Tokenizers`
products — WhisperKit consumes both — so the adapters can be written against the version already in
the graph, and nothing needs to move.

```swift
let model = try await loadModel(from: downloader, using: tokenizerLoader,
                                id: "mlx-community/Qwen3-4B-4bit")
let session = ChatSession(model)
```

Avoid the `MLXHuggingFace` product for a second reason too: its target pulls `MLXFoundationModels`
under a **default-on** trait, and that surface needs the macOS 27 SDK. Depending on `MLXLLM` +
`MLXLMCommon` only sidesteps both the trait and the tokenizer-package question.

**Caveat on this finding:** it is read off the dependency graph, not off a successful build. Nothing
has been compiled. The first task below is the cheap experiment that turns it into fact.

---

## What exists to build on

The Whisper side already solved every problem this feature has, and the solutions are reusable
patterns rather than reusable code:

- `OfflineModelType` (`ModelManager.swift`) — model catalogue with display name, size, recommended
  flag, superseded flag, and the HuggingFace variant string.
- `ModelManager` — path resolution, availability check (does the folder hold real files, not a
  half-download), `downloadProgress`, `readyTasks` so a dictation joins an in-flight download
  instead of starting a second one, and `ensureReady`.
- `MenuBarController.prepareOfflineModelInBackground` — "selecting a model downloads and loads it",
  wired to `.modelChanged`.
- `LocalSpeechService` — the actor that owns the loaded model, with per-model compute-unit choice.

The LLM side needs the same four things with different nouns. Read those first; do not invent a
second vocabulary for the same concepts.

---

## Target design

Add a second local provider **beside** the endpoint-based one, not instead of it.

```
PromptModel.localModel      → LocalLLMChatProvider   (HTTP → Ollama / LM Studio)   unchanged
PromptModel.localMLXModel   → MLXChatProvider        (in-process, MLX)             new
```

`MLXChatProvider` conforms to the existing `LLMChatProvider` protocol and returns the same
`AsyncThrowingStream<ChatStreamEvent, Error>`, so `SpeechService.executePromptWithLocal` needs
almost nothing: the transcribe-first flow, the envelope, history, `<think>` stripping, the SPEED
logging and the timing split all stay. **This is the reason to keep the provider protocol as the
seam** — the feature is a new provider, not a new pipeline.

Model catalogue mirrors `OfflineModelType`:

```swift
enum LocalLLMModelType: String, CaseIterable {
  case qwen3_4b        // mlx-community/Qwen3-4B-4bit      ~2.3 GB
  case qwen3_8b        // mlx-community/Qwen3-8B-4bit      ~4.5 GB
  // …plus whatever the model audit picks; keep the list short and opinionated,
  // the way the Whisper list ended up after turbo retired Medium and Large.
}
```

Package (versions verified 2026-08-31):

```swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
.package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
```

Products: `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`. Requires macOS 14+ (we ship 15.5) and Swift
tools 6.2 (we build with Xcode 26.5 / Swift 6.3.2) — both fine.

Loading and generating, per the package's own quick start:

```swift
let model = try await #huggingFaceLoadModelContainer(configuration: ...)
let session = ChatSession(model)
```

Do **not** enable the `MLXFoundationModels` product: its `MLXLanguageModel` surface needs the
macOS 27 SDK. We only want `MLXLLM` + `MLXLMCommon`.

---

## Slices

Each slice ships on its own and leaves the app working.

**Slice 0 — prove the graph resolves.** Add `mlx-swift-lm` with **only** `MLXLLM` and `MLXLMCommon`,
change no other dependency, and build both schemes. Gate: SPM resolves with `swift-transformers`
still at 1.1.9, `rebuild-and-restart.sh` **and** `--app-store` both succeed, `run-tests.sh` green,
and offline dictation with Turbo is unchanged (compare the existing `SPEED: Whisper transcription`
lines — we already log what a regression would look like). Also record the `.pkg` size before and
after; this is the cheapest moment to learn what MLX costs in download size.

If resolution unexpectedly fails, the fallback is the WhisperKit upgrade to
[`argmaxinc/argmax-oss-swift`](https://github.com/argmaxinc/argmax-oss-swift) — its current `main`
dropped `swift-transformers` entirely — but that touches the core feature's code path and gets its
own slice and its own gate. Do not bundle it with MLX work; if offline dictation regresses we need
to know which change did it.

**Slice 1 — the provider, with a hardcoded model.** `MLXChatProvider` behind `LLMChatProvider`,
one model, model path resolved manually. No UI. Gate: Dictate Prompt end-to-end through MLX, and
a `SPEED: [mlx:<model>]` line that can be compared against the Ollama path's existing
`transcription + prefill + generation` split. **Measure before building the UI** — if it is not
meaningfully faster than the HTTP path, the case for the whole feature weakens and we should know
then, not after the settings work.

**Slice 2 — catalogue and download.** `LocalLLMModelType`, path resolution, availability, progress,
`ensureReady`, join-in-flight. Follow `ModelManager` closely.

**Slice 3 — Settings.** A model list next to the Whisper one, same visual language (Recommended
star, size, Download/Delete, progress). The "Local Server" endpoint section stays, demoted to the
bring-your-own-server option.

**Slice 4 — the seams.** `ModelSelectionReconciler.reconcileForOfflineMode` should prefer the MLX
model. Offline Mode's network guard must allow the HuggingFace download (it already does for
Whisper — reuse that rule, do not write a second one). Update `README.md` `## Features` — the
in-app Chat answers "what can this app do?" from it.

---

## Risks, named honestly

- **Binary size.** MLX ships Metal kernels. Measure the `.pkg` delta before and after; the App
  Store listing and download size are user-visible.
- **Memory.** Whisper Turbo is 1.6 GB resident; a 4-bit 8B model is ~4.5 GB more. On an 8 GB Mac
  that is not viable. The catalogue needs a small default and probably a machine-aware
  recommendation, the way `usesNeuralEngine` is a per-model decision today.
- **First-load cost.** Whisper's ANE compile took over 14 minutes for turbo before the GPU switch
  (`OfflineModelType.usesNeuralEngine` documents it). Assume nothing about MLX's first load —
  measure it, and if there is a warm-up cost, it belongs in the same background-load slot Whisper
  uses, not on the dictation critical path.
- **Sandbox / App Store.** Model download into Application Support is already proven by Whisper.
  Metal needs no entitlement. Still worth an explicit App-Store-scheme build early in Slice 0 —
  `rebuild-and-restart.sh --app-store` — rather than discovering a signing or sandbox problem at
  submission time.
- **A second inference stack to maintain.** Two local model catalogues, two download paths, two
  sets of "is it ready" logic. Slices 2 and 3 must genuinely share the Whisper patterns, or this
  becomes the app's most duplicated area.

---

## Open questions

1. ~~Does an MLX integration path exist that avoids `swift-transformers` entirely?~~ **Answered
   2026-08-31: yes** — see [the dependency section](#the-dependency-question--resolved-2026-08-31-no-whisperkit-upgrade-needed).
   The WhisperKit upgrade drops out of the plan unless Slice 0 surprises us.
2. How much of `Tokenizer` / `TokenizerLoader` does `swift-transformers` 1.1.9 satisfy? The
   `Downloader` mapping is shown in the docs and looks trivial; the tokenizer side is unexamined
   and is now the main unknown in Slice 1.
3. Which models make the catalogue? Route through the `llm-model-docs` / `audit-llm-models` skill
   rather than guessing — the Whisper list got good by being opinionated and short.
4. ~~Is MLX measurably faster than the local HTTP path for a Dictate Prompt rewrite?~~ **Measured
   2026-09-01 — no.** See [Slice 1 result](#slice-1-result-measured-2026-09-01).


---

## Slice 1 result (measured 2026-09-01)

Reproduce with `LocalLLMBenchmarkTests`: `TEST_RUNNER_WHISPERSHORTCUT_BENCH_LOCAL_LLM=1`, and
`TEST_RUNNER_WHISPERSHORTCUT_BENCH_OLLAMA_MODEL` to point both sides at the same model. Numbers
below are `qwen3:4b-instruct` on Ollama against `mlx-community/Qwen3-4B-Instruct-2507-4bit`, one
realistic Dictate Prompt turn, warm (the second request of a session — the common case).

| | prefill | generation | total |
|---|---|---|---|
| MLX, best of four runs | 3.01s | 0.94s | **3.95s** |
| MLX, worst | 12.49s | 4.21s | **16.70s** |
| Ollama | 0.37–0.89s | 0.91–0.98s | **1.02–1.80s** |

**Generation is not the problem.** In the cleanest run MLX produced 164 characters in 0.94s against
Ollama's 136 in 0.98s — per character MLX is marginally *faster*. An early reading that generation
was 4× slower was an artifact of measuring while Ollama held a model resident.

**Prefill is the whole gap, and it did not yield to the obvious fix.** MLX rebuilds a `ChatSession`
per request, so the thousand-token system prompt is prefilled every time; Ollama keeps the KV cache
of the shared prefix in its own process. mlx-swift-lm's prefix cache (`saveCache(to:)` +
`ChatSession(_:instructions:cache:)`) was implemented and measured: **3.85s with it against 3.01s
without**, inside the run-to-run spread. The reason is concrete — the cache for this prompt is a
**75 MB** `.safetensors` file, and deserializing it costs about what re-prefilling costs. That
mechanism exists to restore a long shared context across launches, not to pass KV state between two
requests in one process. Reverted; the finding is a comment where the next person would try it.

Closing the gap needs the KV state held **in memory** across requests. `ChatSession` takes the
cache `consuming` and mutates it while generating, so that is an architecture change around session
lifetime, not a patch.

**The other finding is variance.** MLX ranged 3.95s–16.70s across runs and once spent 71.95s in a
cold generation; Ollama stayed within 1.02–1.80s. MLX degraded roughly fourfold while Ollama held a
model resident. For a menu-bar app that also keeps Whisper Turbo's 1.6 GB in memory, that
sensitivity weighs as much as the mean — and argues for the `MLX.GPU.set(cacheLimit:)` that is
still unset.

**Recommendation at the time.** Ship MLX as the no-server convenience option, not as the
recommended model. *Superseded — see below.*

---

## Slice 1, second result (measured 2026-09-01, in-memory KV cache)

The in-memory path was built. Warm, same model, same conditions:

| | prefill | generation | total |
|---|---|---|---|
| MLX before | 3.01s | 0.94s | 3.95s |
| **MLX after** | **0.60s** | 0.79s | **1.39s** |
| Ollama | 0.36s | 1.15s | 1.51s |

Prefill fell 5×, into Ollama's range, and since generation was already marginally ahead (5.9ms per
character against 7.1ms) MLX is the faster of the two **on a quiet machine**.

What changed, in `MLXPromptCache`: the package's file-based prefix cache is used **once** — prefill,
`saveCache` to a temp file, `loadPromptCache` back, delete — and what survives between requests is
the layer state in memory. Sharing those arrays is safe for a reason read out of the framework
rather than assumed: after a `state` restore `offset == keys.dim(2)`, so `KVCacheSimple.update`
always takes its reallocating branch on the first token, builds new buffers with `concatenated`,
and writes only into those. The snapshot arrays are read, never written. Only the cache *objects*
are mutated, so each request gets fresh ones wrapping the shared arrays. Reconstruction is limited
to `KVCacheSimple`; anything else falls back to a per-request session.

Priming costs ~8.4s once per app session. `ConnectionPrewarmer.warmMLXModel` now pays it during the
recording, alongside the weights — the same trade `warmLocalModel` already makes for Ollama.

---

## Slice 1, third result (measured 2026-09-02, variance under memory pressure)

Re-ran `LocalLLMBenchmarkTests` with Ollama holding a model resident — the condition that
previously 4×'d MLX — after the in-memory cache shipped:

| | MLX total | Ollama total |
|---|---|---|
| machine free | 1.39s | 1.51s |
| other model resident | **4.13s** | 1.80s |

MLX prefill rose from 0.60s to 3.08s; Ollama only from 0.36s to 0.71s. The cache closed the gap
on a quiet machine. It did not close the sensitivity to memory pressure.

**Recommendation now.** Ship the cache — the 5× prefill win on a quiet machine is real, and the
no-server convenience claim was always true. Do **not** claim the in-process path is as fast as
a local server: that is one measurement, not the distribution. User-facing copy says "no server
to install"; the catalogue star stays "Best of these" (4B vs 8B). Still open:
`MLX.GPU.set(cacheLimit:)`.

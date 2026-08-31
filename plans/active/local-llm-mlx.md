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

## The dependency blocker (read this first)

**Adding MLX to the project as it stands will fail SPM resolution.** This is the single fact that
decides the shape and the order of the work.

| Package | Constraint on `swift-transformers` | Effective range |
|---|---|---|
| WhisperKit, as pinned today (rev `2870b46b`) | `.upToNextMinor(from: "1.1.2")` | `>=1.1.2, <1.2.0` |
| `mlx-swift-lm` HuggingFace integration | `from: "1.3.0"` | `>=1.3.0, <2.0.0` |

The ranges do not intersect. Currently resolved: `swift-transformers 1.1.9`.

**The way out:** upstream WhisperKit has been restructured into
[`argmaxinc/argmax-oss-swift`](https://github.com/argmaxinc/argmax-oss-swift) (the `argmaxinc/WhisperKit`
URL redirects there). Its current `main` **no longer depends on `swift-transformers` at all** — the
dependency list is `swift-argument-parser` plus optional server packages, and the package now ships
`ArgmaxCore` / `WhisperKit` / `TTSKit` / `SpeakerKit` targets. Upgrading removes the clash outright
rather than negotiating around it.

That upgrade is **its own slice with its own risk**, and it touches the code path the app's core
feature runs on. It is not a footnote to the MLX work; it is step 0. Do not start MLX before it is
green, and do not bundle the two into one commit series — if offline dictation regresses, we need to
know which change did it.

The alternative — an MLX integration path that avoids `swift-transformers` — is worth one hour of
investigation before committing to the upgrade. `mlx-swift-lm` states it "integrates with a variety
of tokenizer and downloader packages through protocol conformance" with three integration styles of
differing convenience. If a custom-downloader conformance sidesteps the constraint, step 0 becomes
optional. **Verify this first; it may save the whole upgrade.**

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

**Slice 0 — unblock the dependency.** Either prove an MLX integration path that avoids
`swift-transformers`, or upgrade WhisperKit to `argmax-oss-swift`. Gate: offline dictation with
Turbo works exactly as before, `run-tests.sh` green, load timings unchanged (compare the existing
`SPEED: Whisper transcription` lines — we already log what a regression would look like).

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

1. Does an MLX integration path exist that avoids `swift-transformers` entirely? (Decides whether
   Slice 0 is a one-hour spike or a WhisperKit upgrade.)
2. What does the `argmax-oss-swift` upgrade cost in API changes to `LocalSpeechService` and
   `ModelManager`?
3. Which models make the catalogue? Route through the `llm-model-docs` / `audit-llm-models` skill
   rather than guessing — the Whisper list got good by being opinionated and short.
4. Is MLX measurably faster than the local HTTP path for a Dictate Prompt rewrite? Slice 1 answers
   this, and it is the slice that should be allowed to kill the feature.

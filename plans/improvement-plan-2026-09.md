# App Improvement Plan — September 2026

**Status:** Implemented (F15 remaining half re-scoped 2026-09-03: Parakeet, not a shorter Whisper tail). Written against `main` at v8.05 (`2e2b058`).
**Audience:** The developer deciding what gets built next, and whoever implements a row.
**How it was produced:** Five read-only audits of the source (dictation pipeline, onboarding and
Settings, chat and providers, offline/local models, engineering health), cross-checked against
`plans/improvement-ledger.md`, `plans/instrumentation-gaps.md`, `plans/refactor-ledger.md`, the
open queue in `plans/implementer-queue.md`, the App Store reviews, and the private growth and
usage digests. The three highest-ranked bugs (D1, D2, D5) were verified by reading the code
paths, not only reported by the audit.

**What this plan deliberately leaves out.** Refactors already tracked in the refactor ledger
(R3 `ChatViewModel` slicing, R29 release scripts), anything about pricing, reach, or the marketing
site (private repo), and the license question (closed in issue #40). The growth ledger's current
verdict is that reach, not product quality, is the bottleneck — so this plan keeps to work that is
either **customer-facing reliability**, **first-run activation** (the store page → first successful
dictation path, which is the one funnel stage the app itself controls), or **the offline
differentiator**. Internal-quality work with no user-visible effect is listed only where it
protects a release.

---

## How to read the tiers

| Tier | Meaning | Time box |
| --- | --- | --- |
| 0 | Verified bugs and one-line fixes with high user impact. Do all of them, in one release. | one afternoon |
| 1 | Reliability of the core path (Dictate → clipboard). Each row is independently shippable. | 2–3 weeks, interleaved with normal work |
| 2 | First-run activation: the new user's path to a first successful dictation. | 1–2 weeks |
| 3 | Offline story completeness — the differentiator the App Store listing leads with. | 2–3 weeks |
| 4 | Chat quality and safety. | opportunistic |
| 5 | Engineering health that protects releases. Nothing here ships a feature. | opportunistic, small slices |

Effort: **S** = under half a day, **M** = one to three days, **L** = a week or more.
Every row that is a candidate for `plans/implementer-queue.md` carries a **Falsifier** — the
queue's rule is that a proposal without a ship-day-measurable falsifier is not eligible.

IDs: **D** dictation pipeline · **O** onboarding/Settings · **F** offline/local · **C** chat ·
**E** engineering. Ledger cross-references use their own IDs (I2…I7, gap #8, R6).

---

## Tier 0 — Fix now (all S, one release)

| ID | Finding | Where | Fix | Falsifier |
| --- | --- | --- | --- | --- |
| D1 | **`cancelTranscription()` is a no-op.** The `defer` that clears `currentTranscriptionTask` sits inside `if cancellable { … }`, so it runs at the end of the `if`, before `return try await task.value`. Every caller cancels `nil`; the HTTP request keeps running and keeps billing while the UI shows idle. | `SpeechService.swift:437-451` | Hoist the `defer` to function scope (guard its body on `cancellable`). | After Stop during `.processing(.transcribing)`, the log shows the provider request cancelled (`CANCELLATION:` marker) instead of completing; `cancelledWhileProcessing` signals stop being followed by a `pasted` for the same `refTs`. |
| D2 | **Retry on a failed dictation silently produces nothing.** The catch tail of `runAudioJob` sets `currentJobAudioURL = nil`; the popup's Retry re-runs `performTranscription(audioURL:)`, whose result then trips the staleness guard ("Dropping transcription result for cancelled recording") and is discarded. The user waits, sees nothing, lands on idle. | `MenuBarController.swift:1516-1538`, `:1622-1631`, `:1732-1734` | Set `currentJobAudioURL = audioURL` (and `appState = .processing`) in the retry action, the way `transcribeCancelledRecording()` at `:1239` does. | A retry after a forced 503 pastes the transcript; log shows no "Dropping transcription result" after `RETRY:`. |
| D5 | **Every non-benign error overwrites the clipboard with the error text.** A transient 503 destroys what the user had copied; the restore snapshot was already dropped. The popup shows the same message anyway. | `MenuBarController.swift:1505` | Delete the line. If the copy is wanted, put a "Copy details" button on the popup. | — |
| O1 | **Offline-Mode onboarding downloads Large v3 Turbo but selects Whisper Base.** Step picks `mostAccurate`, `syncReady()` hardcodes `.whisperBase`; the reconciler skips it because Base is offline too. The privacy-minded user waits for 1.6 GB, then the first dictation fails with "model not downloaded". | `Onboarding/WelcomeSteps.swift:317-319` vs `:408-411`; `ModelSelectionReconciler.swift:95` | `syncReady()` selects `TranscriptionModel.forOfflineModel(downloadedType)`. | Fresh install with Offline Mode on → first ⌘1 transcribes with the downloaded model. |
| O5 | **Offline-only users get Settings force-opened on every launch.** The launch fallback gates on `anyChatCredentialConfigured`; an offline Whisper model is not a chat credential. | `FullApp.swift:79`; `ProviderCredentials.swift:89-91` | Gate on "can transcribe" (`TranscriptionModel.loadSelected().hasRequiredCredential`). | — |
| F5 | **The Offline Mode switch's own description denies what shipped in 8.04.** It still says Dictate Prompt needs Ollama/LM Studio and that Chat does not work — both false since MLX. This is the one screen a privacy-motivated buyer reads. | `Settings/Tabs/PrivacyPermissionsTab.swift:73-74` | Rewrite the three bullets to match `README.md` "Offline Mode". | — |
| E1 | **OAuth callbacks accept any `code` — no `state` parameter.** PKCE stops code theft, not code injection: a page the user visits can hit `http://127.0.0.1:<port>/callback?code=…` and bind the app to an attacker's OpenRouter/Google account. | `LoopbackOAuthListener.swift:110-113`; no `state` anywhere in `*OAuth*.swift` | Generate a random `state`, send it in the authorize URL, reject callbacks whose `state` differs. | Manual: a callback with a wrong `state` is refused with a logged reason. |
| E2 | **WhisperKit and HotKey are pinned to `branch = main`.** Every clean resolve (including the tag-triggered release build) pulls whatever upstream has that day. The ASR engine of the app's core feature is unpinned. | `WhisperShortcut.xcodeproj/project.pbxproj:674-703` (two references each — one per target) | Pin both to a released tag with `upToNextMinorVersion`; pass `-disableAutomaticPackageResolution` in `release.yml`. | `Package.resolved` shows a version, not a bare revision, for both. |
| C10 | **The loop-stop notice is German** ("Antwort gestoppt: …") in an otherwise English UI, and it is persisted into the session. | `ChatStreamLoopGuard.swift:11` | Translate. | — |
| C15 | **Anthropic (Claude) is fully wired but undocumented.** Settings, key validation, `/claude` command all exist; README lists only Gemini/Grok/OpenAI/MLX for chat. The in-app Chat reads README, so it will deny the feature exists. | `README.md` Features + Requirements | Add the line. | — |
| doc | `plans/active/streaming-dictate.md` header says Slices 2–3 pending; Slice 2 shipped (`DictateStreamingSession.swift`, wired at `MenuBarController.swift:993,1024`). | | Update the status line. | — |

---

## Tier 1 — Reliability of the core path

### 1a. Stalls and network loss (extends ledger I2, implements I7)

| ID | Finding | Where | Fix | Effort | Falsifier |
| --- | --- | --- | --- | --- | --- |
| D3 | **Gemini has no `NetworkDeadline`, and a 300 s per-request timeout that overrides the session's 60 s.** I2's fix covered only the OpenAI-compatible path. Gemini — the default Dictate backend, plus Gemini TTS and the Gemini prompt path — still goes through `performRequest` → raw `session.data(for:)`, with `withRetry` up to 5 attempts. A stalled HTTP/2 connection can hold `.processing` for many minutes, exactly the I2 symptom. | `GeminiAPIClient.swift:98`, `:138`; `SpeechService.swift:1588-1593` | Route `performRequest` through `NetworkDeadline.data`, drop the 300 s override, keep the existing `.requestTimeout` popup. | M | `requestTimedOut` signals appear with `GEMINI-TRANSCRIPTION` in `detail.logPrefix`; no `cancelledWhileProcessing` with `gapMs > 120000` on Gemini in the next two review windows. |
| D4 | **Connection loss on OpenAI/xAI/self-hosted/OpenRouter deletes the recording with no Retry.** `NetworkDeadline` maps only `.timedOut`/`.cancelled`; `.notConnectedToInternet` propagates as a raw `URLError`, which `handleProcessingError` marks non-retryable and cleans up. Gemini maps the same condition to `.networkError` and *is* retryable. This is ledger **I7**'s "network connection was lost" pattern. | `NetworkDeadline.swift:37-41`; `MenuBarController.swift:1512`, `:1544-1546` | Map every `URLError` to `TranscriptionError.networkError` in the shared helper; add one automatic retry on transient `URLError` before the popup, mirroring the 429 budget. | S–M | Zero "network connection was lost" entries in `errors-*.log` without a matching retry line; audio retained on the popup. |
| I6 | **Gemini Flash-Lite glossary echo.** Ledger I6 (usage review run 5): after the glossary-echo discard and the no-glossary retry both return empty, fall back once to an alternate cloud STT on the same audio before surfacing no-speech. | `SpeechService.swift:2301-2310` | As proposed in the ledger. | M | Ledger I6's falsifier. |
| gap #8 | **Close instrumentation gap #8** (queue row 2, `HOLD`): emit a `noSpeechDetected` outcome signal from both the local silence gate and the API-empty path with `source`, `peakDb`, `durationMs`, `logPrefix`. Unblocks ledger I3, which has sat `proposed` since run 2 because nothing can grade it. | `MenuBarController.swift:2432`; `SpeechService.swift:2002` | As specified in the queue row. Instrumentation only. | S | Queue row 2's falsifier. |

### 1b. State-machine strands and clipboard correctness

| ID | Finding | Where | Fix | Effort |
| --- | --- | --- | --- | --- |
| D6 | **The app can strand in `.recording` while the mic permission dialog is up.** `appState` is set to `.recording` before `startRecording()`; if the shortcut is pressed again while the system prompt is showing, `stopRecording()` returns silently (nothing is recording), no delegate fires, and every menu action is dead until relaunch. | `MenuBarController.swift:1022`; `AudioRecorder.swift:109-121`, `:199`; `ChunkedDictateRecorder.swift:125`, `:168-171` | Enter `.recording` only from the permission-granted callback, and call `appState.finish()` when `stopRecording()` finds nothing running. | M |
| D7 | **The indicator ✕ can leave `discardNextRecording` armed** if the direct `stopRecording()` returns early (same conditions as D6). The next dictation is then discarded silently — the user speaks and gets nothing. | `MenuBarController.swift:538-543`, `:2526-2532` | Clear the flag in `startRecording()`, or arm it only once the stop is known to have taken effect. | S |
| D12 | **Clipboard restore fires unconditionally 0.45 s after paste.** Under fast repeated dictations, or a user ⌘C in that window, the restore clobbers the newer contents. | `ClipboardManager.swift:82-98`; `MenuBarController.swift:2489-2495` | Capture `pasteboard.changeCount` at write time; skip the restore if it changed. | S |
| D13 | **`simulatePaste` uses `.hidSystemState`**, so a still-held Fn or ⌥ from the shortcut turns ⌘V into ⌘⌥V ("Paste and Match Style" or worse) in the frontmost app. `simulateCopy` already uses `.privateState` for exactly this reason. | `MenuBarController.swift:2372-2374` vs `:2388`, `:2456` | Use `.privateState` for the paste event too. | S |
| D11 | **`validateSpeechText` drops real transcripts on substring matches.** `assistantRefusalPhrases` includes `"i can transcribe"` and `"provide the text you"` tested with `contains` over the whole transcript → `noSpeechDetected`, audio deleted, no error. `hasPrefix("transcription:")` → non-retryable `promptLeakDetected`. The bare prefix list (`"proper punctuation"`, `"please transcribe"`) is `dropFirst`-ed silently. | `TextProcessingUtility.swift:427`, `:471`, `:93` | Anchor refusal phrases (whole transcript is the refusal, or transcript is short); require word boundaries for prefixes. Add the unit test this function has never had (pairs with E4). | S |
| D14 | **`DictateStreamingSession.chunkTasks` is read from a background task and written on main with no lock** — only the cancel flag is protected. Works on today's delegate ordering; a Swift `Dictionary` read racing a write is undefined behaviour. | `DictateStreamingSession.swift:25`, `:56`, `:60`, `:87`, `:102` | Put `chunkTasks` behind the existing `cancelLock`, or make the class `@MainActor`. | S–M |

### 1c. Stop → clipboard latency (streaming Dictate's remaining tail)

Slice 2 of streaming Dictate shipped; what is left between Stop and paste is a set of serial steps
that do not need to be serial. Measure with the existing `SPEED:` markers before and after.

| ID | Finding | Where | Fix | Effort |
| --- | --- | --- | --- | --- |
| D8 | **Chunk merging runs on the main thread inside the stop path.** `finalizeSession` is dispatched to main and calls `mergeChunks` synchronously — an `AVAudioFile` read/write over every chunk (≈14 MB for five minutes), blocking the UI and delaying the delegate that starts the tail transcription. In the streaming case the merged WAV is needed only for the usage-log sample and the fallback. | `ChunkedDictateRecorder.swift:357-368`, `:385`, `:421-424` | Merge off main; deliver the tail transcript without waiting on the merge. | M |
| D9 | **A whole-file copy for the usage log sits serially before `produce()`.** | `MenuBarController.swift:1773`; `ContextLogger.swift:382` | Run it concurrently with the transcription (it is already discard-on-failure). | S |
| D10 | **Two awaits sit between the clipboard write and the paste** — model-info actor hop plus log disk I/O — before `autoPasteIfEnabled`. | `MenuBarController.swift:1637-1647` | Paste first, log after; `spec.modelInfo()` is already awaited later. | S |

Falsifier for 1c as a whole: median `SPEED:` stop→paste on a 60 s dictation drops measurably
(record ten runs before, ten after, same machine).

### 1d. Chat robustness (the rows with user-visible loss)

| ID | Finding | Where | Fix | Effort |
| --- | --- | --- | --- | --- |
| C2 | **Non-Gemini streams have no retry** — a Wi-Fi blip before the first token kills the reply (refactor-ledger R6's open item, ranked here for impact). | `LLMChatProvider.swift:386-420`; `AnthropicChatProvider.swift:74` | Wrap `openStream` in `RetryBackoff` for pre-first-token failures only. | M |
| C5 | **A corrupt sessions file destroys all chat history.** Decode failure → "starting fresh" → the only copy is overwritten. | `ChatSessionStore.swift:265-274` | Rename the bad file to `gemini-sessions.corrupt-<date>.json` before writing the fresh one; tell the user. | S |
| C6 | **A failure in a background chat tab is invisible** — the error is only surfaced when `sessionId == session.id`. | `ChatView.swift:1087` | Store the error on the session; render a failed-turn row with Retry. | S |
| C7 | **`finishReason` is parsed and thrown away** — a reply cut at `max_tokens` looks complete. | `ChatView.swift:971`; `LLMChatProvider.swift:610` | On `length`/`max_tokens`, append a "reply was truncated" note (same shape as the tool-exhaustion copy at `:1019`). | S |
| C8 | **Every provider's 5xx says "Gemini is temporarily unavailable"**; other providers leak raw JSON. | `ChatView.swift:2766-2773` | Carry the provider on the error; template the name. | S |

---

## Tier 2 — First-run activation

The onboarding is seven steps and does its job for a user with a Gemini key. The gaps are all on
the two paths the store listing leads with: **no key at all (offline)** and **something went wrong**.

| ID | Finding | Where | Fix | Effort |
| --- | --- | --- | --- | --- |
| O2 | **The 1.6 GB onboarding download has no progress, size, or cancel** — an indeterminate spinner for minutes, Continue disabled. `ModelManager.downloadProgress` is already published. | `Onboarding/WelcomeSteps.swift:355-361` | Bind progress and bytes; add Cancel; default Offline users to Base (140 MB) with Turbo offered as an upgrade in Settings. | S |
| F2 | **No disk-space check before a 1.6–4.5 GB download.** | `ModelManager.swift:284`; `LocalLLMModelManager.swift:214` | Compare `volumeAvailableCapacityForImportantUsage` against the existing `estimatedSizeMB` before starting. | S |
| F4 | **Whisper downloads cannot be cancelled** (MLX downloads can). | `ModelManager` has no `cancelDownload`; `LocalLLMModelManager.swift:186` | Mirror the MLX task-cancellation pattern in Settings → Dictate. | S |
| F3 | **A network drop mid-download purges the whole model folder and restarts from zero.** On a flaky connection a 3 GB model can loop indefinitely. | `ModelManager.swift:249-273`, `:390-413` | Keep the partial tree so Hub skips complete files; purge only on a verified-corrupt file. | M |
| O4 | **Closing onboarding halfway leaves a dead app until the next launch.** The tour is only re-shown from `applicationDidFinishLaunching`; a menu-bar app is rarely relaunched. The only signal is the ⚠️ glyph. | `WelcomeWindowController` `:47-58`; `FullApp.swift:75-81` | Persistent "Finish setup…" menu item while `hasCompletedOnboarding` is false. | S |
| O6 | **Offline Mode on step 2 leaves step 3 offering cloud providers that the URL guard will kill** ("nothing may leave this Mac"). | `WelcomeSteps.swift:104-108`, `:207-268` | Collapse cloud rows behind "I also want cloud features" when Offline Mode is on. | S |
| O8 | **Denied microphone is a hard wall.** "Grant Access" only renders for `.notDetermined`; a user who clicked Don't Allow sees a greyed Continue with no explanation of why the button no longer prompts. | `WelcomeView.swift:190-194`; `PermissionsOverview.swift:104-113` | For `.denied`: "macOS won't ask again — enable it in System Settings → Microphone, then return here", plus allow-skip. | S |
| O3 | **No "try it now" moment.** The Done step lists shortcuts; nothing verifies the key/model combination works before the window closes. The first real attempt happens later, in another app, with no context. | `WelcomeSteps.swift:865-960` | A "Try it" panel on the Done step: record 3 s, transcribe, show the text inline; on failure show the concrete error and a link to the right tab. | M |
| O7 | **Wrong "Settings → General" pointers** — the tour lives on About, the usage-data toggle on Smart Improvement. | `WelcomeSteps.swift:953`, `:851` | Fix the four "Settings → X" strings. | S |
| O13 | **App Store build: the Dictate Prompt screenshot-selection mode and the manual ⌘C requirement for offline models are explained only in README.** | `AppConstants.swift:66-74`; `WelcomeSteps.swift:906` | One App-Store-specific line on the Done step's Dictate Prompt row. | S |
| O14 | **Default ⌘1/⌘2/⌘3 collide with tab switching in browsers, Slack, VS Code**, and onboarding never shows the recorder. A new user's first ⌘1 may just switch a tab. | `ShortcutConfig.swift` defaults | Show the recorder on the Done step; consider ⌃⌥ defaults for new installs (existing installs keep theirs). | S–M |
| O9 / E8 | **No what's-new, no update check.** The DMG build has no Sparkle or version check; README advertises automatic updates only for the App Store. Direct-download users are pinned to whatever they installed — including for E1/E2 above. | grep `Sparkle`, `checkForUpdate`: none | A "What's new in x.y" card on About gated on last-seen version; for the non-App-Store build, a check against the GitHub releases API with a "Download" link. Sparkle proper is a second step. | M |
| O10 / O11 | **Settings depth**: 9 tabs, 54 sections, 5–6 parallel credential concepts (provider keys, OpenRouter OAuth, custom OpenAI endpoint, self-hosted STT endpoint, local LLM server, in-process MLX). Rarely used rows (window behaviour, popup position/duration, recording safeguards, raw-response dump, temperature, thinking effort) sit above the fold in tabs a new user opens looking for a key field. | `SettingsView.swift:82-98`; `GeneralSettingsTab.swift:81`; `SpeechToTextSettingsTab.swift:278-294` | One collapsed "Advanced" `DisclosureGroup` per tab; everything past the first provider key goes behind it. Reversible, no data-model change. | M |
| O12 | **Offline Mode vs. offline models vs. local servers are three overlapping ideas in three tabs** and the switch's own copy sends the user to a third place. | `PrivacyPermissionsTab.swift:53`, `:79` | Surface the model-download row inline on the Privacy tab when Offline Mode is on. | S |

Falsifier for Tier 2 as a whole: the **Share Usage Report** already counts dictations per
window; a fresh-install dogfood (delete the container, run onboarding offline) reaches a pasted
transcript without opening Settings.

---

## Tier 3 — Offline story completeness

The App Store listing and README lead with "runs fully offline". The audit found the transcription
half solid (recording kept while the model loads, no silent offline→cloud swap, URL-protocol guard
unit-tested) and the rest of the mode uneven.

| ID | Finding | Where | Fix | Effort |
| --- | --- | --- | --- | --- |
| F6 | **Chat is not reconciled or filtered for Offline Mode.** `isSelectableUnderOfflineMode` is applied only to Dictate Prompt models; the reconciler touches only the two transcription keys and `selectedPromptModel`. With Offline Mode on, the Chat picker lists Gemini/GPT/Grok, the selection stays Gemini, and every message dies at the URL guard. | `SettingsConfiguration.swift:663` vs `:678-688`; `ModelSelectionReconciler.swift:86-118` | Filter `chatModels` the same way; reconcile the chat selection onto MLX. | S–M |
| C14 | **MLX chat accepts tools and drops them with a log line.** Gmail/Trello/workspace tools are still declared, so on MLX `/folder` + "read my notes" fails as a plausible hallucination. `generateStructured` throws. | `MLXChatProvider.swift:22-27`, `:90` | Do not declare tools for `.localMLX`; say so once per session in-chat. | S |
| F7 | **Read Aloud in Offline Mode fails with advice for a different feature** ("Pick an on-device Whisper model for dictation"). None of the nine `OfflineMode.isEnabled` call sites is on the TTS path. | `MenuBarController.swift:2784-2787`; `OfflineMode.swift:29-34` | Pre-check at the entry point with a Read-Aloud-specific message — or ship F8 and make it work. | S |
| F8 | **No local TTS.** `AVSpeechSynthesizer` is used nowhere; macOS ships free on-device neural voices. Wiring one as the Offline-Mode Read Aloud fallback turns a "stops working" bullet into a working feature and closes the last hard gap in the offline story. | grep `AVSpeechSynthesizer`: none | Add an `.system` TTS provider backed by `AVSpeechSynthesizer` with the voice picker from `AVSpeechSynthesisVoice.speechVoices()`; make it the automatic choice under Offline Mode. | M |
| F9 | **Turning Offline Mode off never restores prior selections.** No snapshot is taken; the user who tries the switch stays on Whisper Turbo + Qwen 4B without being told. | `ModelSelectionReconciler.swift:33`, `:51`, `:182` | Persist pre-offline selections; restore on disable. | S |
| F11 | **`MLX.GPU.set(cacheLimit:)` is still unset** — the plan's own last open item and its single measured weakness (prefill regresses several-fold under memory pressure). | `plans/active/local-llm-mlx.md` last line; grep `cacheLimit`: none | Set it at loader init. Re-run `LocalLLMBenchmarkTests` under pressure. | S |
| F10 | **`MLXPromptCache` grows without bound** — one KV snapshot per distinct system prompt, never evicted; chat prompts vary per session and workspace. | `MLXPromptCache.swift:43`, `:73-77` | 1–2 entry LRU; drop on memory pressure. | S |
| F12 | **Nothing gates MLX on Apple Silicon or RAM.** The 8B model (4.5 GB) is offered unconditionally, including on an 8 GB Mac already holding Whisper Turbo. | `LocalLLMModelManager.swift:39`, `:60` | Gate 8B behind `ProcessInfo.physicalMemory`; hide MLX on non-arm64. | S |
| F13 | **Neither local model is ever unloaded.** Offline Mode with MLX keeps ≈1.6 GB + ≈2.3 GB + KV snapshots resident for the app's lifetime. | `LocalSpeechService.swift:90`; `LocalLLMModelManager.swift:380` | `DispatchSource.makeMemoryPressureSource` + idle unload after N minutes. | M |
| F14 | **No VAD for Whisper; silence protection is post-hoc.** Classic silence hallucinations ("Thank you.") are caught only if the plausibility heuristic recognises them. | `LocalSpeechService.swift:217-234`; `TextProcessingUtility.swift:286`, `:396-429` | Reuse the existing peak-power gate before invoking Whisper; evaluate WhisperKit's VAD chunking. Ties into gap #8 (the gate becomes measurable first). | M |
| E5 | **Privacy wording overstates the network block for model downloads.** `WhisperKit.download` uses its own `URLSession`, never touched by `OfflineModeURLProtocol` — the app will still reach huggingface.co in Offline Mode. Defensible (the README already carves it out), but `privacy.md` says "every request". | `ModelManager.swift:329`; `privacy.md` | Align the wording; or pass a guarded session if WhisperKit's `HubApi` allows it. | S |
| F15 | **Parakeet-class model is the remaining offline latency gap.** Slice 4 (Whisper on `DictateStreamingSession`) shipped 2026-09-02. Stage timings on real recordings (2026-09-03, M1 Pro, Turbo on GPU) showed Whisper's ~3 s floor is architectural: the 30 s-padded encoder is ½–⅔ of every call (a 2 s tail still pays 5–6 s encode), so shrinking chunks cannot reach Wispr-class ≤700 ms. Wispr Flow is cloud-only (small server ASR + Llama cleanup at Baseten). Remaining: Parakeet TDT 0.6B v3 via FluidAudio (encoder ~20 ms / 15 s window, 1 min audio ~0.5 s on M4 Pro, German FLEURS WER 5.9 %); open point is no `promptTokens` glossary (CTC vocab boost exists, untested on osteopathy terms). Cheaper Whisper-only levers, unmeasured: ANE encoder with `turbo_632MB`, serialise overlapping chunk decodes, shorten the glossary. See `plans/active/streaming-dictate.md` "Where the fixed cost per call goes". Instrumentation (`SPEED: LOCAL-SPEECH timings …`, test `realRecordingBreakdown`) is on `main`. | `LocalSpeechService.swift` `transcribe`; FluidAudio not in the tree | Parakeet via FluidAudio as a new local ASR path; keep Whisper as fallback. | L |

---

## Tier 4 — Chat quality and safety

| ID | Finding | Where | Fix | Effort |
| --- | --- | --- | --- | --- |
| C4 | **Every mutating tool executes without confirmation, and `open_url` closes an exfiltration loop.** Calendar/Tasks create and delete, Trello create/move/update/archive, workspace write/append/edit, and `open_url` (scheme-checked, then opened) run on the model's say-so; the only guardrail is prose in the tool descriptions. `gmail_read` pulls untrusted third-party text into the same context. | `ChatTools.swift:312-526`, `:624-701`, `:892-936`, `:1071-1080`, `:1342` | Per-turn approval sheet for write tools — at minimum `open_url` and the destructive Trello/Calendar ones — the way workspace writes already gate on `WorkspaceWriteAccess.isEnabled`. | M |
| C3 | **OpenAI, custom-endpoint, local and MLX providers silently discard PDF/document attachments.** `hasMedia` admits only `image/*` and `audio/*`; the text-only branch sends the turn as if nothing were attached. Grok and Anthropic reject with a message. | `LLMChatProvider.swift:755-763` | Give the four providers the same `validateAttachments` guard. | S |
| C1 | **The loop guard re-scans the whole reply on every stream delta, on the main actor** — sentence split twice plus an n-gram scan up to ~3 M comparisons per token on a long reply. The only unbounded per-token work left after the hang fixes. | `ChatView.swift:939-962`; `ChatStreamLoopGuard.swift:46`, `:75`, `:155` | Scan only the last few KB, only every N deltas; cache the sentence split. | S–M |
| C9 | **Attachment size limits are enforced in one of two paths, and silently.** Drag-drop skips files >20 MB with a bare `continue`; `/attach` has no check and persists the base64 into the sessions JSON. | `ChatComposerTextView.swift:669`; `ChatView.swift:601` | One shared check with an error banner. | S |
| C11 | **`/pin` and `/unpin` give no feedback**, and `/pin` is a toggle. | `ChatView.swift:669-681` | `showNotice(...)` like `/think` and `/x`. | S |
| I5 | **Dictate Prompt presets** (ledger I5, reinforced in run 5): one-tap Correct / Format / Rephrase so short command verbs are not voice-dictated through the STT that garbles them. | ledger | As proposed. | M |
| C12 / C13 | **Search rebuilds the whole corpus per query on the main actor; every save normalises every session.** Bounded today (50 × 400), noted for when limits rise. | `ChatSearch.swift:37-77`; `ChatSessionStore.swift:293-340` | Per-session haystack cached by `lastUpdated`; normalise only changed sessions. | M |

---

## Tier 5 — Engineering health that protects releases

| ID | Finding | Where | Fix | Effort |
| --- | --- | --- | --- | --- |
| E3 / E9 | **No CI runs tests; the release workflow never runs them either.** The only workflow is tag-triggered; `create-release.sh --skip-tests --allow-dirty` is what `/release` passes. Most tests are live-network and skip without `.env`, so a naive CI job would be mostly silent. | `.github/workflows/release.yml:3-6`; `scripts/run-tests.sh:16-26`; `scripts/create-release.sh:32-34` | `ci.yml` on `pull_request` running a hermetic subset; tag live tests so offline runs are meaningful; make the hermetic subset a required job before the archive step in `release.yml`. | M |
| E4 | **Zero unit tests on the core paths**: `AppState`, `MenuBarController`, `ChunkedDictateRecorder`, `ClipboardManager` (auto-paste), `ContextDerivation`, `ModelSelectionReconciler`, `ContextLogger`; `OfflineModeURLProtocol` itself is untested. The 4,200 test lines all sit on leaf helpers. Three Tier 0/1 bugs (D1, D2, D11) live exactly in this untested layer. | `WhisperShortcutTests/` | Start where it is cheap and pure: `ModelSelectionReconciler`, `ClipboardManager` snapshot/restore, `validateSpeechText`, then an `AppState` transition table. Each Tier 1 fix lands with its test. | M–L (sliced) |
| E6 | **Keychain items are not `…ThisDeviceOnly`**, and accessibility is set only on the `add` branch, so pre-existing items are never repaired. | `KeychainManager.swift:151-156` | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, included in the update attributes. | S |
| E7 | **No crash reporting; hang reports never leave the machine.** The watchdog's Mach-level capture is good engineering but write-only local evidence a user must be talked through retrieving. | `MainThreadWatchdog.swift:199` | "Reveal hang reports" in Settings → About plus attach-to-issue in the feedback flow; evaluate MetricKit. | S–M |
| E10 / E11 | **Package pin hygiene**: `mlx-swift-lm` `upToNextMajor` vs `swift-transformers` exact-pinned (two packages that must agree on tokenizer behaviour); HotKey and WhisperKit referenced twice in the project file (once per target), so a bump can diverge. | `project.pbxproj:673-717` | Same strictness for both; one reference per package. | S |

---

## Suggested sequencing

1. **Release A (this week):** all of Tier 0. One PR, one release, release notes lead with "Stop now really stops" and "Retry works again".
2. **Release B:** Tier 1a + 1b (D3, D4/I7, D6, D7, D11–D14, gap #8). D3 and D4 are the customer-facing stall fixes the growth ledger explicitly keeps; gap #8 is the instrumentation that ranks above features by the register's own rule. Each row lands with its unit test (E4 slices).
3. **Release C:** Tier 2 offline-first onboarding (O2, F2, F4, O4, O6, O8, O7, O13) — all S. Then O3 "Try it" and O9 update check as their own PRs.
4. **Release D:** Tier 3 F6/C14/F7/F9/F11/F10/F12 (all S) in one pass; F8 local TTS as its own feature PR — it is the one row here that produces a marketable line ("Read Aloud now works offline").
5. **Then:** Tier 1c latency, Tier 4 C4/C3/C1, Tier 5 CI. F15 slice 4 (Whisper streaming) shipped 2026-09-02; the 2026-09-03 timings closed the "just shrink the tail" path. Remaining F15 is Parakeet-class, still L, still later — but it is now the only measured path to Wispr-class offline latency.

## Candidates for `plans/implementer-queue.md`

Rows with a measurable falsifier and a contained blast radius, in order: **D1**, **D2**, **gap #8**
(already row 2, `HOLD`), **D4/I7**, **D3**, **O1**, **F9**, **F11**. Everything in Tier 2 that
touches onboarding copy or layout should stay interactive — it needs a human to look at it.

## Things the audits checked and cleared (do not re-flag)

- Stale-result guards and `processedAudioURLs` dedup across both dictation pipelines; the cancelled-recording recovery menu; the silent-recording info popup; credential pre-checks before recording on all three entry points; the mic-denied popup with its Settings jump.
- `ChunkedDictateRecorder` rotation ordering and off-main `record()`/`stop()` (ledger I1); `DictateStreamingSession` fallback semantics; `ConnectionPrewarmer` at all four start sites.
- Offline Mode's `URLProtocol` guard on every app-built session with a unit-tested, fail-closed host rule; recording kept while a Whisper model loads; no silent offline→cloud swap; ANE/GPU choice documented.
- Workspace file tools: symlink-resolved containment, read caps, binary detection, write-off-by-default with backups; Gmail is read-only; tool errors return to the model instead of killing the turn; 16-round tool loop with honest exhaustion copy; atomic, debounced session writes with flush on terminate.
- No secrets in logs; loopback listener bound to `127.0.0.1`; minimal entitlements; notarisation verified in `release.yml`; hardened runtime on all configs; no `TODO`/`as!`/`@unchecked Sendable`; the four `try!` are literal regexes.
- English-only UI (the one exception is C10); actionable missing-credential copy; App Store gates consistent; onboarding resume across a permission-triggered relaunch; the Screen Recording "Quit & Reopen" affordance.

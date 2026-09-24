# Refactor Ledger

Running record for `/review-refactors`. Each run reads this **before** triaging and updates it at
the end, so repeated runs build on each other instead of re-deriving the same findings.

Long-lived by design: unlike the plans described in `plans/README.md`, this file is not deleted when
a piece of work finishes — entries change status instead. IDs are stable and never reused.

Status values: `applied` · `deferred` · `rejected` · `superseded`.

## Findings

| ID  | Finding                                                                    | Blast radius | Status   | Run | Notes                                                                  |
| --- | -------------------------------------------------------------------------- | ------------ | -------- | --- | ---------------------------------------------------------------------- |
| R1  | Live-meeting session state has no owner — 17 `liveMeeting*` flags on `MenuBarController` | hot path     | applied  | 1   | `44a83e1` → `LiveMeetingSession.swift`; controller 3043 → 2530 lines    |
| R2  | Chat tool dispatch duplicated as an if/else ladder outside `ChatToolRegistry` | cross-file   | applied  | 1   | `execute(name:args:context:)` + `ChatToolContext`; one dispatch point   |
| R3  | `ChatViewModel` is 9 responsibilities in 2,374 lines                       | cross-file   | **in progress** | 1 | Slice 1 applied run 5 → `ChatSearch.swift` (search + ranking + snippeting, 148 lines out; `ChatSearchResult` is now top-level and `ChatSidebar` refers to it directly). Search earned a *type*, not an extension, because it needs nothing from the view model but the store — and that made it testable for the first time (8 tests). **The constraint the run-1 note missed:** `store` and most of the view model's state are `private`, which is file-scoped in Swift, so the remaining regions **cannot** simply move to an `extension ChatViewModel` in another file. Each one has to earn an owner (the R1/R17 shape) or take its dependencies as parameters. Remaining and measured at run 5: Archive/Restore/Delete 293, Meeting notes + editing 257, Workspace folders 185, Local-model slash commands 131, Tab navigation 59, Scroll 28. `ChatView.swift` 5,728 → 5,189 across run 5 |
| R4  | `performTranscription` / `performPrompting` are one envelope copied twice   | hot path     | applied  | 1   | `AudioJobSpec` + `runAudioJob`; Voice Feedback shares `cancelAudioJob`  |
| R5  | Dictate Prompt hand-rolls an OpenAI client that `OpenAIChatProvider` already is | hot path | applied | 1 | Working tree run 5 → `DictatePromptEnvelope` + `buildPromptEnvelope` in `SpeechService`. **Not** the run-1 target shape: building one Gemini-shaped `contents` and converting was rejected on measurement, because the providers genuinely disagree about audio (Gemini falls back to the Files API >20 MB and uploads AAC; OpenAI can only inline wav/mp3 and must reject oversized input; local sends none). What *is* identical is every other decision — screenshot on/off, the two screenshot label strings (written twice verbatim), the capture-failed guard, the model-can't-take-images rejection, the clipboard header (written **three** times), and the history flattening. Those now happen once and each provider renders them. Audio stays per provider on purpose |
| R6  | Four independent retry/backoff policies                                    | cross-file   | applied  | 1   | Working tree run 5 → `RetryBackoff.swift`. Re-measured at run 5 it is **4** loops (`GeminiAPIClient.performRequest`, its stream, `ChunkRetryPolicy`, `SpeechService.performWithRetryOn429`). Their *control flow* legitimately differs and was left alone; what they shared is the delay math and the retryable/permanent judgement. The finding with teeth: "a rate/quota error with no `retryAfter` is a permanent spend cap — don't retry" existed in **three different spellings** and was **missing entirely** from `performWithRetryOn429`, so a capped OpenAI key burned a doomed retry + backoff on every Dictate Prompt. Now one rule, plus an `insufficient_quota` body check for the raw-HTTP loop that has no `TranscriptionError` yet. 9 tests, mutation-proven. Still open and unchanged: OpenAI/Grok/Anthropic/Local chat streams have **no** retry at all — a behavior change, not this refactor |
| R7  | Provider clone leftovers — `instructions(from:)` ×2, tool-decl encoding ×5  | self-contained | applied | 1   | `cec1b0d`; `GeminiSystemInstruction` + `LLMToolDeclaration` encoders    |
| R8  | Per-enum UserDefaults loader boilerplate in `SettingsConfiguration`         | self-contained | superseded | 1 | Absorbed into R11's slot table — the per-enum loaders survive, the table records which setting uses which |
| R11 | `SettingsViewModel` load/save was a hand-maintained parallel list          | cross-file   | applied  | 2   | `120c2c1` → `SettingsSlot`; 26 settings declared once; round-trip test proven to fail on injected key drift |
| R12 | `KeychainManager` cloned 7 provider save/get/delete triples               | hot path     | applied  | 2   | `8d31dd0` → `KeychainCredential`; 467 → 264 lines, 38 call sites       |
| R13 | Four API-key settings sections were 89-line clones                        | self-contained | applied | 2   | `8d31dd0` → `APIKeyEntrySection` + descriptor on `APIKeyProvider`      |
| R14 | Three model pickers each redeclared the same tile grid                    | self-contained | applied | 2   | `0e10d37` → `ModelGrid` + `ModelGroupHeader`                           |
| R15 | `ChunkTTSService` and `ChunkTranscriptionService` are the same skeleton    | hot path     | applied  | 3   | working tree → `ChunkPipelineSupport.swift`: `ChunkRetryPolicy` (the per-chunk retry loop, previously line-for-line in both) + generic `ChunkResultAccumulator`. 829 → 669 lines across the two services. Drain loops deliberately **not** merged — see the note below |
| R16 | Four message-action buttons re-declared the same 28×28 hover chrome       | self-contained | applied | 3   | working tree → `MessageActionButton.swift`; `ChatView` −66 lines. `isActive` covers Read Aloud's playing state |
| R17 | Progressive TTS playback has no owner (the R1 shape, in the same file)     | hot path     | applied  | 3   | working tree → `TTSPlaybackSession.swift`: 4 counters/flags + the AVAudioEngine trio + 7 functions out of `MenuBarController` (2,912 → 2,832). Owner keeps `appState` and `ttsDidStop` via 3 callbacks |
| R18 | OpenAI Dictate Prompt had no screenshot-capture guard (found measuring R5) | hot path     | applied  | 3   | Behavior fix, not a refactor: in screenshot-selection mode (App Store) a failed capture used to send the "edit the highlighted region" prompt with no image. Gemini guarded this, OpenAI did not; message now shared |
| R19 | ~~OpenAI prompt path doesn't AAC-transcode its audio~~                    | —            | rejected | 3   | **Not a drift.** OpenAI's `input_audio.format` accepts only `wav`/`mp3` (`openAIAudioFormat` returns exactly those), so AAC cannot go through that endpoint at all. The upload really is larger than Gemini's; making it smaller means adding mp3 encoding — a feature, not a fix. Don't re-flag |
| R21 | `TranscriptionModel` collapsed two axes — model *and* provider — into one flat enum | cross-file | applied | 4 | Working tree → `TranscriptionProvider.swift`. The axis already existed, denormalized: `isGemini`/`isOpenAI`/`isXAI`/`isOffline` plus `==` checks against the two non-model cases, re-derived in `hasRequiredCredential`, `credentialRequiredTitle` and `apiKeyRequiredMessage` (3 copies that had to agree, nothing making them). Now one derived `var provider`; the four booleans are one-liners over it. **Persistence deliberately untouched** — `TranscriptionModel` still owns the stored raw value, so no settings migration. See R22/R23 for what is left |
| R22 | Dictate grid grouped by cloud/offline, hiding the distinction that actually confused users | self-contained | applied | 4 | Working tree → `ModelSelectionView` groups by `TranscriptionProvider.Group` (direct / routed / offline) and routed tiles show what they route to (`OpenRouter → Gemini 3.5 Flash Lite`). Reported symptom: "Gemini 3.5 Flash-Lite is in the grid *and* in OpenRouter's picker — which one am I choosing?" Nothing said one bills the Google key and the other the OpenRouter balance |
| R23 | Provider capabilities still live as ~25 exhaustive switches on the model enum | cross-file | applied (reduced) | 4 | **Re-measured run 5 and the run-4 note was wrong** — `TranscriptionModel` has **10** exhaustive switches, not ~25, and only `apiEndpoint` was provider-shaped. `costLevel` is per-model (OpenAI runs Low/Medium/Low; Gemini Low except Pro), `geminiTranscriptionGenerationConfig` is per-tier *by design* (Pro rejects `thinkingLevel: minimal`), and `displayName`/`description`/`isRecommended`/`offlineModelType`/`asymmetryClass` are all genuinely per-model. Working tree → `TranscriptionProvider.fixedEndpoint` + one Gemini URL template; the five spelled-out Gemini URLs are gone. Nothing else here is worth moving — **don't re-open this** |
| R24 | Splitting persisted selection into `(provider, model)`                     | cross-file   | deferred | 4   | The expensive part of the two-axis refactor and the least valuable — needs a UserDefaults migration off the flat raw value. Explicitly **not** scheduled: R21–R23 deliver the structure and the UI without it. Only revisit if a provider appears whose model list cannot be expressed as enum cases *and* the R21 escape hatch stops working. Note two such providers already exist (`openRouterTranscription`, `selfHostedTranscription`) and are handled fine by a side-channel slug/URL |
| R20 | OpenAI prompt path maps history to messages by hand                       | self-contained | applied | 3 | Came free with R5 exactly as predicted. History is flattened once into `[PromptHistoryTurn]` (a neutral `isUser` + `text` pair) and each provider renders its own role names — `assistant`/`user` for OpenAI, `model`/`user` for Gemini-shaped local `contents`. The `OpenAIChatCompletionsConverter` bridge was never needed |
| R25 | The reply-markdown classifier was written twice and had already drifted    | self-contained | applied  | 5   | Working tree → `ReplyBlockBuilder.swift` (489 lines out of `ChatView.swift`, 5,728 → 5,297). `buildReplyBlocks` / `buildContentOnlyBlocks` were one 8-branch paragraph classifier copied twice, once with citation threading. The copies had already shipped one bug (the old code's own comment records the grounded path dumping raw base64 for generated images) and were still shipping another: `CodeBlockExtractor` was only ever called on the ungrounded path, so **any reply that came back with search grounding rendered ``` fences as literal text**. Now one `classify`, one ladder, plus `OffsetMap` so extraction is safe on the grounded path (supports index the original content; extraction shortens it). Extracted to its own file *because* the fix was untestable inside a private view — that untestability is how the copies drifted. **Behaviour change, intended**: grounded replies gain code blocks |
| R26 | "Does the user have a credential for this provider?" was answered 4 ways   | hot path     | applied  | 5   | Working tree → `ChatModelProvider.credentialRequirement`, the app's only per-provider credential switch; `hasCredential` / `credentialRequiredMessage` / `requiresUserSuppliedCredential` all derive from it. Collapsed: `ProviderCredentials.verifyConfigured` (6-case switch), `ChatViewModel.validateCredential` (the same 6 cases, different wording, only one of which named the Settings tab), and the four-term `hasAnyKey` OR-chain written verbatim in **both** `MenuBarController` and `FullApp`. User picked "unify check *and* wording" → chat error strings now match `ProviderCredentials`' (they name Settings → General). Two deliberate behaviour changes: `verifyConfigured(.gemini)` used to pass through silently (its "Gemini carries no Keychain key" comment was stale) and now fails early with a clear message; `validateCredential` is no longer `async` |
| R29 | The release pipeline has no executable seam — every mechanical step is prose the agent re-runs by hand | hot path | deferred | 6 | `/release` steps 3/5/6/12–15 and `/submit-appstore` steps 1–5/8 are pure mechanics (read plist, bump both keys, resolve remote URL, detect branch, tag, push; archive, export, pkgutil-check, upload) with no script behind them. The repo's own rule — `.cursor/CONTEXT-CONVENTIONS.md` #5, "Reference scripts, not steps" — is violated most by the one path that ships to users. Proposal: `scripts/release/{bump-version,cut-tag,appstore-package,appstore-upload}.sh` own the mechanics; the commands keep only judgment (baseline, notes, ask-before-submit). Subsumes R30 and R34 |
| R30 | Two divergent implementations of the tag cut — and the flow bypasses the safer one | cross-file | applied | 6 | `scripts/create-release.sh` gates on a clean tree, checks the tag does not already exist, and rolls the local tag back if the push fails. `/release` steps 14–15 re-spell the same cut and have **none** of those three. Meanwhile `AGENTS.md:29`, `README.md:216`, the app-bundled `WhisperShortcut/Docs/README.md:216` and `.github/RELEASE_SETUP.md:157` all advertise the script as *the* way to release, while `release.md:63` explains why the flow refuses to call it — and mis-describes it ("only read-version → tag → push"; it also runs tests and gates on a clean tree). Fix: give the script a `--tag/--yes` non-interactive mode and have `/release` call it. **Applied run 6** (working tree): script gained `--tag/--yes/--skip-tests/--allow-dirty` plus a **new** check — the tag must match `Info.plist`, since `/submit-appstore` looks the build up by `v$VERSION`. `--allow-dirty` gates on the release files (`Info.plist`, `RELEASE_NOTES.md`) being committed rather than on a pristine tree, which is what `/release` actually needs. Proven in a scratch clone: happy path tags+pushes with unrelated dirty work present, a failed push deletes the local tag again, the release-file gate fires. **The elegance is that the 5 docs advertising the script needed no edit** — the script became what they already claimed it was |
| R31 | The "macOS ships a `.pkg`, never `asc publish appstore`" warning is written 4× | self-contained | applied | 6 | `release.md:88`, `submit-appstore.md:21–26`, `submit-appstore.md:142–143`, `app-store-connect/SKILL.md:242`. The signing-cert distinction (Apple Distribution + auto-provisioned 3rd Party Mac Developer Installer vs Developer-ID) is likewise in `release.md:88`, `submit-appstore.md:12`, `submit-appstore.md:130–136`, `app-store-connect/SKILL.md:253`. `/submit-appstore` is the only one that can make the mistake — it should own the fact once; `release.md` should shrink to a pointer. **Applied run 6**: one full explanation survives (`submit-appstore.md:21–26`), the other three are pointers. `submit-appstore.md`'s Signing notes now say in-band that this command is the single owner, so the next agent adds detail there instead of re-explaining it elsewhere |
| R32 | "Which version is live on the App Store?" is answered two ways, and they have already drifted | cross-file | applied | 6 | `release.md:26–35` says *query it, do not ask the user* and names `READY_FOR_SALE`; `submit-appstore.md:95–96` says "ask the user which version is live if unsure"; `app-store-connect/SKILL.md:158` names `READY_FOR_DISTRIBUTION`. **Checked against the live API in run 6: `READY_FOR_SALE` is correct, the skill is wrong.** Memory `pending-appstore-793` records this baseline having bitten before. Fix: one named "resolve the live App Store baseline" procedure in the `app-store-connect` skill; both commands link to it. **Applied run 6**: new `## Resolve the live App Store baseline` section owns the command and the state string; `release.md` and `submit-appstore.md` link to it; the wrong `READY_FOR_DISTRIBUTION` is corrected and kept as an explicit negation so it does not get re-introduced |
| R33 | The documented What's New step does not match how it is actually done | cross-file | applied | 6 | `submit-appstore.md:104–109` prescribes 10 hand-built `asc localizations update --whats-new "..."` calls against a prose-hardcoded locale list. On disk the real artifact is `.asc/whatsnew-<version>/<locale>.strings` — 6 versions present (7.78 … 7.95), each a full metadata dir (`description`, `keywords`, `marketingUrl`, `promotionalText`, `supportUrl`, `whatsNew`) applied via `asc metadata apply --dir`. Neither command nor the skill mentions the convention. Nor does anything say **who produces the 10 localized texts** — `/release` outputs English only, `/submit-appstore` demands localized. Evidence the gap bites: `whatsnew-7.95/en-US` has `supportUrl = whispershortcut.com/support`, `de-DE` has `github.com/…/issues`, and nothing in the flow would surface the disagreement. Locale list should come from `asc localizations supported-locales`, not prose. **Applied run 6 — and the run-6 report's mechanism was wrong, corrected while applying:** the `.strings` dirs are *not* `metadata apply --dir` input (that wants an `app-info/` + `version/<ver>/` JSON tree); they are `asc localizations download` / `upload --path <dir>` artifacts, a flat `<locale>.strings` layout. Step 7 now documents that round-trip, and the locale set comes from `asc localizations list --version` (10 configured) — **not** `supported-locales`, which returns the full 50-locale catalog with a `configured` flag and answers a different question. Two live-API verifications drove the wording: (1) `upload` rewrites all **six** fields per locale, not just `whatsNew`; (2) **`--dry-run` is not a diff** — it returns byte-identical output whether a field was edited or not, so the real guard is `diff -r` against a pristine download. The English→locale handoff is now named in both commands (`/release` outputs English only; translating is `/submit-appstore` step 7) |
| R34 | `/release` step 5's "increment by 1" is underspecified for a two-decimal version string | self-contained | deferred | 6 | `CFBundleShortVersionString` is `7.99`; "increment by 1" admits `8.00` (intended, per the tag list), `7.100` and `8.0`. The format is load-bearing — the `v$VERSION` tag and the `asc` version string both key off it. Has not bitten yet. Disappears if R29's bump script lands |
| R35 | Two model managers (`ModelManager` WhisperKit / `LocalLLMModelManager` MLX) were one skeleton, already drifted | hot path | applied | 7 | `a4d1379` → `ModelStore<Model: DownloadableModel>` (`ModelStore.swift`), both managers are now `final class … : ModelStore<…>` overriding only paths/required-files/`fetch`/`load`/`unload`/`deletionTarget`. All 22 call-site files unchanged (`static let shared` lives on the non-generic subclass — a typealias cannot carry it). Drift found and closed, all in the direction "MLX got the fix, Whisper didn't": Delete now cancels the running download first (MLX's own comment records the bug); `Task.checkCancellation()` after the fetch (Hub returns normally when cancelled mid-tree); one `@MainActor` isolation domain instead of per-method hops — Whisper used to clear `downloadTasks` from a detached `Task` in a `defer`, so a finished download could still be joined. The corrupt-download self-heal stays **Whisper-only** via `healsCorruptDownloadOnLoadFailure` (user's call). Disk reads (`resolveModelPath`, `isModelAvailable`, `getModelSize`) are `nonisolated` because `TranscriptionModel.hasRequiredCredential`, `SpeechErrorFormatter` and the `LocalSpeechService` actor call them synchronously — that seam is what kept the ripple at zero. Dead code removed: `verifyModelFiles` + `findMelSpectrogramFile` (55 lines, only called each other). 10 tests in `ModelStoreTests` (join-in-flight, cancel, delete-cancels-first, self-heal opt-in) |
| R36 | Two ~110-line model-row views + three download-handler copies | self-contained | applied | 7 | `a4d1379` → `ModelDownloadRow<M, Badge>` (`Settings/Components/`). `SpeechToTextSettingsTab.offlineModelRow` and `LocalLLMModelsSection.row` are each ~25 lines of badge content now. Drift closed: `getModelSize` only when shown (the MLX row's own perf comment — the Whisper row was enumerating gigabytes on every progress tick); the Whisper `refreshTrigger` + 0.5 s sleep hack is gone (the store's `@Published` writes already re-render the row, which is how the MLX row worked). `estimatedSizeLabel` became a `DownloadableModel` requirement so MLX's "≈2.5 GB" wins through the generic. `WhisperModelDownloadCard` (onboarding) is a different layout and was left alone |
| R37 | `prepareOfflineModelInBackground` / `prepareMLXModelInBackground` twins in `MenuBarController` | self-contained | applied | 7 | `a4d1379` → one generic `prepareModelInBackground(_ store:, _:, label:, reason:, downloadIfMissing:)`. Came free with R35 as predicted |
| R38 | The Gemini transcription request was built 3× (`transcribeWithGeminiInline`, `…FileURI`, `ChunkTranscriptionService`); only one copy had the recovery ladder | hot path | applied | 7 | `a4d1379` → `GeminiAPIClient.transcribe(audioURL:instruction:model:credential:audioDurationSeconds:glossaryTerms:mode:withRetry:timeoutInterval:) -> GeminiTranscriptionResult` (`GeminiTranscriptionCall.swift`): encode → request → perform → extract → both plausibility gates, once. `SpeechService` keeps the echo-retry + alternate-model ladder around one call (`discardedAsGlossaryEcho` on the result replaces the `afterLengthGate` bookkeeping); the chunk service passes `withRetry: false` + its timeout. The chunk copy's hard-coded fallback instruction was dead (`geminiTranscriptionInstruction` already substitutes the default). **Files-API branch deleted** (user's call): every `transcribe()` caller feeds the app's own recorder (24 kHz mono 16-bit = 48 KB/s → 20 MB ≈ 437 s) and chunking takes over at 45 s, so "≤45 s and >20 MB" cannot occur. `GeminiAPIClient.uploadFile` stays — Dictate Prompt still uses it. Live roundtrip suite run as the wire-level equivalence check |
| R39 | `ChunkProgressDelegate` in `MenuBarController` repeated set-status → guard-transition → icon → grid-popup 4× | self-contained | applied | 7 | `a4d1379` → `applyChunkStatus(_:at:popupSuffix:logIfSkipped:)` + `updateChunkPopup`; `chunkStarted`/`chunkCompleted`/`chunkFailed` are 3–8 lines each |

### Follow-ups that came out of applying the above

| ID  | Finding                                                              | Blast radius | Status  | Run | Notes                                                        |
| --- | -------------------------------------------------------------------- | ------------ | ------- | --- | ------------------------------------------------------------ |
| R9  | Dictate Prompt had no stale-result guard (found while applying R4)   | hot path     | applied | 1   | `77b5c96`; also collapsed 3 copies of the prompt cancel path |
| R10 | Voice Feedback never cleared `chunkStatuses` (found while applying R4) | hot path     | applied | 1   | `77b5c96`; clearing is now unconditional, flag deleted       |
| R27 | ⚠️ "add an API key" warning ignored routed transcription (found applying R26) | self-contained | applied | 5 | The menu-bar warning tested `!hasAnyKey && !hasOfflineTranscriptionModel`, so a user whose only setup was OpenRouter or a self-hosted endpoint was told to add a key they did not need. Now tests `canTranscribe`, which was already computed 6 lines above. Behaviour fix, not a refactor |
| R28 | OpenAI Dictate Prompt retried a spend-cap 429 (found applying R6)          | hot path     | applied  | 5   | `performWithRetryOn429` retried **any** 429, including `insufficient_quota` — a billing block that never clears. The user waited out a backoff before seeing an error that was never going to change. The other three retry loops all had this rule. Behaviour fix, shipped as part of R6 |
| R40 | `ChatViewModel` request assembly + error mapping hide under the "Archive / Restore / Delete" MARK (R3 slice 2) | self-contained | applied | 8 | `4dbf4ea` — ~190 lines (`buildContents` 2808, `youTubeLinksToAttach`, `logImagePayloadMeasurement`, `friendlyError` 2943, `chatProviderDisplayName`) need only `messages`, `session.id`, `store.session(by:)`, `openChatModel` → `ChatRequestBuilder` + pure `ChatErrorFormatter`; testable for the first time (the `ChatSearch` route) |
| R41 | "Mutate store → resync view" written 8× in `ChatViewModel`; dead `pinSession`/`unpinSession` (R3 slice 3) | self-contained | applied | 8 | `08f4fc3` — `archiveOlder*` ×4 + `archiveSession` + `closeTab` + `closeOtherTabs`/`closeTabsToTheRight` (8 lines verbatim) → `syncAfterStoreMutation()`; "resolve target session" 8-line block ×3 (1649/1756/1795) → `withSession(id:)`; `pinSession`/`unpinSession` have **zero callers repo-wide** → delete |
| R42 | Meeting-editing guard duplicated; transcript path built three ways (R3 slice 4) | self-contained | applied | 8 | `792d1e5` + `8361ef1` (compile fix: `Result`'s failure type must be an `Error`) — Ended-meeting guard 2570–2577 ≡ 2618–2625; `MeetingListService.transcriptURL(forStem:)` already exists (used at 2498) while 2318 and 2559 hand-build it. Memory tools (2660–2692) use **no** VM state and scroll anchors need only `store` → both leave the view model |
| R43 | Session-list state is pushed by hand instead of derived from the store | cross-file | deferred | 8 | `refreshRecentSessions()` has 20 call sites; 6 slash-command sites mutate `session.x` and rely on the *next* `appendModelMessage` to persist (comments at 1991/2028 admit it). Target: a `didChange` publisher on `ChatSessionStore.saveSessionsFile` + one sink. **Deliberately not applied**: `save` frequency during streaming must be measured first — a per-token refresh re-sorts 50 sessions on the main thread, and this file's oddities all cite hang captures |
| R44 | `performWithRetryOn429` / `performStreamingWithRetryOn429` differ only in `data` vs `bytes` | hot path | applied | 8 | `746c8cf` — `SpeechService` 2424 / 1875: the 429 branch is byte-identical. Collapses to one loop with `onPartial: nil` = non-streaming. Narrows `RetryBackoff.swift:6–12` ("four loops legitimately differ") for **this pair only** — same file, same producer shape |
| R45 | The Gemini SSE seam is written twice — stream open, non-2xx drain, stall watchdog | hot path | applied | 8 | `69f6f04` — `SpeechService:1686–1738` (TTS) vs `GeminiAPIClient:540–631` (chat), with watchdog constants in two places (`AppConstants.ttsStream*` vs `Constants.stream*`); PCM slice loops 1759 / 1890 both hand-roll `PCMStreamBatcher` |
| R46 | `GeminiAPIClient` hygiene: literals ×2–3, `uploadFile` bypasses `createRequest`, dead TTS branch | self-contained | applied | 8 | `925dbcd` — `safetySettings` ×2 (585, 983); `:generateContent` endpoint literal ×3; `uploadFile` rebuilds auth `createRequest` already does + repeats its request/check block (1081 ≡ 1123); YouTube 400/403 retry branches (800/817) differ in one note string; `mode == "TTS"` at 315 is **dead** (TTS moved to `streamingBytes`). The inline transient predicate at 831 vs `RetryBackoff.isTransientPreFirstToken` is **not** unified — they differ on `URLError`, so merging changes retry behaviour |
| R47 | Audio helpers defined N times: AAC-or-raw ×4, duration ×6 | hot path | applied | 8 | `4d8a48c` — AAC-or-raw identical 8 lines at `GeminiTranscriptionCall:47`, `SpeechService:1049/1373/2116`; `AudioChunker.getAudioDuration` byte-identical to `SpeechService:2546`, AVAudioFile formula inline ×4 more. MIME maps (`audio/mp3` vs `audio/mpeg`, OpenRouter's `m4a`) are per-provider vocabularies — left alone on purpose |
| R48 | `ContextDerivation`: five `switch focus` ladders + a prompt triple through 6 signatures, already drifted | self-contained | applied (a–c, e) | 8 | `1d56bee`. **(d) NOT applied** — `generateStructured` always emits a `thinkingConfig` for the Smart Improvement model (`.default` → `["thinkingLevel": "low"]`, `.minimal` clamped to `low` by `geminiRejectsMinimalThinking`), so the body could not be made byte-identical; the diff adds a `thinkingConfig` key for every `ThinkingLevel` (old 1351 bytes, new 1413–1416). The hand-built body stays. **Behaviour delta in (a):** `buildAnalysisUserMessage` used to re-read `SystemPromptsStore` untrimmed for `.chat` while sampling used the trimmed value; both now use the trimmed one, so a whitespace-only chat prompt now counts as empty. 816 re-reads `SystemPromptsStore` for `.chat` while 457 takes it as a parameter — the drift the threading invites. JSONL corpus decoded **twice per run** (222, 413); the Gemini path hand-builds what `GeminiAPIClient.generateStructured` already is (the R5 shape); `parseDate` allocates an `ISO8601DateFormatter` per call |
| R49 | `PopupNotificationWindow` encodes one kind as four independent `Bool`s | self-contained | applied | 8 | `c57f0a1` — `isError/isInfo/isCancelled/isProcessing` on a 13-parameter init, resolved by ladders in `setupIcon` and `startAutoHideTimer`; four action-button factories ×10 lines; four constraint blocks re-encoding a button order that is **also** encoded in `init`, `addSubview`, `hasButtons` and `mouseDown`; five `show*` tails verbatim; label config ×3 |
| R50 | Local layer: memory-pressure source ×3, idle-unload ×2, prewarm timing ×4, timeout logging ×4 | cross-file | applied | 8 | `2cd1204` — `MLXPromptCache:79` ≡ `LocalSpeechService:228` ≡ `LocalLLMModelManager:262`; `ConnectionPrewarmer` timing wrapper ×4; `LocalSpeechService` "model missing" sniff ×2 (second copy widened with `"load"` in `02feb4dd` — unify on the superset); `requestTimeout` catch + `logSignal(.requestTimedOut)` ×4 across 3 files |
| R51 | Six hand-written HTTP-status→`TranscriptionError` ladders; two Codable models of one Gemini wire shape | hot path | deferred | 8 | `GeminiAPIClient:1357`, `SpeechService:1187/2162/2370`, `LLMChatProvider:364/962`; `GeminiResponse` (`TranscriptionModels:690`) vs `GeminiChatResponse` (`:890`); three Gemini request struct families in one file. Touches every provider path at once and the mapped strings are user-visible — **recorded, not scheduled** |

## Swept areas

| Area                                             | Last swept | At commit | Notes                                                             |
| ------------------------------------------------ | ---------- | --------- | ----------------------------------------------------------------- |
| `MenuBarController.swift`                        | run 1      | `77b5c96` | R1, R4, R9, R10 applied. Still 2,530 lines — TTS playback, menu construction and clipboard handling remain unexamined |
| Chat providers (`*ChatProvider`, `LLMChatProvider`) | run 1      | `77b5c96` | R7 applied; layer already in good shape                           |
| `ChatTools.swift` + `ChatViewModel` tool dispatch | run 1      | `77b5c96` | R2 applied; rest of `ChatView.swift` only skimmed                 |
| `SpeechService.swift`                            | run 1      | `77b5c96` | Read for R5/R6; nothing applied yet                               |
| `Settings/` (all 45 files, 7,631 lines)          | run 2      | `b5e98f7` | R11, R13, R14 all applied. Tab views are thin composition — healthy, don't re-flag |
| `KeychainManager.swift` + `APIKeyProvider`       | run 2      | `b5e98f7` | R12 applied; storage now keyed by `KeychainCredential`            |
| `ChunkTTSService` + `ChunkTranscriptionService`  | run 3      | `d2e7e31` | Read in full. R15 applied. What is left in them is genuinely different — don't chase the rest |
| `MenuBarController` TTS-playback region          | run 3      | `d2e7e31` | R17 applied. Still unexamined in that file: menu construction, clipboard/paste handling, the `ChunkProgressDelegate` conformance (~200 lines) |
| `SpeechService` Dictate Prompt paths (583–1088)  | run 3      | `d2e7e31` | Read for R5. R18 applied, R19 rejected, R20 deferred. The prompt *tail* (`recordPromptTurn`, system-prompt builder) is already shared — only the envelope is not |
| `ChatView` message-action buttons (5193–5366)    | run 3      | `d2e7e31` | R16 applied. The rest of the rendering half is still unread |
| `ChatView.swift` rendering half (3182–5728)      | run 5      | `c2b974d` | R25 applied. Message list, streaming detachment, scroll persistence and `SelectableProseText` were read in full and are **earned complexity** — every oddity cites a hang capture. Don't "simplify" them |
| Credential layer (`ProviderCredentials`, `ChatModelProvider`, `TranscriptionProvider`) | run 5 | `c2b974d` | R26, R27 applied. One switch per axis now; the pattern to copy, not to re-derive |
| `TranscriptionModels.swift` switches             | run 5      | `c2b974d` | R23 closed out. The remaining 9 switches are genuinely per-model — measured, not assumed |
| `SpeechService` Dictate Prompt envelope (all 3 providers) | run 5 | `c2b974d` | R5, R20 applied. The **audio** half of each path is deliberately still three implementations — see R5's note |
| The four retry loops                             | run 5      | `c2b974d` | R6, R28 applied. Control flow left per-loop on purpose; only policy is shared |
| `ChatViewModel` Search region                    | run 5      | `c2b974d` | R3 slice 1 → `ChatSearch.swift`. The rest of `ChatViewModel` is still unswept |
| Release + App Store submit tooling (`/release`, `/submit-appstore`, `create-release.sh`, `release.yml`, `RELEASE_SETUP.md`, parent `app-store-connect` skill) | run 6 | `b60bfdc` | ~1,065 lines across 6 files governing one pipeline, read in full. R29–R34 all open. `release.yml` itself is fine — linear, single-purpose, no duplication with the commands |
| Offline/local model layer (`ModelManager`, `LocalLLMModelManager`, `ModelStore`, their 3 Settings/onboarding views, all 6 `ensureReady` call sites) | run 7 | `c6ffa80` | R35–R37 applied. `MLXModelLoader`, `MLXPromptCache`, `OfflineMode`, `SystemTTSService`, `LocalSpeechService` only skimmed — still unswept |
| `SpeechService` Gemini transcription half (2247–2504) + `ChunkTranscriptionService` request block | run 7 | `c6ffa80` | R38 applied. The OpenAI-compatible trio (OpenAI / xAI / self-hosted) already shares `sendOpenAICompatibleTranscriptionRequest` and OpenRouter's separate shape is documented — healthy, don't re-flag. TTS synthesizers (1633–1722): OpenAI/xAI are ~14-line near-clones with no drift, deliberately not unified |
| `MenuBarController` `ChunkProgressDelegate` conformance (3042–3245) | run 7 | `c6ffa80` | R39 applied. Menu construction and clipboard/paste handling in that file are **still** unexamined |
| `ChatViewModel` request/error, session-management, meeting-edit, memory and scroll regions | run 8 | `7091b8c` | R40–R42 applied. `ChatView.swift` 5,631 → 5,402. Still inside the view model: send/queue (837–1505), the `// MARK: - Private` half, workspace-folder commands. The R3 constraint holds — each remaining region must earn an owner or take its deps as parameters |
| `SpeechService` retry + Gemini TTS stream, `GeminiAPIClient` stream half | run 8 | `7091b8c` | R44, R45 applied. `openSSEStream` + `StreamProgressClock.startWatchdog` + `PCMStreamBatcher.feed` are now the seam — copy them, don't re-derive. `streamingBytes(for:)` and `GeminiAPIClient.resourceTimeout` were pure forwarders and are gone |
| `GeminiAPIClient` non-streaming half + Files API | run 8 | `7091b8c` | R46 applied. The inline transient predicate (~831) is deliberately NOT `RetryBackoff.isTransientPreFirstToken` — they differ on `URLError`. `uploadFile` is live (Gemini Dictate Prompt >20 MB), not dead |
| Audio payload/duration helpers across 8 files | run 8 | `7091b8c` | R47 applied → `AudioTranscoder.payload`, `AudioDuration`. Per-provider MIME tables stay separate on purpose (Gemini `audio/aac` vs OpenRouter `m4a`); `AudioChunker.splitAudioStream` keeps its own read off the asset it already holds |
| `ContextDerivation.swift` (941 lines, read in full) | run 8 | `7091b8c` | R48 (a–c, e) applied; (d) blocked by `thinkingConfig` — see the finding row. `rawSystemPromptForFocus` (166 lines of per-focus prompt text) is genuinely per-case, left alone |
| `PopupNotificationWindow.swift` (1,240 lines, read in full) | run 8 | `7091b8c` | R49 applied → `PopupKind`, one button factory, one ordered `actionButtons`. Net −49 lines. `Constants.displayDuration` was already `SettingsDefaults.notificationDuration.rawValue`, so the fallback change is a no-op |
| Local model layer lifetime guards + `ConnectionPrewarmer` | run 8 | `7091b8c` | R50 applied → `ModelLifetimeGuards` (3 adopters), `timedWarmUp`, one missing-model predicate, one timeout signal. `warmOfflineWhisper` still bypasses `ensureReady` on purpose |

## Not yet swept

- The rest of the new offline/local layer: `LocalSpeechService` (637, +410 since run 6),
  `MLXModelLoader` (in `LocalLLMModelManager.swift`), `MLXPromptCache` (236), `OfflineMode` (180),
  `SystemTTSService` (192), `ConnectionPrewarmer` (+175). `warmOfflineWhisper` / `warmMLXModel` in
  the prewarmer look like the R37 shape but the Whisper one deliberately bypasses `ensureReady`
  (its comment explains the self-heal is too destructive for a speculative warm-up) — read before
  flagging.
- `ChatView.swift`'s **input area** (`ChatInputAreaView`, ~470 lines) — the one rendering region run 5
  did not open. Everything else in the rendering half is now read.
- `ChatViewModel` (R3) — run 8 took slices 2–4 (R40–R42). What is left: the send/queue half
  (837–1505) and the `// MARK: - Private` region. R43 (store-derived session lists) is the design
  question underneath it and is recorded as its own finding.
- `Settings/` again: **3,075 insertions across 42 files since run 2's sweep** at `b5e98f7`, so it is
  fair game under the Step 0b2 rule even though run 2 closed it out.
- `ChatView.swift`'s **input area** (`ChatInputAreaView`, ~470 lines) — still the one unread
  rendering region.
- `ChatTools.swift` (1,665) and `ChatToolRegistry` — never swept.
- `PopupNotificationWindow.swift` (1,223), `ContextDerivation.swift` (941)
- `Onboarding/` (`WelcomeSteps.swift` 1,056), `GeminiAPIClient.swift` stream body (~600 lines, read
  only down to line 440 in run 3), `SpeechService`'s TTS + transcription-provider half (~1,400 lines)

## Signals checked and cleared (don't re-flag without new evidence)

- `#if APP_STORE` is contained to 7 sites — not scattered.
- `Settings/Tabs/*` are thin composition of named section views, not scaffolding clones (run 2).
- `ConfigurableShortcutSlot` (`SettingsViewModel`) and `TTSProvider.voiceUserDefaultsKey` are
  already the table-driven pattern R11 wants — use them as the model, don't re-flag them.
- R6 grew from 4 retry policies to 5 (`ChunkTranscriptionService` added one), then dropped to 3 when
  R15 landed — re-measure every run, don't trust an older count.
- The two chunk services' **drain loops** were examined in run 3 and deliberately left as two: their
  producers differ (an `AsyncStream` of exported audio chunks vs an array of text chunks), TTS has a
  playback-order gate transcription has no use for, and the two call their progress delegate in
  opposite order (`chunkProgressUpdated` before vs after `chunkCompleted`). Forcing one skeleton onto
  that needs a hook per difference — the "abstraction that unifies nothing" the command warns about.
- `ChunkedTTSError` and `ChunkedTranscriptionError` have the same case shapes but different
  user-visible wording ("failed to synthesize" / "failed to transcribe", and only transcription has
  `partialSuccess`). Merging them changes error strings; left alone on purpose.
- `Settings/` is now swept end to end and everything found there is applied. The remaining backlog
  (R3, R5, R6) is all outside it — don't re-triage `Settings/` next run just because
  `SettingsConfiguration` still ranks high on churn and size.

## Working notes for the next run

- **Verifying UI changes**: `driver.sh shot "Settings…" <name>` works; switching Settings *tabs*
  does not — the sidebar is SwiftUI with no AX rows, and `click at {x,y}` via System Events does
  not land even after `activate`. R14 was verified by proving the extracted view bodies were
  byte-identical to the copies they replaced, which is the better check for a pure extraction
  anyway.
- **Committing around in-progress work**: when a sweep touches a file the user is already editing,
  stage only your hunks — copy the file aside, `git show HEAD:<file> >` it, re-apply just your
  edit, `git add`, restore. Verify with `git diff --cached -- <file>`.
- **Careful with `git stash` mid-refactor**: `rebuild-and-restart.sh` regenerates
  `WhisperShortcut/Docs/README.md`, which then blocks `stash pop`. Check the regenerated content
  matches the stashed one before discarding it.
- **Verifying a pure extraction mechanically** (used for R15 and R17, better than re-reading it):
  pull the old region with `git show HEAD:<file>`, strip comments/blank lines, apply the rename map,
  and assert every old code line still appears verbatim in the new file. What comes back is exactly
  the intentional differences — for R17 it printed the nine lines that moved into the owner's
  callbacks and nothing else. For shared logic, add a test and then **mutate the source to prove the
  test bites** (breaking `ChunkRetryPolicy`'s fail-fast made 2 of the 6 new tests fail; restore with
  a copy taken beforehand).
- A broad `git add` from a *parallel* session can sweep in files an in-progress refactor is holding
  (run 3: commit `d2e7e31` picked up that run's `AppConstants.swift` edit while the rest stayed in the
  working tree). Harmless, but check `git status` before reporting what is committed vs not.
- UserDefaults access is disciplined: 217 uses of `UserDefaultsKeys` vs 1 raw string literal.
- `AppConstants` / `UserDefaultsKeys` are long but flat declarations, not hotspots.
- The crusted-code signal (large files untouched for months) came back **empty** in run 5:
  `AudioChunker`, `MarkdownParsing`, `AudioRecorder`, `MainThreadWatchdog`, `TrelloAPIClient` are all
  small, single-purpose and stable. Stop treating staleness as a lead in this repo.
- `ChatView`'s message list, `StreamingBuffer` detachment, scroll persistence and `SelectableProseText`
  look baroque but each carries a hang-capture reference (`hang-20260701-134623`,
  `hang-20260703-093924`, `hang-20260704-205531`). Read the comment before touching anything there.
- `parseUserMessagePastedXML` runs the same ~12-line extract-and-advance twice (paste vs selection
  tags). Real duplication, ~15 lines, has never drifted — noted in run 5 so it isn't re-discovered
  as a finding.

## Working notes added in run 5

- **A mutation test that survives is not a passing test.** Run 5's first citation-offset fixture used
  a short code fence; breaking `OffsetMap` to the identity map did not fail it, because the shift
  (11 chars) was smaller than the paragraph, so the support range still overlapped by accident. The
  fixture only discriminates once the fence is longer than the paragraph being cited. Always mutate
  before believing a new test.
- **UI driving is currently unavailable**: `driver.sh` fails with "osascript is not allowed assistive
  access" — the terminal that runs Claude Code lacks System Settings ▸ Privacy & Security ▸
  Accessibility. Plan verification around unit tests until that is granted.
- **`private` is file-scoped, and that is what gates R3.** The obvious way to shrink a god view model
  — move each MARK region to an `extension ChatViewModel` in its own file — does not compile here,
  because the regions read `private` state (`store` and friends). Either the member becomes internal
  (weakens encapsulation module-wide) or the region earns a real owner / takes its dependencies as
  parameters. `ChatSearch` took the second route and needed only `store` passed in. Budget for that
  when planning the remaining slices; do not assume they are all this clean.
- **Watch for a stale `xcodebuild` holding the build DB.** Piping a test run through `head` kills the
  pipe (exit 144) but leaves xcodebuild running, and the next invocation fails with "database is
  locked". Redirect to a file and grep it, or `pkill -f xcodebuild` first.
- **Extracting to make something testable is a legitimate part of the refactor.** R25's fix lived
  inside a `private struct` in a 5,700-line view, which is precisely why the two copies could drift
  unnoticed. Moving it to `ReplyBlockBuilder.swift` was what allowed the bug to be *proven* (the
  mutation reproducing the old grounded path yields `["text","text","text"]` where a code block
  belongs) rather than argued.

## Working notes added in run 6

- **The release/submit corpus spans both repos.** `/release` and `/submit-appstore` live in the
  submodule (`.cursor/commands/`), the `app-store-connect` skill lives in the parent
  (`.agents/skills/`, symlinked from `.claude/skills/`). A finding about one is usually a finding
  about all three — sweep them together or the dedup only half-lands.
- **Doc refactors get a real equivalence check too.** For R31/R32 the check is a corpus-wide grep:
  count full explanations (must be 1) and pointers (must be N-1) after the change. That is what
  proved the collapse rather than eyeballing three files.
- **`asc versions list` is the ground truth for the App Store state string** — it returns
  `READY_FOR_SALE`. Two docs disagreed for months; one API call settled it. Query before writing
  down any `asc` enum value.
- **Nothing in this run enters the app bundle**, so `rebuild-and-restart.sh` was deliberately not
  run: `scripts/*.sh` and `.cursor/commands/*.md` are not compiled or copied into the app, and
  running it would have regenerated `WhisperShortcut/Docs/README.md` into a tree that already has
  unrelated in-progress work.
- **Observed while sweeping, not a refactor:** `v8.00` is tagged and on GitHub but has no App Store
  version at all (`asc versions list` tops out at 7.99 `READY_FOR_SALE`) — `/submit-appstore` was
  never run for it. Local `main` is also 4 ahead / 2 behind `origin/main`.
- **`--dry-run` does not always mean "show me the diff".** `asc localizations upload --dry-run`
  returns the same `"action":"update"` list for every locale whether you edited a field or not.
  Run the mutation check on a *tool's* dry-run before documenting it as a safety gate — the same
  discipline run 5 applied to tests.
- **Live-store finding, fixed on 8.00.** `supportUrl` on 7.99 was `whispershortcut.com/support`
  for **en-US only**; the other nine pointed at `github.com/mgsgde/whisper-shortcut/issues`.
  Apple refuses the edit on a `READY_FOR_SALE` version (`Attribute 'supportUrl' cannot be edited
  at this time`), so the ASC version for 8.00 was created (`a8838cba-…`, metadata copied from
  7.99) and all ten locales set there. **Carried-over metadata freezes when a version goes live —
  an editable version is the only window to fix it**, which is why `/submit-appstore` step 7 now
  checks the copied fields for cross-locale agreement.

## Working notes added in run 7

- **`static let shared` cannot live on a generic class.** The way to share a skeleton between two
  singletons without touching their call sites is a generic base class + `final class X: Base<M>`
  holding `shared`. A `typealias` does not work (no stored statics on generic types) and a
  forwarding wrapper is the anti-pattern the command warns about. R35 kept all 22 call-site files
  untouched this way.
- **Decide isolation per method by who calls it, not by what feels safe.** Making the whole store
  `@MainActor` would have rippled into `TranscriptionModel.hasRequiredCredential` (sync,
  nonisolated, called everywhere), `SpeechErrorFormatter` and the `LocalSpeechService` actor. The
  pure disk reads are `nonisolated`; only the task bookkeeping is main-actor. Grep the callers
  before choosing.
- **A self-heal that deletes must not cancel itself.** `deleteModel` now cancels first (the R35
  fix), but `makeReady`'s corrupt-download path runs *inside* the `readyTasks` entry that
  `cancelDownload` cancels — so the self-heal uses `removeFiles(of:)`, the file-system half
  without the cancel. Caught while writing the test, not while reading the code.
- **Prove the dead branch with the recorder's numbers, not intuition.** The Files-API branch
  looked plausible until `AudioRecorder`'s format (24 kHz × mono × 16-bit = 48 KB/s) put 20 MB at
  437 s, ten times the 45 s chunking threshold. One grep on `AVSampleRateKey` settled it.
- **`ObservableObject` + `@Published` in a generic base class works** with `@ObservedObject var
  store: ModelStore<M>` in a generic SwiftUI view; no `objectWillChange` plumbing needed.
- Tests are run against the App Store scheme (`@testable import WhisperShortcut_AppStore`);
  live-network suites carry `.tags(.liveNetwork)` and are skipped by the hermetic plan.

## Working notes added in run 8

- **A brief that names its own abort condition is what makes a delegate safe.** R48(d) told the
  builder to dump both JSON bodies and diff them, and to leave the step undone if they differed. They
  did — `resolvedThinkingConfig` never returns nil for `gemini-3.8-flash` (`.default` →
  `["thinkingLevel": "low"]`, `.minimal` clamped by `geminiRejectsMinimalThinking`) — so
  `callGeminiForAnalysis` still hand-builds its body and the rest of R48 landed anyway. Without the
  abort clause this would have shipped a silent request-shape change.
- **`Result`'s failure type must conform to `Error`.** `[String: Any]` does not, so a "return the
  reply dictionary on failure" helper needs a one-field wrapper struct. Cost one extra commit in R42.
- **An escaping closure cannot assign a captured `var`.** `openSSEStream`'s `onNon2xx` needed a tiny
  reference box for the chat stream to record the status its YouTube 400/403 retries read.
- **Check what a "pure forwarder" actually forwarded before deleting it.** `streamingBytes(for:)` was
  literally `session.bytes(for:)` and `resourceTimeout` was `Constants.resourceTimeout`, which is why
  routing TTS through the chat seam kept the same connection pool and the same deadline.
- **One closure cannot always express N call sites.** R47's AAC helper needed a separate `aacLabel`
  because `getMimeType("m4a")` is `audio/wav` while OpenRouter wants `"m4a"` — folding both into the
  extension closure would have changed OpenRouter's payload label. Two parameters, tables untouched.
- **A shared helper whose callers branch on different conditions takes the condition as a parameter.**
  R41's `syncAfterStoreMutation(activeSessionChanged:)` has seven callers using three different tests
  (`store.load().id != session.id`, `session.id != keepId`, `activeWillBeClosed`); unifying the
  condition would have been a behaviour change wearing a refactor's clothes.
- **Delegated typing worked at this scale**: 11 commits from four `cursor-agent` briefs on
  `grok-4.7-high`, one bounded finding group each, each self-verified (build exit status, hermetic
  suite, mutation-checked tests) and then re-read here against the diff rather than trusted.
- Two sub-threshold repetitions were deliberately NOT numbered and are recorded here so a later run
  does not rediscover them: the 3-line pasteboard-write triple (`ChatView` ×3), the empty
  `FocusedLoadResult` literal ×2, the `inline_data` map ×3, `"Speech service was deallocated"` ×3,
  and the UserDefaults "absent key means default" idiom ×3.

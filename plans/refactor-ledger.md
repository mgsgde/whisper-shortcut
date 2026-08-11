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

### Follow-ups that came out of applying the above

| ID  | Finding                                                              | Blast radius | Status  | Run | Notes                                                        |
| --- | -------------------------------------------------------------------- | ------------ | ------- | --- | ------------------------------------------------------------ |
| R9  | Dictate Prompt had no stale-result guard (found while applying R4)   | hot path     | applied | 1   | `77b5c96`; also collapsed 3 copies of the prompt cancel path |
| R10 | Voice Feedback never cleared `chunkStatuses` (found while applying R4) | hot path     | applied | 1   | `77b5c96`; clearing is now unconditional, flag deleted       |
| R27 | ⚠️ "add an API key" warning ignored routed transcription (found applying R26) | self-contained | applied | 5 | The menu-bar warning tested `!hasAnyKey && !hasOfflineTranscriptionModel`, so a user whose only setup was OpenRouter or a self-hosted endpoint was told to add a key they did not need. Now tests `canTranscribe`, which was already computed 6 lines above. Behaviour fix, not a refactor |
| R28 | OpenAI Dictate Prompt retried a spend-cap 429 (found applying R6)          | hot path     | applied  | 5   | `performWithRetryOn429` retried **any** 429, including `insufficient_quota` — a billing block that never clears. The user waited out a backoff before seeing an error that was never going to change. The other three retry loops all had this rule. Behaviour fix, shipped as part of R6 |

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

## Not yet swept

- `ChatView.swift`'s **input area** (`ChatInputAreaView`, ~470 lines) — the one rendering region run 5
  did not open. Everything else in the rendering half is now read.
- `ChatViewModel` (R3) — now **2,720 lines**, up from the 2,620 measured in run 3. Biggest remaining
  item in the repo and deserves a run of its own rather than a slot in a mixed list.
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

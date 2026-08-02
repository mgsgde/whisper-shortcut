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
| R3  | `ChatViewModel` is 9 responsibilities in 2,374 lines                       | cross-file   | deferred | 1   | Re-measured run 3: 13 responsibilities, ~2,620 lines. Cleanly extractable along its own MARKs — Search 242, Workspace-folders 180, Meeting 290, Archive/Restore/Delete 229, Scroll 28 (~970 lines out, leaving the ~1,450-line send/stream engine). Largest remaining item |
| R4  | `performTranscription` / `performPrompting` are one envelope copied twice   | hot path     | applied  | 1   | `AudioJobSpec` + `runAudioJob`; Voice Feedback shares `cancelAudioJob`  |
| R5  | Dictate Prompt hand-rolls an OpenAI client that `OpenAIChatProvider` already is | hot path | deferred | 1   | Bigger than run 1 recorded: the whole *envelope* (screenshot, clipboard, history, audio) is assembled twice, `SpeechService.swift` Gemini ~816-901 vs OpenAI ~909-1086. Target: build the user turn once as Gemini-shaped `contents` (both OpenAI converters already consume that shape), then only send per provider. R18/R19/R20 came out of measuring this |
| R6  | Four independent retry/backoff policies                                    | cross-file   | deferred | 1   | Re-measured run 3: was 5, now **3** after R15 — `GeminiAPIClient.performRequest`, `GeminiAPIClient` stream, `SpeechService.performWithRetryOn429`. Separately: OpenAI/Grok/Anthropic/Local chat streams have **no** retry, so a transient 503 kills a turn Gemini survives — closing that is a behavior change, not this refactor |
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
| R23 | Provider capabilities still live as ~25 exhaustive switches on the model enum | cross-file | deferred | 4 | Next slice after R21. `apiEndpoint`, `costLevel`, the request-shape knobs and the "honors system prompt / glossary / temperature / thinking" facts are provider-level, not model-level, but are still written per case. Moving them onto `TranscriptionProvider` is what collapses the switches. Do this **before** considering R24 |
| R24 | Splitting persisted selection into `(provider, model)`                     | cross-file   | deferred | 4   | The expensive part of the two-axis refactor and the least valuable — needs a UserDefaults migration off the flat raw value. Explicitly **not** scheduled: R21–R23 deliver the structure and the UI without it. Only revisit if a provider appears whose model list cannot be expressed as enum cases *and* the R21 escape hatch stops working. Note two such providers already exist (`openRouterTranscription`, `selfHostedTranscription`) and are handled fine by a side-channel slug/URL |
| R20 | OpenAI prompt path maps history to messages by hand                       | self-contained | deferred | 3   | `OpenAIChatCompletionsConverter.messages(from:)` exists but takes `[[String: Any]]`, while `getContentsForAPI` returns typed `[GeminiChatRequest.GeminiChatContent]`. Bridging costs more code than the 5-line mapping — becomes free with R5. Blocked on R5 |

### Follow-ups that came out of applying the above

| ID  | Finding                                                              | Blast radius | Status  | Run | Notes                                                        |
| --- | -------------------------------------------------------------------- | ------------ | ------- | --- | ------------------------------------------------------------ |
| R9  | Dictate Prompt had no stale-result guard (found while applying R4)   | hot path     | applied | 1   | `77b5c96`; also collapsed 3 copies of the prompt cancel path |
| R10 | Voice Feedback never cleared `chunkStatuses` (found while applying R4) | hot path     | applied | 1   | `77b5c96`; clearing is now unconditional, flag deleted       |

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

## Not yet swept

- `ChatView.swift`'s rendering half **minus the button views** (message list, input area, model reply
  view, markdown/code blocks, message bubble — ~2,000 lines). Still the highest combined signal in
  the repo: 250 churn / 5,631 lines / 80 fix-commits (counting its old `GeminiChatView.swift` name —
  the churn stats hide this unless you follow the rename)
- `PopupNotificationWindow.swift` (1,223), `ContextDerivation.swift` (937), `TranscriptionModels.swift` (1,013)
- `Onboarding/` (`WelcomeSteps.swift` 934), `GeminiAPIClient.swift` stream body (~600 lines, read only
  down to line 440 in run 3), `SpeechService`'s TTS + transcription-provider half (~1,400 lines)

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

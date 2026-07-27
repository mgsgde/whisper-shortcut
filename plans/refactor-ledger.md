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
| R3  | `ChatViewModel` is 9 responsibilities in 2,374 lines                       | cross-file   | deferred | 1   | Largest remaining item. Do after R1's seam pattern has settled          |
| R4  | `performTranscription` / `performPrompting` are one envelope copied twice   | hot path     | applied  | 1   | `AudioJobSpec` + `runAudioJob`; Voice Feedback shares `cancelAudioJob`  |
| R5  | Dictate Prompt hand-rolls an OpenAI client that `OpenAIChatProvider` already is | cross-file   | deferred | 1   | `SpeechService.executePromptWithOpenAI` ~90 lines of parallel client    |
| R6  | Four independent retry/backoff policies                                    | cross-file   | deferred | 1   | `GeminiAPIClient` ×2, `ChunkTTSService`, `SpeechService`; OpenAI/Grok streams don't retry at all |
| R7  | Provider clone leftovers — `instructions(from:)` ×2, tool-decl encoding ×5  | self-contained | applied | 1   | `cec1b0d`; `GeminiSystemInstruction` + `LLMToolDeclaration` encoders    |
| R8  | Per-enum UserDefaults loader boilerplate in `SettingsConfiguration`         | self-contained | superseded | 1 | Absorbed into R11's slot table — the per-enum loaders survive, the table records which setting uses which |
| R11 | `SettingsViewModel` load/save was a hand-maintained parallel list          | cross-file   | applied  | 2   | `120c2c1` → `SettingsSlot`; 26 settings declared once; round-trip test proven to fail on injected key drift |
| R12 | `KeychainManager` cloned 7 provider save/get/delete triples               | hot path     | applied  | 2   | `8d31dd0` → `KeychainCredential`; 467 → 264 lines, 38 call sites       |
| R13 | Four API-key settings sections were 89-line clones                        | self-contained | applied | 2   | `8d31dd0` → `APIKeyEntrySection` + descriptor on `APIKeyProvider`      |
| R14 | Three model pickers each redeclared the same tile grid                    | self-contained | applied | 2   | `0e10d37` → `ModelGrid` + `ModelGroupHeader`                           |

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

## Not yet swept

- `ChatView.swift` below the view model (lines ~2500–5346: the SwiftUI rendering half). Highest
  combined signal left: 247 churn / 5,346 lines / 79 fix-commits (counting its old
  `GeminiChatView.swift` name — the churn stats hide this unless you follow the rename)
- `PopupNotificationWindow.swift` (1,243), `ContextDerivation.swift` (937), `TranscriptionModels.swift` (937)
- `Onboarding/` (`WelcomeSteps.swift` 934), the TTS chunking path (`ChunkTTSService`), `GeminiAPIClient.swift` (1,152)

## Signals checked and cleared (don't re-flag without new evidence)

- `#if APP_STORE` is contained to 7 sites — not scattered.
- `Settings/Tabs/*` are thin composition of named section views, not scaffolding clones (run 2).
- `ConfigurableShortcutSlot` (`SettingsViewModel`) and `TTSProvider.voiceUserDefaultsKey` are
  already the table-driven pattern R11 wants — use them as the model, don't re-flag them.
- R6 grew from 4 retry policies to 5 (`ChunkTranscriptionService` added one) — re-measure, don't
  trust the run-1 count.
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
- UserDefaults access is disciplined: 217 uses of `UserDefaultsKeys` vs 1 raw string literal.
- `AppConstants` / `UserDefaultsKeys` are long but flat declarations, not hotspots.

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
| R8  | Per-enum UserDefaults loader boilerplate in `SettingsConfiguration`         | self-contained | deferred | 1   | 5 copies of read-raw → migrate → validate → fall back                  |

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

## Not yet swept

- `ChatView.swift` below the view model (lines ~2500–5265: the SwiftUI rendering half)
- `Settings/` — `SettingsConfiguration.swift` (1,590 lines) and the per-tab views
- `PopupNotificationWindow.swift` (1,243), `ContextDerivation.swift` (937), `TranscriptionModels.swift` (937)
- `Onboarding/`, the TTS chunking path (`ChunkTTSService`), `GeminiAPIClient.swift` (1,152)

## Signals checked and cleared (don't re-flag without new evidence)

- `#if APP_STORE` is contained to 7 sites — not scattered.
- UserDefaults access is disciplined: 217 uses of `UserDefaultsKeys` vs 1 raw string literal.
- `AppConstants` / `UserDefaultsKeys` are long but flat declarations, not hotspots.

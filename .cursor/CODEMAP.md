# CODEMAP — where to find code by topic

Read this file **just-in-time** when orienting in the repo (same role as sabaki.dance's
`.cursor/CODEMAP.md`). Rules and conventions: `.cursor/rules/index.mdc`; context-file layout:
`.cursor/CONTEXT-CONVENTIONS.md`. Everything below is a flat Xcode target under
`WhisperShortcut/` unless a directory is named. File names are the index — when a row and the
tree disagree, the tree wins; fix the row.

## Core flow

| Topic                                   | Start here                                                                                                          |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| App state machine (single source)       | `AppState.swift` — always transition through it, never flip UI flags                                                |
| Orchestration, menu bar, shortcuts      | `MenuBarController.swift`, `Shortcuts.swift`, `ShortcutConfig.swift`, `FnDictationToggle.swift`                     |
| Dictate / Dictate Prompt / Read Aloud   | `SpeechService.swift` (transcribe, executePrompt, readSelectionAloud) → `TranscriptionProvider.swift`               |
| Recording & chunking                    | `AudioRecorder.swift`, `ChunkedDictateRecorder.swift`, `AudioChunker.swift`, `AudioMerger.swift`, `AudioTranscoder.swift`, `Chunk*.swift` |
| Streaming dictation                     | `DictateStreamingSession.swift`, `TranscriptMerger.swift`, `SpeechTextSanitizer.swift`, `TextProcessingUtility.swift` |
| Offline dictation (WhisperKit)          | `LocalSpeechService.swift` — read its actor doc comment before touching speed; `ModelManager.swift`                 |
| Text-to-speech                          | `ChunkTTSService.swift`, `SystemTTSService.swift`, `TTSPlaybackSession.swift`, `TextChunker.swift`                  |
| Clipboard / paste at cursor             | `ClipboardManager.swift`, `AccessibilityPermissionManager.swift`, `PermissionStatusChecker.swift`                   |
| Live meeting transcription              | `LiveMeetingRecorder.swift`, `LiveMeetingSession.swift`, `LiveMeetingTranscriptStore.swift`, `MeetingListService.swift` |
| Voice Feedback                          | `VoiceFeedbackService.swift`                                                                                        |
| Screenshot                              | `ScreenshotSaveLocation.swift` (+ the screenshot path in `MenuBarController.swift`)                                 |
| Feedback UI (pill / popups)             | `RecordingIndicatorWindow.swift`, `PopupNotificationWindow.swift`, `SpeechErrorFormatter.swift`, `AppErrors.swift`  |

## Chat

| Topic                                   | Start here                                                                                                          |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Provider abstraction + factory          | `LLMChatProvider.swift` (`ChatModelProvider` enum, `LLMProviderFactory`)                                            |
| Providers                               | `GeminiChatProvider.swift`, `OpenAIChatProvider.swift`, `GrokChatProvider.swift`, `AnthropicChatProvider.swift`, `LocalLLMChatProvider.swift`, `MLXChatProvider.swift` |
| Slash commands, model switching         | `ChatViewModel` in `ChatView.swift` (`commandsBeforeModels` / `commandsAfterModels` / `modelCommandLookup`), `ChatModelCommandResolver.swift`, `ModelSelectionReconciler.swift` |
| Chat UI                                 | `ChatRootView.swift`, `ChatView.swift`, `ChatSidebar.swift`, `ChatComposerTextView.swift`, `ChatTheme.swift`, `ChatWindowController.swift`, `ChatWindowManager.swift`, `MessageActionButton.swift`, `MarkdownParsing.swift` |
| Sessions, memory, search                | `ChatSessionStore.swift`, `ChatMemoryStore.swift`, `ChatSearch.swift`, `PromptConversationHistory.swift`            |
| Tools (local, Google, Trello, docs)     | `ChatTools.swift` (`ChatToolRegistry`), `ChatToolTurnMemo.swift`, `Workspace*.swift` (context files, file tools, folders, map) |
| Streaming hang protection               | `ChatStreamLoopGuard.swift`, `MainThreadWatchdog.swift` (writes `hang-*.txt`; skill `analyze-chat-freeze`)          |
| OpenRouter connect (PKCE)               | `OpenRouterOAuthService.swift`, `OpenRouterOAuthConfig.swift`, `OpenRouterModelCatalog.swift`, `LoopbackOAuthListener.swift`, `OAuthCSRF.swift` |
| Google account (Calendar/Tasks/Gmail)   | `GoogleAccountOAuthService.swift`, `GoogleCalendarOAuthConfig.swift`, `GoogleCalendarAPIClient.swift`, `GoogleTasksAPIClient.swift`, `GmailAPIClient.swift` |
| Trello                                  | `TrelloOAuthService.swift`, `TrelloOAuthConfig.swift`, `TrelloAPIClient.swift`                                      |
| Grounding links (YouTube, X)            | `YouTubeVideoLink.swift`, `XSearchHandles.swift`                                                                    |

## Models, prompts, credentials

| Topic                                   | Start here                                                                                                          |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Transcription model IDs                 | `TranscriptionModels.swift` — the list lives here, never in prose                                                   |
| Prompt / TTS model IDs                  | `PromptModel`, `TTSModel` in `Settings/Shared/SettingsConfiguration.swift`                                          |
| Gemini API client                       | `GeminiAPIClient.swift`, `GeminiCredentialProvider.swift`                                                           |
| System prompts                          | `SystemPromptsStore.swift`, `AppConstants.swift` (skill `gemini-system-prompt-best-practices`)                      |
| Keys & Keychain                         | `KeychainManager.swift`, `KeychainCredential.swift`, `ProviderCredentials.swift`, `CustomEndpointAuth.swift`        |
| Networking resilience                   | `NetworkDeadline.swift`, `RetryBackoff.swift`, `RateLimitCoordinator.swift`, `ConnectionPrewarmer.swift`, `OfflineMode.swift` |
| Local models (Ollama / LM Studio / MLX) | `LocalLLMModelManager.swift`, `MLXPromptCache.swift`, `MLXTransformersAdapters.swift`                               |

## Smart Improvement & usage data

| Topic                                   | Start here                                                                                                          |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Interaction / signal logging            | `ContextLogger.swift`, `ContextDerivation.swift`, `DebugRawResponses.swift`; paths in `AppSupportPaths.swift`, `Docs/data-directories.md` |
| Smart Improvement                       | `SmartImprovementTypes.swift`, `SmartImprovementReviewView.swift`, `AutoPromptImprovementScheduler.swift`, `ImproveFromUsageAutoRunCoordinator.swift` |
| Glossary learning                       | `GlossaryFastLearner.swift` (NSSpellChecker, main-thread only)                                                      |
| Transcription history, usage report     | `TranscriptionHistoryStore.swift`, `UsageReport.swift`                                                              |
| Review prompt (App Store rating)        | `ReviewPrompter.swift`                                                                                              |

## Settings, onboarding, app shell

| Topic                                   | Start here                                                                                                          |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Settings window & tabs                  | `SettingsView.swift`, `SettingsWindowController.swift`, `Settings/Tabs/*SettingsTab.swift`                          |
| Settings model, keys, constants         | `Settings/Shared/` (`SettingsViewModel`, `SettingsConfiguration`, `SettingsConstants`, `SettingsSlot`), `SettingsManager.swift`, `UserDefaultsKeys.swift` |
| Reusable settings components            | `Settings/Components/` (model grid/tiles, API-key chip + validator, shortcut recorder, prompt editors)              |
| Onboarding                              | `Onboarding/` (`WelcomeView`, `WelcomeSteps`, `OnboardingTryItPanel`)                                               |
| App entry, entitlements, privacy copy   | `FullApp.swift`, `Info.plist`, `*.entitlements`, `PrivacyCopy.swift`, `PRIVACY.md`, `FeedbackLinks.swift`           |
| Logging                                 | `DebugLogger.swift` only — view with `bash scripts/logs.sh -t 5m`                                                   |

## Outside the target

| Topic                                   | Start here                                                                                                          |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Tests                                   | `WhisperShortcutTests/` — `bash scripts/run-tests.sh` (live suites carry `(live)` in the `@Suite` name)             |
| Build / release / App Store             | `scripts/rebuild-and-restart.sh`, `scripts/create-release.sh`, `.cursor/commands/{release,submit-appstore}.md`      |
| Scheduled loops & implementer           | `scripts/*-job.sh`, `scripts/implementer/`, `scripts/loop-prompt.sh`; architecture `plans/agent-loops.md`           |
| Ledgers & queues                        | `plans/improvement-ledger.md`, `plans/loop-ledger.md`, `plans/implementer-queue.md`, `plans/instrumentation-gaps.md` |
| Bundled docs the in-app Chat reads      | `README.md` → copied to `WhisperShortcut/Docs/README.md` by the rebuild script                                      |

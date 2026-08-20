import Foundation

/// Centralized UserDefaults keys for type-safe access throughout the app
/// This prevents typos and makes refactoring easier
enum UserDefaultsKeys {
  // MARK: - Chat Window Settings
  static let chatCloseOnFocusLoss = "geminiCloseOnFocusLoss"
  static let chatSidebarVisible = "geminiSidebarVisible"
  /// Per-session reading position: maps session UUID → id of the message kept at the top of the
  /// chat scroll view. Stored as [String: String]. Lets the scroll position survive window
  /// hide/show (incl. the cross-screen resize that recreates the list), tab switches, and relaunch.
  static let chatScrollAnchors = "chatScrollAnchors"

  // MARK: - Settings Window
  static let settingsCloseOnFocusLoss = "settingsCloseOnFocusLoss"
  /// Last Settings sidebar pane (`SettingsTab.rawValue`). Restored on next open, matching
  /// the macOS HIG recommendation for multi-pane settings windows.
  static let settingsSelectedTab = "settingsSelectedTab"

  // MARK: - Model Settings
  static let selectedTranscriptionModel = "selectedTranscriptionModel"
  static let selectedPromptModel = "selectedPromptModel"
  static let selectedChatModel = "selectedOpenGeminiModel"
  /// Most-recently-used chat models (array of PromptModel rawValues, most recent first).
  /// Drives the recency ordering of the model-switch commands in chat autocomplete.
  static let chatModelRecency = "chatModelRecency"

  // MARK: - Prompt Settings
  static let customPromptText = "customPromptText"
  static let promptModeSystemPrompt = "promptModeSystemPrompt"

  // MARK: - Whisper Settings
  static let whisperLanguage = "whisperLanguage"
  
  // MARK: - Notification Settings
  static let showPopupNotifications = "showPopupNotifications"
  static let notificationPosition = "notificationPosition"
  static let notificationDuration = "notificationDuration"
  static let errorNotificationDuration = "errorNotificationDuration"
  /// One-shot migration flag: default notification position moved left-top → center-bottom.
  static let didMigrateNotificationPositionToCenterBottom = "didMigrateNotificationPositionToCenterBottom"

  /// One-shot migration flag: default Gemini models moved to the 3.5 Flash-Lite / 3.6 Flash tier.
  static let didMigrateGeminiDefaultsTo36 = "didMigrateGeminiDefaultsTo36"

  /// One-shot migration flag: chat / Dictate Prompt / meeting-summary defaults moved 3.6 Flash →
  /// 3.5 Flash-Lite, and Smart Improvement moved 3.1 Pro → 3.6 Flash (cost).
  static let didMigrateGeminiDefaultsToFlashLite = "didMigrateGeminiDefaultsToFlashLite"

  /// One-shot migration flag: dictation + meeting transcription moved back 3.5 Flash-Lite →
  /// 3.1 Flash-Lite (speed, glossary adherence, hallucination containment).
  static let didMigrateTranscriptionTo31FlashLite = "didMigrateTranscriptionTo31FlashLite"

  // MARK: - Recording Safeguards
  static let confirmAboveDurationSeconds = "confirmAboveDurationSeconds"

  // MARK: - Auto-Paste Settings
  static let autoPasteAfterDictation = "autoPasteAfterDictation"
  /// After auto-paste, put back whatever was on the clipboard before dictation
  /// ("non-destructive paste"). Only has an effect while auto-paste is on.
  static let restoreClipboardAfterPaste = "restoreClipboardAfterPaste"

  // MARK: - Fn Push-to-Talk
  /// Fn (Globe) key dictation: hold to record and release to transcribe, or tap to
  /// toggle the recording on and tap again to stop.
  static let holdFnToDictate = "holdFnToDictate"

  // MARK: - Screenshot Settings
  static let screenshotInPromptMode = "screenshotInPromptMode"
  /// When true, captured screenshots (⌘3 and the in-chat button) are also written
  /// as PNG files into the user-selected folder, in addition to the clipboard.
  static let screenshotSaveEnabled = "screenshotSaveEnabled"
  /// Security-scoped bookmark (Data) for the folder screenshots are saved into.
  static let screenshotSaveBookmark = "screenshotSaveBookmark"
  /// Human-readable path of the screenshot save folder, for display in Settings.
  static let screenshotSaveFolderDisplayPath = "screenshotSaveFolderDisplayPath"
  /// Last directory the chat Attach picker landed on; reopened next time (see C2 behavior).
  static let lastAttachDirectoryPath = "lastAttachDirectoryPath"

  // MARK: - Workspace Folders
  /// Folders the chat may read from, as `[[String: Any]]` entries holding a security-scoped
  /// bookmark (Data) plus the originally picked path (String). See `WorkspaceFolders`.
  static let workspaceFolders = "workspaceFolders"

  // MARK: - App State
  static let shouldTerminate = "shouldTerminate"
  static let hasUsedPromptFeature = "hasUsedPromptFeature"
  /// Whether we've already shown the native macOS Accessibility prompt (which also pre-registers
  /// the app in System Settings). macOS suppresses the prompt after a prior denial, so once this
  /// is set we deep-link into System Settings instead of re-prompting.
  static let hasShownAccessibilityPrompt = "hasShownAccessibilityPrompt"
  static let hasAppliedLaunchAtLoginDefault = "hasAppliedLaunchAtLoginDefault"
  static let hasCompletedOnboarding = "hasCompletedOnboarding"
  /// WelcomeStep.rawValue the onboarding tour is currently on. Persisted so a mid-tour
  /// restart (e.g. macOS "Quit & Reopen" after granting a permission) resumes on the same
  /// step instead of starting over. Reset to 0 when onboarding finishes or is dismissed.
  static let onboardingCurrentStep = "onboardingCurrentStep"
  
  // MARK: - Review Prompter
  static let successfulOperationsCount = "successfulOperationsCount"
  static let lastReviewPromptDate = "lastReviewPromptDate"
  /// True when the counter+cooldown have been satisfied but the prompt hasn't been
  /// shown yet — we wait for the user to focus this app (menu bar or chat window)
  /// so we don't steal focus from whatever app they're working in.
  static let pendingReviewPrompt = "pendingReviewPrompt"
  /// GitHub-distribution one-time "support me on the App Store" popup state.
  /// Set once shown (regardless of choice) so we never nag a second time.
  static let githubSupportPromptShown = "githubSupportPromptShown"
  
  // MARK: - Debug (commented out in code, kept for reference)
  static let enableDebugTestMenu = "enableDebugTestMenu"
  /// When true, the final assistant response of each chat send is written as a `.md`
  /// file under `AppSupportPaths.debugRawResponsesURL()`. Used to reproduce markdown
  /// rendering bugs without instrumenting code each time. Off by default.
  static let saveRawAssistantResponses = "saveRawAssistantResponses"

  // MARK: - Live Meeting Settings
  static let meetingTranscriptSectionExpanded = "meetingTranscriptSectionExpanded"
  static let liveMeetingChunkInterval = "liveMeetingChunkInterval"
  static let liveMeetingSafeguardDurationSeconds = "liveMeetingSafeguardDurationSeconds"
  static let selectedTranscriptionModelForMeetings = "selectedTranscriptionModelForMeetings"
  static let selectedMeetingSummaryModel = "selectedMeetingSummaryModel"

  // MARK: - Context Settings
  static let contextLoggingEnabled = "userContextLoggingEnabled"
  static let contextInPromptEnabled = "userContextInPromptEnabled"
  static let contextMaxEntriesPerMode = "userContextMaxEntriesPerMode"
  static let contextMaxTotalChars = "userContextMaxTotalChars"
  static let selectedImprovementModel = "selectedImprovementModel"
  static let improveFromUsageAutoRunInterval = "improveFromUsageAutoRunInterval"
  static let lastAutoImprovementRunDate = "lastAutoImprovementRunDate"

  // MARK: - Custom Transcription API
  static let customTranscriptionAPIURL = "customTranscriptionAPIURL"

  // MARK: - Transcription tuning (Gemini + OpenRouter)
  /// `generationConfig.temperature` sent with transcription requests. Before this existed nothing
  /// was sent and every request ran at the model default of 1.0.
  static let transcriptionTemperature = "transcriptionTemperature"
  /// `generationConfig.thinkingConfig.thinkingLevel` for transcription.
  static let transcriptionThinkingEffort = "transcriptionThinkingEffort"

  // MARK: - OpenRouter transcription
  /// Model slug sent to OpenRouter for dictation (e.g. `google/gemini-3.5-flash-lite`). OpenRouter
  /// has no `/v1/audio/transcriptions`, so audio goes through chat completions — see
  /// `SpeechService.transcribeWithOpenRouter`.
  static let openRouterTranscriptionModelID = "openRouterTranscriptionModelID"

  // MARK: - Custom OpenAI-compatible Chat Endpoint (OpenRouter, LiteLLM, self-hosted proxy, …)
  /// Base URL up to `/v1` (the app appends `/chat/completions`). Empty → official OpenAI API.
  static let customOpenAIChatEndpointURL = "customOpenAIChatEndpointURL"
  /// Model tag for the Custom endpoint chat model (e.g. `openai/gpt-4o` on OpenRouter).
  static let customOpenAIChatModelID = "customOpenAIChatModelID"

  // MARK: - Grok X search
  /// Default X accounts new chats restrict Grok's `x_search` to, stored space-separated
  /// (see `XSearchHandles`). Empty → search all of X. Per-chat override: `/x` in the chat window.
  static let grokXSearchHandles = "grokXSearchHandles"

  // MARK: - Local LLM (OpenAI-compatible, e.g. Ollama / LM Studio)
  /// Base URL of the local OpenAI-compatible server (the part before `/chat/completions`),
  /// e.g. `http://localhost:11434/v1`. Empty → SettingsDefaults.localEndpointURL.
  static let localPromptEndpointURL = "localPromptEndpointURL"
  /// The model tag to request from the local server (e.g. an Ollama tag like `qwen3`).
  /// Empty → SettingsDefaults.localModelID.
  static let localPromptModelID = "localPromptModelID"

  // MARK: - Read Aloud
  /// When true, selected text is run through a Gemini "rewrite for speech" pass before TTS.
  /// Default: enabled. Stored under SettingsDefaults.readAloudSmartRewriteEnabled.
  static let readAloudSmartRewriteEnabled = "readAloudSmartRewriteEnabled"
  /// Local playback rate for Read Aloud TTS. Stored as Double (e.g. 1.0, 1.25, 1.5).
  static let readAloudSpeed = "readAloudSpeed"
  /// Selected Read Aloud TTS model raw value (Gemini / OpenAI / xAI). See TTSModel.
  static let selectedReadAloudModel = "selectedReadAloudModel"
  /// Selected Read Aloud voice per provider. Stored separately so switching providers and back
  /// keeps each provider's chosen voice. Empty/unknown → that provider's default voice.
  /// See TTSProvider.voices / ReadAloudPreferences.voice(for:).
  static let selectedReadAloudVoiceGemini = "selectedReadAloudVoiceGemini"
  static let selectedReadAloudVoiceOpenAI = "selectedReadAloudVoiceOpenAI"
  static let selectedReadAloudVoiceXAI = "selectedReadAloudVoiceXAI"
}


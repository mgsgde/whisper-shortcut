import Foundation

/// Centralized UserDefaults keys for type-safe access throughout the app
/// This prevents typos and makes refactoring easier
enum UserDefaultsKeys {
  // MARK: - Chat Window Settings
  static let chatCloseOnFocusLoss = "geminiCloseOnFocusLoss"
  static let chatSidebarVisible = "geminiSidebarVisible"

  // MARK: - Settings Window
  static let settingsCloseOnFocusLoss = "settingsCloseOnFocusLoss"

  // MARK: - Model Settings
  static let selectedTranscriptionModel = "selectedTranscriptionModel"
  static let selectedPromptModel = "selectedPromptModel"
  static let selectedChatModel = "selectedOpenGeminiModel"

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

  // MARK: - Recording Safeguards
  static let confirmAboveDurationSeconds = "confirmAboveDurationSeconds"

  // MARK: - Auto-Paste Settings
  static let autoPasteAfterDictation = "autoPasteAfterDictation"

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

  // MARK: - App State
  static let shouldTerminate = "shouldTerminate"
  static let hasUsedPromptFeature = "hasUsedPromptFeature"
  static let hasAppliedLaunchAtLoginDefault = "hasAppliedLaunchAtLoginDefault"
  static let hasCompletedOnboarding = "hasCompletedOnboarding"
  
  // MARK: - Review Prompter
  static let successfulOperationsCount = "successfulOperationsCount"
  static let lastReviewPromptDate = "lastReviewPromptDate"
  /// App version (CFBundleShortVersionString) at which the counter was last reset.
  /// On version bump we reset the counter so users get re-prompted after meaningful updates.
  static let lastReviewedAppVersion = "lastReviewedAppVersion"
  /// True when the counter+cooldown have been satisfied but the prompt hasn't been
  /// shown yet — we wait for the user to open the menu bar so we don't steal focus
  /// from whatever app they're working in.
  static let pendingReviewPrompt = "pendingReviewPrompt"
  /// GitHub-distribution one-time "support me on the App Store" popup state.
  /// Set once shown (regardless of choice) so we never nag a second time.
  static let githubSupportPromptShown = "githubSupportPromptShown"
  
  // MARK: - Debug (commented out in code, kept for reference)
  static let enableDebugTestMenu = "enableDebugTestMenu"

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

  // MARK: - Read Aloud
  /// When true, selected text is run through a Gemini "rewrite for speech" pass before TTS.
  /// Default: enabled. Stored under SettingsDefaults.readAloudSmartRewriteEnabled.
  static let readAloudSmartRewriteEnabled = "readAloudSmartRewriteEnabled"
  /// Local playback rate for Read Aloud TTS. Stored as Double (e.g. 1.0, 1.25, 1.5).
  static let readAloudSpeed = "readAloudSpeed"
  /// Selected Read Aloud TTS model raw value (Gemini / OpenAI / xAI). See TTSModel.
  static let selectedReadAloudModel = "selectedReadAloudModel"
}


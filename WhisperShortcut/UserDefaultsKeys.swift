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
  
  // MARK: - Legacy Keys (for migration)
  static let selectedTTSModel = "selectedTTSModel"
  
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
  
  // MARK: - App State
  static let shouldTerminate = "shouldTerminate"
  static let hasUsedPromptFeature = "hasUsedPromptFeature"
  
  // MARK: - Review Prompter
  static let successfulOperationsCount = "successfulOperationsCount"
  static let lastReviewPromptDate = "lastReviewPromptDate"
  
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

}


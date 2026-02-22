import Foundation

/// Centralized UserDefaults keys for type-safe access throughout the app
/// This prevents typos and makes refactoring easier
enum UserDefaultsKeys {
  // MARK: - Model Settings
  static let selectedTranscriptionModel = "selectedTranscriptionModel"
  static let selectedPromptModel = "selectedPromptModel"
  static let selectedPromptAndReadModel = "selectedPromptAndReadModel"
  static let selectedOpenGeminiModel = "selectedOpenGeminiModel"

  // MARK: - Prompt Settings
  static let customPromptText = "customPromptText"
  static let promptModeSystemPrompt = "promptModeSystemPrompt"
  static let promptAndReadSystemPrompt = "promptAndReadSystemPrompt"
  
  // MARK: - Read Aloud Settings
  static let selectedReadAloudVoice = "selectedReadAloudVoice"
  static let selectedPromptAndReadVoice = "selectedPromptAndReadVoice"
  static let readAloudPlaybackRate = "readAloudPlaybackRate"
  
  // MARK: - Legacy Keys (for migration)
  static let selectedReadAloudVoiceLegacy = "selected_read_aloud_voice"
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
  
  // MARK: - App State
  static let shouldTerminate = "shouldTerminate"
  static let hasUsedPromptFeature = "hasUsedPromptFeature"
  
  // MARK: - Review Prompter
  static let successfulOperationsCount = "successfulOperationsCount"
  static let lastReviewPromptDate = "lastReviewPromptDate"
  
  // MARK: - Debug (commented out in code, kept for reference)
  static let enableDebugTestMenu = "enableDebugTestMenu"

  // MARK: - Live Meeting Settings
  static let liveMeetingChunkInterval = "liveMeetingChunkInterval"
  static let liveMeetingSafeguardDurationSeconds = "liveMeetingSafeguardDurationSeconds"

  // MARK: - Context Settings
  static let contextLoggingEnabled = "userContextLoggingEnabled"
  static let contextInPromptEnabled = "userContextInPromptEnabled"
  static let contextMaxEntriesPerMode = "userContextMaxEntriesPerMode"
  static let contextMaxTotalChars = "userContextMaxTotalChars"

  // MARK: - Auto-Improvement Settings
  static let selectedImprovementModel = "selectedImprovementModel"
  static let autoApplyImprovements = "autoApplyImprovements"
  static let lastAutoImprovementRunDate = "lastAutoImprovementRunDate"
  static let improveFromUsageAutoRunInterval = "improveFromUsageAutoRunInterval"
  static let promptImprovementDictationCount = "promptImprovementDictationCount"
  static let promptImprovementDictationThreshold = "promptImprovementDictationThreshold"

  // MARK: - Proxy API (Phase 1 – latency testing)
  static let proxyAPIBaseURL = "proxyAPIBaseURL"
  static let useGeminiViaProxy = "useGeminiViaProxy"
}


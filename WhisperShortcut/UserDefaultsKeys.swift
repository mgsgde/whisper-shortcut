import Foundation

/// Centralized UserDefaults keys for type-safe access throughout the app
/// This prevents typos and makes refactoring easier
enum UserDefaultsKeys {
  // MARK: - Model Settings
  static let selectedTranscriptionModel = "selectedTranscriptionModel"
  static let selectedPromptModel = "selectedPromptModel"
  static let selectedPromptAndReadModel = "selectedPromptAndReadModel"
  
  // MARK: - Prompt Settings
  static let customPromptText = "customPromptText"
  static let dictationDifficultWords = "dictationDifficultWords"
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

  // MARK: - User Context Settings
  static let userContextLoggingEnabled = "userContextLoggingEnabled"
  static let userContextInPromptEnabled = "userContextInPromptEnabled"
  static let userContextMaxEntriesPerMode = "userContextMaxEntriesPerMode"
  static let userContextMaxTotalChars = "userContextMaxTotalChars"

  /// Stored value before applying a suggested system prompt (Dictate Prompt); used for Restore Previous.
  static let previousPromptModeSystemPrompt = "previousPromptModeSystemPrompt"
  static let hasPreviousPromptModeSystemPrompt = "hasPreviousPromptModeSystemPrompt"
  /// Stored value before applying a suggested system prompt (Prompt & Read); used for Restore Previous.
  static let previousPromptAndReadSystemPrompt = "previousPromptAndReadSystemPrompt"
  static let hasPreviousPromptAndReadSystemPrompt = "hasPreviousPromptAndReadSystemPrompt"
  /// Stored value before applying a suggested dictation prompt; used for Restore Previous.
  static let previousCustomPromptText = "previousCustomPromptText"
  static let hasPreviousCustomPromptText = "hasPreviousCustomPromptText"
  /// Stored value before applying suggested difficult words; used for Restore Previous.
  static let previousDictationDifficultWords = "previousDictationDifficultWords"
  static let hasPreviousDictationDifficultWords = "hasPreviousDictationDifficultWords"
  /// Stored value before applying suggested user context; used for Restore Previous.
  static let previousUserContext = "previousUserContext"
  static let hasPreviousUserContext = "hasPreviousUserContext"

  /// Last applied AI suggestion; used for Reset to Latest (Dictate, Dictate Prompt, Dictate Prompt & Read, User Context).
  static let lastAppliedCustomPromptText = "lastAppliedCustomPromptText"
  static let hasLastAppliedCustomPromptText = "hasLastAppliedCustomPromptText"
  static let lastAppliedPromptModeSystemPrompt = "lastAppliedPromptModeSystemPrompt"
  static let hasLastAppliedPromptModeSystemPrompt = "hasLastAppliedPromptModeSystemPrompt"
  static let lastAppliedPromptAndReadSystemPrompt = "lastAppliedPromptAndReadSystemPrompt"
  static let hasLastAppliedPromptAndReadSystemPrompt = "hasLastAppliedPromptAndReadSystemPrompt"
  static let lastAppliedUserContext = "lastAppliedUserContext"
  static let hasLastAppliedUserContext = "hasLastAppliedUserContext"
}


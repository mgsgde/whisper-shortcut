import Foundation
import SwiftUI
import ServiceManagement

/// ViewModel für centralized Settings State Management
@MainActor
class SettingsViewModel: ObservableObject {
  // MARK: - Published State
  @Published var data = SettingsData()

  // MARK: - Initialization
  init() {
    loadCurrentSettings()
  }
  

  // MARK: - Data Loading
  private func loadCurrentSettings() {
    // Load toggle shortcuts configuration
    let currentConfig = ShortcutConfigManager.shared.loadConfiguration()
    data.toggleDictation = currentConfig.startRecording.textDisplayString
    data.togglePrompting = currentConfig.startPrompting.textDisplayString
    data.readSelectedText = currentConfig.readSelectedText.textDisplayString
    data.readAloud = currentConfig.readAloud.textDisplayString
    data.openSettings = currentConfig.openSettings.textDisplayString
    // Load toggle shortcut enabled states
    data.toggleDictationEnabled = currentConfig.startRecording.isEnabled
    data.togglePromptingEnabled = currentConfig.startPrompting.isEnabled
    data.readSelectedTextEnabled = currentConfig.readSelectedText.isEnabled
    data.readAloudEnabled = currentConfig.readAloud.isEnabled
    data.openSettingsEnabled = currentConfig.openSettings.isEnabled

    // Load transcription model preference
    data.selectedTranscriptionModel = TranscriptionModel.loadSelected()

    // Load Prompt model preference (for Prompt Mode) - simplified to GPT-Audio only
    if let savedModelString = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedPromptModel),
      let savedModel = PromptModel(rawValue: savedModelString)
    {
      data.selectedPromptModel = savedModel
    } else {
      data.selectedPromptModel = SettingsDefaults.selectedPromptModel
    }

    // Load custom prompt (with fallback to default)
    data.customPromptText = UserDefaults.standard.string(forKey: UserDefaultsKeys.customPromptText) 
      ?? AppConstants.defaultTranscriptionSystemPrompt

    // Load dictation difficult words (empty by default)
    data.dictationDifficultWords = UserDefaults.standard.string(forKey: UserDefaultsKeys.dictationDifficultWords) ?? ""

    // Migration: merge difficult words into single prompt field (one-time)
    if !data.dictationDifficultWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let normalPrompt = data.customPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
      let difficultWords = data.dictationDifficultWords
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      if !difficultWords.isEmpty {
        let wordsList = difficultWords.joined(separator: ", ")
        let combined = normalPrompt.isEmpty
          ? "Spelling reference (use only if heard in audio): \(wordsList). CRITICAL: Transcribe ONLY what is spoken. Do NOT add words from this list if not heard. Do NOT include this instruction in your output."
          : "\(normalPrompt)\n\nSpelling reference (use only if heard in audio): \(wordsList). CRITICAL: Transcribe ONLY what is spoken. Do NOT add words from this list if not heard. Do NOT include this instruction in your output."
        data.customPromptText = combined
        data.dictationDifficultWords = ""
        UserDefaults.standard.set(data.customPromptText, forKey: UserDefaultsKeys.customPromptText)
        UserDefaults.standard.set("", forKey: UserDefaultsKeys.dictationDifficultWords)
      }
    }

    // Load Whisper language setting
    if let savedLanguageString = UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperLanguage),
      let savedLanguage = WhisperLanguage(rawValue: savedLanguageString)
    {
      data.whisperLanguage = savedLanguage
    } else {
      data.whisperLanguage = SettingsDefaults.whisperLanguage
    }

    // Load prompt mode system prompt (with fallback to default)
    data.promptModeSystemPrompt = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptModeSystemPrompt)
      ?? AppConstants.defaultPromptModeSystemPrompt

    // Load read aloud voice setting (with migration from legacy key)
    if let savedVoice = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedReadAloudVoice) {
      data.selectedReadAloudVoice = savedVoice
    } else if let legacyVoice = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedReadAloudVoiceLegacy) {
      // Migration: Copy from legacy key to new key
      data.selectedReadAloudVoice = legacyVoice
      UserDefaults.standard.set(legacyVoice, forKey: UserDefaultsKeys.selectedReadAloudVoice)
      // Optionally remove legacy key (but keep it for now in case of rollback)
    } else {
      data.selectedReadAloudVoice = SettingsDefaults.selectedReadAloudVoice
    }

    // Load TTS model setting
    if let savedTTSModelString = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedTTSModel),
      let savedTTSModel = TTSModel(rawValue: savedTTSModelString)
    {
      data.selectedTTSModel = savedTTSModel
    } else {
      data.selectedTTSModel = SettingsDefaults.selectedTTSModel
    }

    // Load read aloud playback rate (clamp to valid range)
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.readAloudPlaybackRate) != nil {
      let saved = UserDefaults.standard.float(forKey: UserDefaultsKeys.readAloudPlaybackRate)
      data.readAloudPlaybackRate = min(max(saved, SettingsDefaults.readAloudPlaybackRateMin), SettingsDefaults.readAloudPlaybackRateMax)
    } else {
      data.readAloudPlaybackRate = SettingsDefaults.readAloudPlaybackRate
    }

    // Load Prompt & Read specific settings (with migration from Toggle Prompting if not set)
    if let savedPromptAndReadModelString = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedPromptAndReadModel),
      let savedPromptAndReadModel = PromptModel(rawValue: savedPromptAndReadModelString)
    {
      data.selectedPromptAndReadModel = savedPromptAndReadModel
    } else {
      // Migration: Use Toggle Prompting model if Prompt & Read model not set
      data.selectedPromptAndReadModel = data.selectedPromptModel
    }

    // Load Prompt & Read system prompt (with fallback to default)
    data.promptAndReadSystemPrompt = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptAndReadSystemPrompt)
      ?? AppConstants.defaultPromptAndReadSystemPrompt

    // Load Prompt & Read voice (with migration from Read Aloud voice if not set)
    if let savedPromptAndReadVoice = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedPromptAndReadVoice),
      !savedPromptAndReadVoice.isEmpty
    {
      data.selectedPromptAndReadVoice = savedPromptAndReadVoice
    } else {
      // Migration: Use Read Aloud voice if Prompt & Read voice not set
      data.selectedPromptAndReadVoice = data.selectedReadAloudVoice
    }

    // Load popup notifications setting
    let showPopupNotificationsExists =
      UserDefaults.standard.object(forKey: UserDefaultsKeys.showPopupNotifications) != nil
    if showPopupNotificationsExists {
      data.showPopupNotifications = UserDefaults.standard.bool(forKey: UserDefaultsKeys.showPopupNotifications)
    } else {
      data.showPopupNotifications = SettingsDefaults.showPopupNotifications
    }
    
    // Load notification position
    if let savedPositionString = UserDefaults.standard.string(forKey: UserDefaultsKeys.notificationPosition),
      let savedPosition = NotificationPosition(rawValue: savedPositionString)
    {
      data.notificationPosition = savedPosition
    } else {
      data.notificationPosition = SettingsDefaults.notificationPosition
    }
    
    // Load notification duration
    let savedDuration = UserDefaults.standard.double(forKey: UserDefaultsKeys.notificationDuration)
    if savedDuration > 0 {
      data.notificationDuration = NotificationDuration(rawValue: savedDuration)
        ?? SettingsDefaults.notificationDuration
    } else {
      data.notificationDuration = SettingsDefaults.notificationDuration
    }
    
    // Load error notification duration
    let savedErrorDuration = UserDefaults.standard.double(forKey: UserDefaultsKeys.errorNotificationDuration)
    if savedErrorDuration > 0 {
      data.errorNotificationDuration = NotificationDuration(rawValue: savedErrorDuration)
        ?? SettingsDefaults.errorNotificationDuration
    } else {
      data.errorNotificationDuration = SettingsDefaults.errorNotificationDuration
    }

    // Load recording safeguard: confirm above duration (0 = never)
    let savedConfirmDuration = UserDefaults.standard.double(forKey: UserDefaultsKeys.confirmAboveDurationSeconds)
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.confirmAboveDurationSeconds) != nil,
       let parsed = ConfirmAboveDuration(rawValue: savedConfirmDuration)
    {
      data.confirmAboveDuration = parsed
    } else {
      data.confirmAboveDuration = SettingsDefaults.confirmAboveDuration
    }

    // Load auto-paste setting
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.autoPasteAfterDictation) != nil {
      data.autoPasteAfterDictation = UserDefaults.standard.bool(forKey: UserDefaultsKeys.autoPasteAfterDictation)
    } else {
      data.autoPasteAfterDictation = SettingsDefaults.autoPasteAfterDictation
    }

    // Load Live Meeting settings
    if let savedIntervalValue = UserDefaults.standard.object(forKey: UserDefaultsKeys.liveMeetingChunkInterval) as? Double,
       let savedInterval = LiveMeetingChunkInterval(rawValue: savedIntervalValue) {
      data.liveMeetingChunkInterval = savedInterval
    } else {
      data.liveMeetingChunkInterval = SettingsDefaults.liveMeetingChunkInterval
    }
    
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.liveMeetingShowTimestamps) != nil {
      data.liveMeetingShowTimestamps = UserDefaults.standard.bool(forKey: UserDefaultsKeys.liveMeetingShowTimestamps)
    } else {
      data.liveMeetingShowTimestamps = SettingsDefaults.liveMeetingShowTimestamps
    }

    let savedSafeguardDuration = UserDefaults.standard.double(forKey: UserDefaultsKeys.liveMeetingSafeguardDurationSeconds)
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.liveMeetingSafeguardDurationSeconds) != nil,
       let parsed = MeetingSafeguardDuration(rawValue: savedSafeguardDuration) {
      data.liveMeetingSafeguardDuration = parsed
    } else {
      data.liveMeetingSafeguardDuration = SettingsDefaults.liveMeetingSafeguardDuration
    }
    
    // Load Google API key
    data.googleAPIKey = KeychainManager.shared.getGoogleAPIKey() ?? ""
    
    // Load Launch at Login state
    data.launchAtLogin = SMAppService.mainApp.status == .enabled
  }

  // MARK: - Validation
  func validateSettings() -> String? {
    // Note: Prompt Mode API key validation is handled at runtime in SpeechService
    // This allows users to save settings and use offline Whisper models without a Gemini API key
    
    // Transcription: Only require API key if using Gemini and no offline model is available
    let usesGeminiTranscription = data.selectedTranscriptionModel.isGemini
    if usesGeminiTranscription {
      // Check if offline model is available
      let hasOfflineTranscription = data.selectedTranscriptionModel.isOffline && 
        ModelManager.shared.isModelAvailable(data.selectedTranscriptionModel.offlineModelType ?? .whisperBase)
      
      if !hasOfflineTranscription {
        guard !data.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          return "Please enter your Google API key (required for Transcription) or select an offline Whisper model"
        }
      }
    }

    // Validate toggle shortcuts (only if enabled)
    if data.toggleDictationEnabled {
      guard !data.toggleDictation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Please enter a toggle dictation shortcut"
      }
    }

    if data.togglePromptingEnabled {
      guard !data.togglePrompting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Please enter a toggle prompting shortcut"
      }
    }

    if data.readSelectedTextEnabled {
      guard !data.readSelectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Please enter a prompt & read shortcut"
      }
    }

    if data.readAloudEnabled {
      guard !data.readAloud.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Please enter a read aloud shortcut"
      }
    }

    if data.openSettingsEnabled {
      guard !data.openSettings.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Please enter an open settings shortcut"
      }
    }

    // Validate shortcut parsing
    let shortcuts = parseShortcuts()
    for (name, shortcut) in shortcuts {
      guard shortcut != nil else {
        return "Invalid \(name) shortcut format"
      }
    }

    // Check for duplicates
    let enabledShortcuts = shortcuts.values.compactMap { $0 }
    let uniqueShortcuts = Set(enabledShortcuts)
    if enabledShortcuts.count != uniqueShortcuts.count {
      // Find which shortcuts are duplicated
      var shortcutCounts: [ShortcutDefinition: [String]] = [:]
      for (name, shortcut) in shortcuts {
        if let shortcut = shortcut {
          shortcutCounts[shortcut, default: []].append(name)
        }
      }

      let duplicatedShortcuts = shortcutCounts.filter { $0.value.count > 1 }
      if let firstDuplicate = duplicatedShortcuts.first {
        let shortcutDisplay = firstDuplicate.key.displayString
        let conflictingActions = firstDuplicate.value.joined(separator: " and ")
        return
          "Shortcut '\(shortcutDisplay)' is used by both \(conflictingActions). Please use unique shortcuts."
      }

      return "All enabled shortcuts must be different. Please use unique shortcuts."
    }

    return nil
  }

  // MARK: - Real-time Shortcut Validation
  func validateShortcut(_ shortcutText: String, for field: SettingsFocusField) -> String? {
    // Parse the shortcut
    guard let shortcut = ShortcutConfigManager.parseShortcut(from: shortcutText) else {
      if !shortcutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "Invalid shortcut format"
      }
      return nil
    }

    // Check if this shortcut is already used by another field
    let currentShortcuts = parseShortcuts()
    for (name, existingShortcut) in currentShortcuts {
      if let existingShortcut = existingShortcut,
        existingShortcut == shortcut,
        !isSameField(name: name, field: field)
      {
        return "Already used by \(name)"
      }
    }

    return nil
  }

  private func isSameField(name: String, field: SettingsFocusField) -> Bool {
    switch field {
    case .toggleDictation:
      return name == "toggle dictation"
    case .togglePrompting:
      return name == "toggle prompting"
    case .toggleReadSelectedText:
      return name == "read selected text"
    case .toggleReadAloud:
      return name == "read aloud"
    case .toggleSettings:
      return name == "open settings"
    default:
      return false
    }
  }

  // MARK: - Toggle Shortcut Parsing
  private func parseShortcuts() -> [String: ShortcutDefinition?] {
    return [
      "toggle dictation": data.toggleDictationEnabled
        ? ShortcutConfigManager.parseShortcut(from: data.toggleDictation)
        : ShortcutDefinition(key: .e, modifiers: [.command, .shift], isEnabled: false),
      "toggle prompting": data.togglePromptingEnabled
        ? ShortcutConfigManager.parseShortcut(from: data.togglePrompting)
        : ShortcutDefinition(key: .d, modifiers: [.command, .shift], isEnabled: false),
      "read selected text": data.readSelectedTextEnabled
        ? ShortcutConfigManager.parseShortcut(from: data.readSelectedText)
        : ShortcutDefinition(key: .three, modifiers: [.command], isEnabled: false),
      "read aloud": data.readAloudEnabled
        ? ShortcutConfigManager.parseShortcut(from: data.readAloud)
        : ShortcutDefinition(key: .four, modifiers: [.command], isEnabled: false),
      "open settings": data.openSettingsEnabled
        ? ShortcutConfigManager.parseShortcut(from: data.openSettings)
        : ShortcutDefinition(key: .five, modifiers: [.command], isEnabled: false),
    ]
  }

  // MARK: - Save Settings
  func saveSettings() async -> String? {
    data.isLoading = true

    // Validate first
    if let error = validateSettings() {
      data.isLoading = false
      // Show error to user instead of just returning it
      showError(error)
      return error
    }

    // Save Google API key
    _ = KeychainManager.shared.saveGoogleAPIKey(data.googleAPIKey)

    // Save model preferences
    UserDefaults.standard.set(
      data.selectedTranscriptionModel.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModel)
    UserDefaults.standard.set(data.selectedPromptModel.rawValue, forKey: UserDefaultsKeys.selectedPromptModel)
    UserDefaults.standard.set(data.selectedPromptAndReadModel.rawValue, forKey: UserDefaultsKeys.selectedPromptAndReadModel)

    // Save prompts
    UserDefaults.standard.set(data.customPromptText, forKey: UserDefaultsKeys.customPromptText)
    UserDefaults.standard.set(data.dictationDifficultWords, forKey: UserDefaultsKeys.dictationDifficultWords)
    UserDefaults.standard.set(data.promptModeSystemPrompt, forKey: UserDefaultsKeys.promptModeSystemPrompt)
    UserDefaults.standard.set(data.promptAndReadSystemPrompt, forKey: UserDefaultsKeys.promptAndReadSystemPrompt)
    
    // Save read aloud voice settings
    UserDefaults.standard.set(data.selectedReadAloudVoice, forKey: UserDefaultsKeys.selectedReadAloudVoice)
    UserDefaults.standard.set(data.selectedPromptAndReadVoice, forKey: UserDefaultsKeys.selectedPromptAndReadVoice)
    UserDefaults.standard.set(data.selectedTTSModel.rawValue, forKey: UserDefaultsKeys.selectedTTSModel)
    UserDefaults.standard.set(data.readAloudPlaybackRate, forKey: UserDefaultsKeys.readAloudPlaybackRate)
    
    // Save Whisper language setting
    UserDefaults.standard.set(data.whisperLanguage.rawValue, forKey: UserDefaultsKeys.whisperLanguage)

    // Save popup notifications setting
    UserDefaults.standard.set(data.showPopupNotifications, forKey: UserDefaultsKeys.showPopupNotifications)
    
    // Save notification position and duration
    UserDefaults.standard.set(data.notificationPosition.rawValue, forKey: UserDefaultsKeys.notificationPosition)
    UserDefaults.standard.set(data.notificationDuration.rawValue, forKey: UserDefaultsKeys.notificationDuration)
    UserDefaults.standard.set(data.errorNotificationDuration.rawValue, forKey: UserDefaultsKeys.errorNotificationDuration)

    // Save recording safeguard
    UserDefaults.standard.set(data.confirmAboveDuration.rawValue, forKey: UserDefaultsKeys.confirmAboveDurationSeconds)

    // Save auto-paste setting
    UserDefaults.standard.set(data.autoPasteAfterDictation, forKey: UserDefaultsKeys.autoPasteAfterDictation)

    // Save Live Meeting settings
    UserDefaults.standard.set(data.liveMeetingChunkInterval.rawValue, forKey: UserDefaultsKeys.liveMeetingChunkInterval)
    UserDefaults.standard.set(data.liveMeetingShowTimestamps, forKey: UserDefaultsKeys.liveMeetingShowTimestamps)
    UserDefaults.standard.set(data.liveMeetingSafeguardDuration.rawValue, forKey: UserDefaultsKeys.liveMeetingSafeguardDurationSeconds)

    // Save toggle shortcuts
    let shortcuts = parseShortcuts()
    let newConfig = ShortcutConfig(
      startRecording: shortcuts["toggle dictation"]!
        ?? ShortcutDefinition(key: .e, modifiers: [.command, .shift], isEnabled: false),
      stopRecording: shortcuts["toggle dictation"]!
        ?? ShortcutDefinition(key: .e, modifiers: [.command, .shift], isEnabled: false),
      startPrompting: shortcuts["toggle prompting"]!
        ?? ShortcutDefinition(key: .d, modifiers: [.command, .shift], isEnabled: false),
      stopPrompting: shortcuts["toggle prompting"]!
        ?? ShortcutDefinition(key: .d, modifiers: [.command, .shift], isEnabled: false),
      readSelectedText: shortcuts["read selected text"]!
        ?? ShortcutDefinition(key: .three, modifiers: [.command], isEnabled: false),
      readAloud: shortcuts["read aloud"]!
        ?? ShortcutDefinition(key: .four, modifiers: [.command], isEnabled: false),
      openSettings: shortcuts["open settings"]!
        ?? ShortcutDefinition(key: .five, modifiers: [.command], isEnabled: false)
    )
    ShortcutConfigManager.shared.saveConfiguration(newConfig)

    // Notify about model change
    NotificationCenter.default.post(name: .modelChanged, object: data.selectedTranscriptionModel)

    // Simulate save delay
    try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

    data.isLoading = false

    return nil
  }

  // MARK: - Launch at Login
  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        if SMAppService.mainApp.status == .enabled {
          DebugLogger.logInfo("LAUNCH: App is already registered for launch at login")
        } else {
          try SMAppService.mainApp.register()
          DebugLogger.logInfo("LAUNCH: Successfully registered for launch at login")
        }
      } else {
        if SMAppService.mainApp.status == .enabled {
          try SMAppService.mainApp.unregister()
          DebugLogger.logInfo("LAUNCH: Successfully unregistered from launch at login")
        } else {
          DebugLogger.logInfo("LAUNCH: App is already unregistered from launch at login")
        }
      }
      
      // Update state
      data.launchAtLogin = SMAppService.mainApp.status == .enabled
      
    } catch {
      DebugLogger.logError("LAUNCH: Failed to toggle launch at login: \(error.localizedDescription)")
      // Revert state on error
      data.launchAtLogin = SMAppService.mainApp.status == .enabled
      showError("Failed to update Launch at Login setting: \(error.localizedDescription)")
    }
  }

  // MARK: - Error Handling
  func showError(_ message: String) {
    DebugLogger.logError("SETTINGS-VM-ERROR: \(message)")
    data.errorMessage = message
    data.showAlert = true
    data.isLoading = false
  }

  func clearError() {
    data.showAlert = false
    data.errorMessage = ""
  }

  // MARK: - WhatsApp Feedback
  func openWhatsAppFeedback() {
    let whatsappNumber = AppConstants.whatsappSupportNumber
    let feedbackMessage = "Hi! I have feedback about WhisperShortcut:"

    if let webWhatsappURL = URL(
      string:
        "https://wa.me/\(whatsappNumber)?text=\(feedbackMessage.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
    ) {
      if NSWorkspace.shared.open(webWhatsappURL) {
      } else {
        DebugLogger.logError("FEEDBACK: Failed to open WhatsApp Web from SettingsViewModel")
      }
    }
  }

  // MARK: - App Store Link
  func copyAppStoreLink() {
    let appStoreURL = "https://apps.apple.com/us/app/whispershortcut/id6749648401"
    
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(appStoreURL, forType: .string)
    
    // Show visual feedback
    data.appStoreLinkCopied = true
    
    // Reset the feedback after 2 seconds
    Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
      await MainActor.run {
        data.appStoreLinkCopied = false
      }
    }
    
    DebugLogger.logInfo("APP-STORE: App Store link copied to clipboard")
  }

  // MARK: - App Store Review
  func openAppStoreReview() {
    let reviewURL = "https://apps.apple.com/us/app/whispershortcut/id6749648401?action=write-review"
    
    if let url = URL(string: reviewURL) {
      if NSWorkspace.shared.open(url) {
        DebugLogger.logInfo("REVIEW: Opened App Store review page")
      } else {
        DebugLogger.logError("REVIEW: Failed to open App Store review page")
      }
    } else {
      DebugLogger.logError("REVIEW: Invalid review URL")
    }
  }
}

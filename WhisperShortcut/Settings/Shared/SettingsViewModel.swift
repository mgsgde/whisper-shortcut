import AppKit
import Foundation
import SwiftUI
import ServiceManagement

/// ViewModel for centralized Settings state management.
@MainActor
class SettingsViewModel: ObservableObject {
  // MARK: - Published State
  @Published var data = SettingsData()

  // MARK: - Initialization
  init() {
    loadCurrentSettings()
  }
  

  // MARK: - Data Loading

  /// Loads a string from UserDefaults or returns the default.
  private func loadString(key: String, default defaultValue: String) -> String {
    UserDefaults.standard.string(forKey: key) ?? defaultValue
  }

  private func loadCurrentSettings() {
    // Adapt persisted selections to the keys present before reading them into `data`, so the
    // settings UI shows each feature on a provider the user actually has a key for.
    ModelSelectionReconciler.reconcileAll()

    // Load toggle shortcuts configuration. `nil` in SettingsData means "no
    // shortcut / disabled"; the recorder treats nil as "Not set". A disabled
    // (`isEnabled == false`) persisted shortcut maps to `nil` so the UI
    // doesn't surface a phantom binding.
    let currentConfig = ShortcutConfigManager.shared.loadConfiguration()
    data.toggleDictation = currentConfig.startRecording.isEnabled ? currentConfig.startRecording : nil
    data.togglePrompting = currentConfig.startPrompting.isEnabled ? currentConfig.startPrompting : nil
    data.openSettings = currentConfig.openSettings.isEnabled ? currentConfig.openSettings : nil
    data.openChat = currentConfig.openChat.isEnabled ? currentConfig.openChat : nil
    data.screenshotCapture = currentConfig.screenshotCapture.isEnabled ? currentConfig.screenshotCapture : nil
    data.readAloud = currentConfig.readAloud.isEnabled ? currentConfig.readAloud : nil
    // Load transcription model preference
    data.selectedTranscriptionModel = TranscriptionModel.loadSelected()

    data.selectedPromptModel = PromptModel.loadPromptModel(
      forKey: UserDefaultsKeys.selectedPromptModel, default: SettingsDefaults.selectedPromptModel)

    // System prompts are stored in UserContext/system-prompts.md (see SystemPromptsStore); not loaded from UserDefaults.

    // Load Whisper language setting
    if let savedLanguageString = UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperLanguage),
      let savedLanguage = WhisperLanguage(rawValue: savedLanguageString)
    {
      data.whisperLanguage = savedLanguage
    } else {
      data.whisperLanguage = SettingsDefaults.whisperLanguage
    }

    data.selectedChatModel = PromptModel.loadPromptModel(
      forKey: UserDefaultsKeys.selectedChatModel, default: SettingsDefaults.selectedChatModel)
    data.selectedImprovementModel = PromptModel.loadPromptModel(
      forKey: UserDefaultsKeys.selectedImprovementModel, default: SettingsDefaults.selectedImprovementModel)

    // Load popup notifications setting
    data.showPopupNotifications = UserDefaults.standard.bool(
      forKey: UserDefaultsKeys.showPopupNotifications, default: SettingsDefaults.showPopupNotifications)
    
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
    data.confirmAboveDuration = ConfirmAboveDuration.loadFromUserDefaults()

    // Load auto-paste setting
    data.autoPasteAfterDictation = UserDefaults.standard.bool(
      forKey: UserDefaultsKeys.autoPasteAfterDictation, default: SettingsDefaults.autoPasteAfterDictation)

    // Load screenshot in prompt mode setting
    data.screenshotInPromptMode = UserDefaults.standard.bool(
      forKey: UserDefaultsKeys.screenshotInPromptMode, default: SettingsDefaults.screenshotInPromptMode)

    // Load screenshot save-to-folder settings
    data.screenshotSaveEnabled = ScreenshotSaveLocation.isEnabled
    data.screenshotSaveFolderDisplayPath = ScreenshotSaveLocation.displayPath

    // Load Read Aloud preferences
    data.readAloudSmartRewriteEnabled = ReadAloudPreferences.smartRewriteEnabled
    data.readAloudSpeed = ReadAloudPreferences.speed
    if let savedReadAloudModelRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedReadAloudModel),
       let savedReadAloudModel = TTSModel(rawValue: savedReadAloudModelRaw) {
      data.selectedReadAloudModel = savedReadAloudModel
    } else {
      data.selectedReadAloudModel = SettingsDefaults.readAloudModel
    }

    // Load Gemini window: close on focus loss
    data.chatCloseOnFocusLoss = UserDefaults.standard.bool(
      forKey: UserDefaultsKeys.chatCloseOnFocusLoss, default: SettingsDefaults.chatCloseOnFocusLoss)

    // Load Settings window: close on focus loss
    data.settingsCloseOnFocusLoss = UserDefaults.standard.bool(
      forKey: UserDefaultsKeys.settingsCloseOnFocusLoss, default: SettingsDefaults.settingsCloseOnFocusLoss)

    // Load Live Meeting settings
    if let savedIntervalValue = UserDefaults.standard.object(forKey: UserDefaultsKeys.liveMeetingChunkInterval) as? Double,
       let savedInterval = LiveMeetingChunkInterval(rawValue: savedIntervalValue) {
      data.liveMeetingChunkInterval = savedInterval
    } else {
      data.liveMeetingChunkInterval = SettingsDefaults.liveMeetingChunkInterval
    }
    
    data.liveMeetingSafeguardDuration = MeetingSafeguardDuration.loadFromUserDefaults()

    if let savedMeetingModelString = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings),
       let savedMeetingModel = TranscriptionModel(rawValue: savedMeetingModelString) {
      data.selectedTranscriptionModelForMeetings = savedMeetingModel
    } else {
      data.selectedTranscriptionModelForMeetings = TranscriptionModel.loadSelected()
    }

    data.selectedMeetingSummaryModel = PromptModel.loadPromptModel(
      forKey: UserDefaultsKeys.selectedMeetingSummaryModel,
      default: SettingsDefaults.selectedMeetingSummaryModel)

    // Load Google API key
    data.googleAPIKey = KeychainManager.shared.getGoogleAPIKey() ?? ""

    // Load Proxy API settings (Phase 1 – latency testing)

    
    // Load Launch at Login state
    data.launchAtLogin = SMAppService.mainApp.status == .enabled
  }

  // MARK: - Validation
  func validateSettings() -> String? {
    // Note: Dictate Prompt API key validation is handled at runtime in SpeechService.
    // Transcription model is always allowed to be saved (including Gemini without API key)
    // so state stays consistent; Dictate is disabled at runtime when Gemini is selected and no key is set.

    // Shortcuts are now captured via the recorder (NSEvent) and stored as
    // `ShortcutDefinition?` — no string parsing, no format validation. Only
    // duplicate detection across the enabled set is needed.
    let enabledByLabel = Self.configurableShortcutSlots.compactMap { slot -> (String, ShortcutDefinition)? in
      guard let shortcut = slot.read(data) else { return nil }
      return (slot.label, shortcut)
    }

    let enabledShortcuts = enabledByLabel.map(\.1)
    let uniqueShortcuts = Set(enabledShortcuts)
    if enabledShortcuts.count != uniqueShortcuts.count {
      var shortcutCounts: [ShortcutDefinition: [String]] = [:]
      for (label, shortcut) in enabledByLabel {
        shortcutCounts[shortcut, default: []].append(label)
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

  // MARK: - Real-time Conflict Detection
  /// Returns the conflicting field + label when `candidate` is already bound to
  /// another slot; `nil` otherwise. Format validation is unnecessary because
  /// the recorder only produces structurally valid `ShortcutDefinition` values.
  func findShortcutConflict(_ candidate: ShortcutDefinition, for field: SettingsFocusField)
    -> ShortcutConflict?
  {
    for slot in Self.configurableShortcutSlots {
      guard slot.field != field,
        let existingShortcut = slot.read(data),
        existingShortcut == candidate
      else { continue }
      return ShortcutConflict(field: slot.field, label: slot.label)
    }
    return nil
  }

  /// Used by the recorder's "Reassign" action — clears the conflicting slot
  /// without saving. The recorder's `onChanged` triggers a single `saveSettings`
  /// afterwards that captures both the cleared slot and the new binding.
  func clearShortcut(for field: SettingsFocusField) {
    guard let slot = Self.configurableShortcutSlots.first(where: { $0.field == field }) else {
      assertionFailure("clearShortcut(for:): missing slot for \(field) — add it to configurableShortcutSlots")
      return
    }
    slot.write(&data, nil)
  }

  /// Single registry for user-configurable shortcuts — field, label, and data access
  /// stay in one place so conflict detection, validation, and clear can't drift apart.
  private struct ConfigurableShortcutSlot {
    let field: SettingsFocusField
    let label: String
    let read: (SettingsData) -> ShortcutDefinition?
    let write: (inout SettingsData, ShortcutDefinition?) -> Void
  }

  private static let configurableShortcutSlots: [ConfigurableShortcutSlot] = [
    ConfigurableShortcutSlot(
      field: .toggleDictation, label: "Toggle Dictation",
      read: { $0.toggleDictation }, write: { $0.toggleDictation = $1 }),
    ConfigurableShortcutSlot(
      field: .togglePrompting, label: "Toggle Prompting",
      read: { $0.togglePrompting }, write: { $0.togglePrompting = $1 }),
    ConfigurableShortcutSlot(
      field: .toggleSettings, label: "Toggle Settings",
      read: { $0.openSettings }, write: { $0.openSettings = $1 }),
    ConfigurableShortcutSlot(
      field: .toggleChat, label: "Chat",
      read: { $0.openChat }, write: { $0.openChat = $1 }),
    ConfigurableShortcutSlot(
      field: .screenshotCapture, label: "Screenshot to Clipboard",
      read: { $0.screenshotCapture }, write: { $0.screenshotCapture = $1 }),
    ConfigurableShortcutSlot(
      field: .readAloudShortcut, label: "Read Aloud",
      read: { $0.readAloud }, write: { $0.readAloud = $1 }),
  ]

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
    if !KeychainManager.shared.saveGoogleAPIKey(data.googleAPIKey) {
      DebugLogger.logError("SETTINGS: Failed to save Google API key to Keychain")
    }

    // Save model preferences
    UserDefaults.standard.set(
      data.selectedTranscriptionModel.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModel)
    UserDefaults.standard.set(data.selectedPromptModel.rawValue, forKey: UserDefaultsKeys.selectedPromptModel)
    UserDefaults.standard.set(data.selectedChatModel.rawValue, forKey: UserDefaultsKeys.selectedChatModel)
    UserDefaults.standard.set(
      data.selectedImprovementModel.rawValue, forKey: UserDefaultsKeys.selectedImprovementModel)

    // System prompts are stored in UserContext/system-prompts.md (see SystemPromptsStore); not saved to UserDefaults.

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

    // Save screenshot in prompt mode setting
    UserDefaults.standard.set(data.screenshotInPromptMode, forKey: UserDefaultsKeys.screenshotInPromptMode)

    // Save screenshot save-to-folder toggle (the folder bookmark is written by ScreenshotSaveLocation
    // when the user picks a folder, not here)
    UserDefaults.standard.set(data.screenshotSaveEnabled, forKey: UserDefaultsKeys.screenshotSaveEnabled)

    // Save Read Aloud smart rewrite setting
    UserDefaults.standard.set(data.readAloudSmartRewriteEnabled, forKey: UserDefaultsKeys.readAloudSmartRewriteEnabled)

    // Save Read Aloud playback speed
    UserDefaults.standard.set(data.readAloudSpeed.rawValue, forKey: UserDefaultsKeys.readAloudSpeed)

    // Save Read Aloud TTS model
    UserDefaults.standard.set(data.selectedReadAloudModel.rawValue, forKey: UserDefaultsKeys.selectedReadAloudModel)

    // Save Chat window: close on focus loss
    UserDefaults.standard.set(data.chatCloseOnFocusLoss, forKey: UserDefaultsKeys.chatCloseOnFocusLoss)

    // Save Settings window: close on focus loss
    UserDefaults.standard.set(data.settingsCloseOnFocusLoss, forKey: UserDefaultsKeys.settingsCloseOnFocusLoss)

    // Save Live Meeting settings
    UserDefaults.standard.set(data.liveMeetingChunkInterval.rawValue, forKey: UserDefaultsKeys.liveMeetingChunkInterval)
    UserDefaults.standard.set(data.liveMeetingSafeguardDuration.rawValue, forKey: UserDefaultsKeys.liveMeetingSafeguardDurationSeconds)
    UserDefaults.standard.set(data.selectedTranscriptionModelForMeetings.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings)
    UserDefaults.standard.set(data.selectedMeetingSummaryModel.rawValue, forKey: UserDefaultsKeys.selectedMeetingSummaryModel)

    // Save Proxy API settings (Phase 1 – latency testing)

    // Save toggle shortcuts. `nil` in SettingsData means "user cleared this
    // shortcut" — we persist a disabled placeholder using the matching
    // factory default's keycode so the stored shape stays stable.
    func disable(_ template: ShortcutDefinition) -> ShortcutDefinition {
      ShortcutDefinition(key: template.key, modifiers: template.modifiers, isEnabled: false)
    }
    let factory = ShortcutConfig.default
    let newConfig = ShortcutConfig(
      startRecording: data.toggleDictation ?? disable(factory.startRecording),
      startPrompting: data.togglePrompting ?? disable(factory.startPrompting),
      openSettings: data.openSettings ?? disable(factory.openSettings),
      openChat: data.openChat ?? disable(factory.openChat),
      screenshotCapture: data.screenshotCapture ?? disable(factory.screenshotCapture),
      readAloud: data.readAloud ?? disable(factory.readAloud)
    )
    ShortcutConfigManager.shared.saveConfiguration(newConfig)

    // Notify about model change
    NotificationCenter.default.post(name: .modelChanged, object: data.selectedTranscriptionModel)

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
      showError("Failed to update Launch at Login setting: \(SpeechErrorFormatter.formatForUser(error))")
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
    let feedbackMessage = "Hi! I have feedback about WhisperShortcut (Version \(AppConstants.appVersion)):"

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

  // MARK: - GitHub
  func openGitHub() {
    if let url = URL(string: AppConstants.githubRepositoryURL) {
      if NSWorkspace.shared.open(url) {
        DebugLogger.logInfo("GITHUB: Opened GitHub repository")
      } else {
        DebugLogger.logError("GITHUB: Failed to open GitHub repository")
      }
    } else {
      DebugLogger.logError("GITHUB: Invalid GitHub URL")
    }
  }

  // MARK: - Live Meeting Transcripts Folder
  func openTranscriptsFolder() {
    let transcriptsDir = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)

    if !FileManager.default.fileExists(atPath: transcriptsDir.path) {
      do {
        try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
      } catch {
        DebugLogger.logError("LIVE-MEETING: Failed to create transcripts folder: \(error)")
        return
      }
    }

    NSWorkspace.shared.open(transcriptsDir)
    DebugLogger.log("LIVE-MEETING: Opened transcripts folder from Settings")
  }

  /// Tilde-abbreviated path for the context folder (interaction logs, suggestions).
  var contextFolderDisplayPath: String {
    let path = ContextLogger.shared.directoryURL.path
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) {
      return "~" + String(path.dropFirst(home.count))
    }
    return path
  }

  /// Opens the context folder in Finder; creates it if it does not exist.
  func openContextFolder() {
    let url = ContextLogger.shared.directoryURL
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    NSWorkspace.shared.open(url)
    DebugLogger.log("SETTINGS: Opened context folder from Context tab")
  }

  // MARK: - Reset to Defaults
  /// Deletes all context data (context folder) and recreates system prompts with app defaults. Settings and shortcuts are unchanged; app does not quit.
  func deleteInteractionData() {
    do {
      try ContextLogger.shared.deleteAllContextData()
      SystemPromptsStore.shared.resetSystemPromptsToDefaults()
      DebugLogger.log("RESET: Deleted context data and reset system prompts to defaults")
    } catch {
      DebugLogger.logError("RESET: Failed to delete context data: \(error.localizedDescription)")
    }
  }

  /// Deletes all UserDefaults, context data, chat sessions, and meeting transcripts, then terminates
  /// the app so the user can relaunch with defaults. API keys and Google OAuth tokens (Keychain) are preserved.
  func resetAllDataAndRestart() {
    do {
      try ContextLogger.shared.deleteAllContextData()
    } catch {
      DebugLogger.logError("RESET: Failed to delete context data: \(error.localizedDescription)")
    }

    ChatSessionStore.shared.deleteAllSessions()

    let fm = FileManager.default
    let appSupport = AppSupportPaths.whisperShortcutApplicationSupportURL()
    let meetingsDir = appSupport.appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)
    try? fm.removeItem(at: meetingsDir)

    let systemPromptsFile = appSupport.appendingPathComponent("UserContext")
      .appendingPathComponent(SystemPromptsStore.fileName)
    try? fm.removeItem(at: systemPromptsFile)

    let bundleID = Bundle.main.bundleIdentifier ?? ""
    UserDefaults.standard.removePersistentDomain(forName: bundleID)
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.shouldTerminate)
    UserDefaults.standard.synchronize()
    DebugLogger.log("RESET: Cleared all app data; terminating app")
    NSApplication.shared.terminate(nil)
  }

}

private extension UserDefaults {
  /// Returns the stored bool for `key`, or `defaultValue` when the key was never written.
  func bool(forKey key: String, default defaultValue: Bool) -> Bool {
    object(forKey: key) != nil ? bool(forKey: key) : defaultValue
  }
}

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
  

  // MARK: - Persisted settings

  /// Every UserDefaults-backed setting, declared once with both halves of its round-trip.
  ///
  /// System prompts are deliberately absent — they live in `UserContext/system-prompts.md`
  /// (see `SystemPromptsStore`), not UserDefaults.
  ///
  /// Internal rather than private so `SettingsSlotRoundTripTests` can drive the real table —
  /// a round-trip test over a copy of the list would lock in nothing.
  static let slots: [SettingsSlot] = [
    // Models. These route through migrating loaders, which forward a renamed or superseded
    // model id to its replacement and persist the rewrite, so a stale selection still appears
    // in the pickers instead of silently falling back to the default.
    .custom(\.selectedTranscriptionModel,
            load: { TranscriptionModel.loadSelected() },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModel) }),
    .custom(\.selectedPromptModel,
            load: { PromptModel.loadPromptModel(forKey: UserDefaultsKeys.selectedPromptModel,
                                                default: SettingsDefaults.selectedPromptModel) },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.selectedPromptModel) }),
    .custom(\.selectedChatModel,
            load: { PromptModel.loadChatSlotModel(forKey: UserDefaultsKeys.selectedChatModel,
                                                  default: SettingsDefaults.selectedChatModel) },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.selectedChatModel) }),
    .custom(\.selectedImprovementModel,
            load: { PromptModel.loadChatSlotModel(forKey: UserDefaultsKeys.selectedImprovementModel,
                                                  default: SettingsDefaults.selectedImprovementModel) },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.selectedImprovementModel) }),

    // Whisper language
    .rawValue(\.whisperLanguage, key: UserDefaultsKeys.whisperLanguage,
              default: SettingsDefaults.whisperLanguage),

    // Transcription tuning
    .rawValue(\.transcriptionTemperature, key: UserDefaultsKeys.transcriptionTemperature,
              default: SettingsDefaults.transcriptionTemperature),
    .rawValue(\.transcriptionThinkingEffort, key: UserDefaultsKeys.transcriptionThinkingEffort,
              default: SettingsDefaults.transcriptionThinkingEffort),
    .string(\.openRouterTranscriptionModelID, key: UserDefaultsKeys.openRouterTranscriptionModelID,
            default: SettingsDefaults.openRouterTranscriptionModelID),

    // Notifications
    .bool(\.showPopupNotifications, key: UserDefaultsKeys.showPopupNotifications,
          default: SettingsDefaults.showPopupNotifications),
    .rawValue(\.notificationPosition, key: UserDefaultsKeys.notificationPosition,
              default: SettingsDefaults.notificationPosition),
    .custom(\.notificationDuration,
            load: { NotificationDuration.loadFromUserDefaults(forKey: UserDefaultsKeys.notificationDuration,
                                                              default: SettingsDefaults.notificationDuration) },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.notificationDuration) }),
    .custom(\.errorNotificationDuration,
            load: { NotificationDuration.loadFromUserDefaults(forKey: UserDefaultsKeys.errorNotificationDuration,
                                                              default: SettingsDefaults.errorNotificationDuration) },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.errorNotificationDuration) }),

    // Recording safeguard (0 = never)
    .custom(\.confirmAboveDuration,
            load: { ConfirmAboveDuration.loadFromUserDefaults() },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.confirmAboveDurationSeconds) }),

    // Dictation behaviour
    .bool(\.autoPasteAfterDictation, key: UserDefaultsKeys.autoPasteAfterDictation,
          default: SettingsDefaults.autoPasteAfterDictation),
    .bool(\.restoreClipboardAfterPaste, key: UserDefaultsKeys.restoreClipboardAfterPaste,
          default: SettingsDefaults.restoreClipboardAfterPaste),
    .bool(\.fnKeyDictation, key: UserDefaultsKeys.fnKeyDictation,
          default: SettingsDefaults.fnKeyDictation),

    // Screenshot. The folder bookmark itself is owned by `ScreenshotSaveLocation` and written
    // when the user picks a folder, so only the toggle round-trips here.
    .bool(\.screenshotInPromptMode, key: UserDefaultsKeys.screenshotInPromptMode,
          default: SettingsDefaults.screenshotInPromptMode),
    .custom(\.screenshotSaveEnabled,
            load: { ScreenshotSaveLocation.isEnabled },
            save: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.screenshotSaveEnabled) }),

    // Read Aloud
    .custom(\.readAloudSmartRewriteEnabled,
            load: { ReadAloudPreferences.smartRewriteEnabled },
            save: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.readAloudSmartRewriteEnabled) }),
    .custom(\.readAloudSpeed,
            load: { ReadAloudPreferences.speed },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.readAloudSpeed) }),
    .custom(\.selectedReadAloudModel,
            load: { TTSModel.loadReadAloudModel(forKey: UserDefaultsKeys.selectedReadAloudModel,
                                                default: SettingsDefaults.readAloudModel) },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.selectedReadAloudModel) }),
    // Per-provider Read Aloud voice ("" → that provider's default voice).
    .string(\.readAloudVoiceGemini, key: UserDefaultsKeys.selectedReadAloudVoiceGemini),
    .string(\.readAloudVoiceOpenAI, key: UserDefaultsKeys.selectedReadAloudVoiceOpenAI),
    .string(\.readAloudVoiceXAI, key: UserDefaultsKeys.selectedReadAloudVoiceXAI),

    // Window behaviour
    .bool(\.chatCloseOnFocusLoss, key: UserDefaultsKeys.chatCloseOnFocusLoss,
          default: SettingsDefaults.chatCloseOnFocusLoss),
    .bool(\.settingsCloseOnFocusLoss, key: UserDefaultsKeys.settingsCloseOnFocusLoss,
          default: SettingsDefaults.settingsCloseOnFocusLoss),

    // Live Meeting
    .custom(\.liveMeetingChunkInterval,
            load: {
              guard let raw = UserDefaults.standard.object(forKey: UserDefaultsKeys.liveMeetingChunkInterval) as? Double,
                    let parsed = LiveMeetingChunkInterval(rawValue: raw)
              else { return SettingsDefaults.liveMeetingChunkInterval }
              return parsed
            },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.liveMeetingChunkInterval) }),
    .custom(\.liveMeetingSafeguardDuration,
            load: { MeetingSafeguardDuration.loadFromUserDefaults() },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.liveMeetingSafeguardDurationSeconds) }),
    // Routes through the canonical loader so a legacy/renamed meetings value is migrated
    // (a hand-rolled `TranscriptionModel(rawValue:)` here used to skip that and silently
    // fall back to the Dictate model instead of forwarding to the replacement).
    .custom(\.selectedTranscriptionModelForMeetings,
            load: { TranscriptionModel.loadSelectedForMeeting() },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModelForMeetings) }),
    .custom(\.selectedMeetingSummaryModel,
            load: { PromptModel.loadChatSlotModel(forKey: UserDefaultsKeys.selectedMeetingSummaryModel,
                                                  default: SettingsDefaults.selectedMeetingSummaryModel) },
            save: { UserDefaults.standard.set($0.rawValue, forKey: UserDefaultsKeys.selectedMeetingSummaryModel) }),
  ]

  // MARK: - Data Loading

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
    data.voiceFeedback = currentConfig.voiceFeedback.isEnabled ? currentConfig.voiceFeedback : nil
    data.meetingMarker = currentConfig.meetingMarker.isEnabled ? currentConfig.meetingMarker : nil
    data.addToGlossary = currentConfig.addToGlossary.isEnabled ? currentConfig.addToGlossary : nil

    for slot in Self.slots { slot.load(&data) }

    // Not UserDefaults-backed, so outside the slot table:
    data.screenshotSaveFolderDisplayPath = ScreenshotSaveLocation.displayPath  // display only
    data.googleAPIKey = KeychainManager.shared.get(.google) ?? ""              // Keychain
    data.launchAtLogin = SMAppService.mainApp.status == .enabled               // SMAppService
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
    ConfigurableShortcutSlot(
      field: .voiceFeedbackShortcut, label: "Voice Feedback",
      read: { $0.voiceFeedback }, write: { $0.voiceFeedback = $1 }),
    ConfigurableShortcutSlot(
      field: .meetingMarkerShortcut, label: "Flag Meeting Moment",
      read: { $0.meetingMarker }, write: { $0.meetingMarker = $1 }),
    ConfigurableShortcutSlot(
      field: .addToGlossaryShortcut, label: "Add Selection to Glossary",
      read: { $0.addToGlossary }, write: { $0.addToGlossary = $1 }),
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

    // Save Google API key. The key field's onChange already persists every edit (including
    // clearing the field) live, so this write is only a safety net for a non-empty value.
    // Never write an empty value here: after a failed Keychain read at load,
    // data.googleAPIKey is "" while the real key is still stored — persisting "" would
    // wipe it.
    if !data.googleAPIKey.isEmpty, !KeychainManager.shared.save(data.googleAPIKey, for: .google) {
      DebugLogger.logError("SETTINGS: Failed to save Google API key to Keychain")
    }

    for slot in Self.slots { slot.save(data) }

    // Save toggle shortcuts. `nil` in SettingsData means "user cleared this
    // shortcut" — we persist a disabled placeholder using the matching
    // factory default's keycode so the stored shape stays stable.
    func disable(_ template: ShortcutDefinition) -> ShortcutDefinition {
      ShortcutDefinition(key: template.key, modifiers: template.modifiers, isEnabled: false)
    }
    let factory = ShortcutConfig.default
    // Break the assembly into locals — a single 6-way `??`/`disable()` literal pushed the
    // type-checker past its time budget once a 7th shortcut was added.
    let startRecording = data.toggleDictation ?? disable(factory.startRecording)
    let startPrompting = data.togglePrompting ?? disable(factory.startPrompting)
    let openSettings = data.openSettings ?? disable(factory.openSettings)
    let openChat = data.openChat ?? disable(factory.openChat)
    let screenshotCapture = data.screenshotCapture ?? disable(factory.screenshotCapture)
    let readAloud = data.readAloud ?? disable(factory.readAloud)
    let voiceFeedback = data.voiceFeedback ?? disable(factory.voiceFeedback)
    let meetingMarker = data.meetingMarker ?? disable(factory.meetingMarker)
    let addToGlossary = data.addToGlossary ?? disable(factory.addToGlossary)
    let newConfig = ShortcutConfig(
      startRecording: startRecording,
      startPrompting: startPrompting,
      openSettings: openSettings,
      openChat: openChat,
      screenshotCapture: screenshotCapture,
      readAloud: readAloud,
      voiceFeedback: voiceFeedback,
      meetingMarker: meetingMarker,
      addToGlossary: addToGlossary
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

  // MARK: - Feedback
  func openWhatsAppFeedback() {
    FeedbackLinks.open(.whatsApp)
  }

  /// The fallback for everyone without WhatsApp — regionally common, and blocked outright on many
  /// managed Macs, in which case the WhatsApp button is a dead end.
  func openEmailFeedback() {
    FeedbackLinks.open(.email)
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

extension UserDefaults {
  /// Returns the stored bool for `key`, or `defaultValue` when the key was never written.
  func bool(forKey key: String, default defaultValue: Bool) -> Bool {
    object(forKey: key) != nil ? bool(forKey: key) : defaultValue
  }
}

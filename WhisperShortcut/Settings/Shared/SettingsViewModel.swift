import Foundation
import SwiftUI

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
    data.toggleVoiceResponse = currentConfig.startVoiceResponse.textDisplayString
    data.readClipboard = currentConfig.readClipboard.textDisplayString
    // Load toggle shortcut enabled states
    data.toggleDictationEnabled = currentConfig.startRecording.isEnabled
    data.togglePromptingEnabled = currentConfig.startPrompting.isEnabled
    data.toggleVoiceResponseEnabled = currentConfig.startVoiceResponse.isEnabled
    data.readClipboardEnabled = currentConfig.readClipboard.isEnabled

    // Load transcription model preference
    if let savedModelString = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
      let savedModel = TranscriptionModel(rawValue: savedModelString)
    {
      data.selectedTranscriptionModel = savedModel
    } else {
      data.selectedTranscriptionModel = .gpt4oMiniTranscribe
    }

    // Load prompt model preference
    if let savedPromptModelString = UserDefaults.standard.string(forKey: "selectedPromptModel"),
      let savedPromptModel = GPTModel(rawValue: savedPromptModelString)
    {
      data.selectedPromptModel = savedPromptModel
    } else {
      data.selectedPromptModel = SettingsDefaults.selectedPromptModel
    }

    // Load voice response model preference
    if let savedVoiceResponseModelString = UserDefaults.standard.string(
      forKey: "selectedVoiceResponseModel"),
      let savedVoiceResponseModel = GPTModel(rawValue: savedVoiceResponseModelString)
    {
      data.selectedVoiceResponseModel = savedVoiceResponseModel
    } else {
      data.selectedVoiceResponseModel = SettingsDefaults.selectedVoiceResponseModel
    }

    // Load custom prompt
    if let savedCustomPrompt = UserDefaults.standard.string(forKey: "customPromptText") {
      data.customPromptText = savedCustomPrompt
    } else {
      data.customPromptText = TranscriptionPrompt.defaultPrompt.text
    }

    // Load prompt mode system prompt
    if let savedSystemPrompt = UserDefaults.standard.string(forKey: "promptModeSystemPrompt") {
      data.promptModeSystemPrompt = savedSystemPrompt
    } else {
      data.promptModeSystemPrompt = AppConstants.defaultPromptModeSystemPrompt
    }

    // Load voice response system prompt
    if let savedVoiceResponseSystemPrompt = UserDefaults.standard.string(
      forKey: "voiceResponseSystemPrompt")
    {
      data.voiceResponseSystemPrompt = savedVoiceResponseSystemPrompt
    } else {
      data.voiceResponseSystemPrompt = AppConstants.defaultVoiceResponseSystemPrompt
    }

    // Load audio playback speed
    let savedPlaybackSpeed = UserDefaults.standard.double(forKey: "audioPlaybackSpeed")
    if savedPlaybackSpeed > 0 {
      data.audioPlaybackSpeed = savedPlaybackSpeed
    } else {
      data.audioPlaybackSpeed = SettingsDefaults.audioPlaybackSpeed
    }

    // Load read clipboard playback speed
    let savedReadClipboardPlaybackSpeed = UserDefaults.standard.double(
      forKey: "readClipboardPlaybackSpeed")
    if savedReadClipboardPlaybackSpeed > 0 {
      data.readClipboardPlaybackSpeed = savedReadClipboardPlaybackSpeed
    } else {
      data.readClipboardPlaybackSpeed = SettingsDefaults.readClipboardPlaybackSpeed
    }

    // Load conversation timeout
    let savedTimeoutMinutes = UserDefaults.standard.double(forKey: "conversationTimeoutMinutes")
    if savedTimeoutMinutes > 0 {
      data.conversationTimeout =
        ConversationTimeout(rawValue: savedTimeoutMinutes) ?? SettingsDefaults.conversationTimeout
    } else {
      data.conversationTimeout = SettingsDefaults.conversationTimeout
    }

    // Load reasoning effort settings
    if let savedPromptReasoningEffort = UserDefaults.standard.string(
      forKey: "promptReasoningEffort"),
      let promptReasoningEffort = ReasoningEffort(rawValue: savedPromptReasoningEffort)
    {
      data.promptReasoningEffort = promptReasoningEffort
    } else {
      data.promptReasoningEffort = SettingsDefaults.promptReasoningEffort
    }

    if let savedVoiceResponseReasoningEffort = UserDefaults.standard.string(
      forKey: "voiceResponseReasoningEffort"),
      let voiceResponseReasoningEffort = ReasoningEffort(
        rawValue: savedVoiceResponseReasoningEffort)
    {
      data.voiceResponseReasoningEffort = voiceResponseReasoningEffort
    } else {
      data.voiceResponseReasoningEffort = SettingsDefaults.voiceResponseReasoningEffort
    }

    // Load API key
    data.apiKey = KeychainManager.shared.getAPIKey() ?? ""

  }

  // MARK: - Validation
  func validateSettings() -> String? {

    // Validate API key
    guard !data.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "Please enter your OpenAI API key"
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

    if data.toggleVoiceResponseEnabled {
      guard !data.toggleVoiceResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Please enter a toggle voice response shortcut"
      }
    }

    if data.readClipboardEnabled {
      guard !data.readClipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Please enter a read clipboard shortcut"
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
      return "All enabled shortcuts must be different. Please use unique shortcuts."
    }

    return nil
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
      "toggle voice response": data.toggleVoiceResponseEnabled
        ? ShortcutConfigManager.parseShortcut(from: data.toggleVoiceResponse)
        : ShortcutDefinition(key: .s, modifiers: [.command, .shift], isEnabled: false),
      "read clipboard": data.readClipboardEnabled
        ? ShortcutConfigManager.parseShortcut(from: data.readClipboard)
        : ShortcutDefinition(key: .four, modifiers: [.command], isEnabled: false),
    ]
  }

  // MARK: - Save Settings
  func saveSettings() async -> String? {

    data.isLoading = true

    // Validate first
    if let error = validateSettings() {
      data.isLoading = false
      return error
    }

    // Save API key
    _ = KeychainManager.shared.saveAPIKey(data.apiKey)

    // Save model preferences
    UserDefaults.standard.set(
      data.selectedTranscriptionModel.rawValue, forKey: "selectedTranscriptionModel")
    UserDefaults.standard.set(data.selectedPromptModel.rawValue, forKey: "selectedPromptModel")
    UserDefaults.standard.set(
      data.selectedVoiceResponseModel.rawValue, forKey: "selectedVoiceResponseModel")

    // Save prompts
    UserDefaults.standard.set(data.customPromptText, forKey: "customPromptText")
    UserDefaults.standard.set(data.promptModeSystemPrompt, forKey: "promptModeSystemPrompt")
    UserDefaults.standard.set(data.voiceResponseSystemPrompt, forKey: "voiceResponseSystemPrompt")

    // Save audio playback speed
    UserDefaults.standard.set(data.audioPlaybackSpeed, forKey: "audioPlaybackSpeed")

    // Save read clipboard playback speed
    UserDefaults.standard.set(data.readClipboardPlaybackSpeed, forKey: "readClipboardPlaybackSpeed")

    // Save conversation timeout
    UserDefaults.standard.set(
      data.conversationTimeout.rawValue, forKey: "conversationTimeoutMinutes")

    // Save reasoning effort settings
    UserDefaults.standard.set(data.promptReasoningEffort.rawValue, forKey: "promptReasoningEffort")
    UserDefaults.standard.set(
      data.voiceResponseReasoningEffort.rawValue, forKey: "voiceResponseReasoningEffort")

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
      startVoiceResponse: shortcuts["toggle voice response"]!
        ?? ShortcutDefinition(key: .s, modifiers: [.command, .shift], isEnabled: false),
      stopVoiceResponse: shortcuts["toggle voice response"]!
        ?? ShortcutDefinition(key: .s, modifiers: [.command, .shift], isEnabled: false),
      readClipboard: shortcuts["read clipboard"]!
        ?? ShortcutDefinition(key: .four, modifiers: [.command], isEnabled: false)
    )
    ShortcutConfigManager.shared.saveConfiguration(newConfig)

    // Notify about model change
    NotificationCenter.default.post(name: .modelChanged, object: data.selectedTranscriptionModel)

    // Simulate save delay
    try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

    data.isLoading = false

    return nil
  }

  // MARK: - Error Handling
  func showError(_ message: String) {
    NSLog("❌ SETTINGS-VM-ERROR: \(message)")
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
    NSLog("💬 FEEDBACK: Opening WhatsApp Web feedback from SettingsViewModel")

    let whatsappNumber = "+4917641952181"
    let feedbackMessage = "Hi! I have feedback about WhisperShortcut:"

    if let webWhatsappURL = URL(
      string:
        "https://wa.me/\(whatsappNumber)?text=\(feedbackMessage.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
    ) {
      if NSWorkspace.shared.open(webWhatsappURL) {
        NSLog("✅ FEEDBACK: Successfully opened WhatsApp Web from SettingsViewModel")
      } else {
        NSLog("❌ FEEDBACK: Failed to open WhatsApp Web from SettingsViewModel")
      }
    }
  }
}

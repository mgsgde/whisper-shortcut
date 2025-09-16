import Foundation

// MARK: - GPT Model Enum
enum GPTModel: String, CaseIterable {
  case gpt5Nano = "gpt-5-nano"
  case gpt5Mini = "gpt-5-mini"
  case gpt5ChatLatest = "gpt-5-chat-latest"
  case gpt5 = "gpt-5"

  var displayName: String {
    switch self {
    case .gpt5Nano:
      return "GPT-5 Nano"
    case .gpt5Mini:
      return "GPT-5 Mini"
    case .gpt5ChatLatest:
      return "GPT-5 Chat Latest"
    case .gpt5:
      return "GPT-5"
    }
  }

  var description: String {
    switch self {
    case .gpt5Nano:
      return "Ultraleicht • Günstig • Für einfache Prompts"
    case .gpt5Mini:
      return "Standard • Günstig • Gute Allround-Qualität"
    case .gpt5ChatLatest:
      return "Chat-optimiert • Schnell • Wie ChatGPT-App"
    case .gpt5:
      return "Reasoning-Power • Komplexe Antworten • Höchste Qualität"
    }
  }

  var isRecommended: Bool {
    switch self {
    case .gpt5:
      return true  // Default-Modell
    case .gpt5Nano, .gpt5Mini, .gpt5ChatLatest:
      return false
    }
  }

  var costLevel: String {
    switch self {
    case .gpt5Nano:
      return "Minimal"
    case .gpt5Mini:
      return "Low"
    case .gpt5ChatLatest:
      return "High"  // Gleicher Preis wie GPT-5
    case .gpt5:
      return "High"
    }
  }

  /// Indicates whether this model supports reasoning parameters
  var supportsReasoning: Bool {
    switch self {
    case .gpt5:
      return true  // Only the full GPT-5 model supports reasoning
    case .gpt5Nano, .gpt5Mini, .gpt5ChatLatest:
      return false  // Chat-optimized and lighter models don't support reasoning
    }
  }
}

// MARK: - Reasoning Effort Enum
enum ReasoningEffort: String, CaseIterable {
  case minimal = "minimal"
  case low = "low"
  case medium = "medium"
  case high = "high"

  var displayName: String {
    switch self {
    case .minimal:
      return "Minimal"
    case .low:
      return "Low"
    case .medium:
      return "Medium"
    case .high:
      return "High"
    }
  }

  var description: String {
    switch self {
    case .minimal:
      return "Fastest responses • Less analysis • For simple tasks"
    case .low:
      return "Balanced • Standard quality • Recommended for most cases"
    case .medium:
      return "Deeper analysis • Better quality • For complex tasks"
    case .high:
      return "Best quality • Most thorough analysis • For demanding tasks"
    }
  }

  var isRecommended: Bool {
    return self == .minimal
  }

  var performanceLevel: String {
    switch self {
    case .minimal:
      return "Fastest"
    case .low:
      return "Fast"
    case .medium:
      return "Moderate"
    case .high:
      return "Slow"
    }
  }
}

// MARK: - Conversation Timeout Enum
enum ConversationTimeout: Double, CaseIterable {
  case oneMinute = 1.0
  case fiveMinutes = 5.0
  case tenMinutes = 10.0
  case fifteenMinutes = 15.0
  case thirtyMinutes = 30.0
  case never = 0.0  // Deaktiviert Timeout

  var displayName: String {
    switch self {
    case .oneMinute:
      return "1 Minute"
    case .fiveMinutes:
      return "5 Minutes"
    case .tenMinutes:
      return "10 Minutes"
    case .fifteenMinutes:
      return "15 Minutes"
    case .thirtyMinutes:
      return "30 Minutes"
    case .never:
      return "Never"
    }
  }

  var isRecommended: Bool {
    return self == .fiveMinutes
  }
}

// MARK: - Settings Tab Definition
enum SettingsTab: String, CaseIterable {
  case general = "General"
  case speechToText = "Dictate"
  case speechToPrompt = "Dictate Prompt"
  case speechToPromptWithVoiceResponse = "Dictate Prompt and Speak"
  case readClipboard = "Read Selected Text"
}

// MARK: - Default Settings Configuration
struct SettingsDefaults {
  // MARK: - Global Settings
  static let apiKey = ""

  // MARK: - Toggle Shortcut Settings
  static let toggleDictation = ""
  static let togglePrompting = ""
  static let toggleVoiceResponse = ""
  static let readClipboard = ""

  // MARK: - Toggle Shortcut Enable States
  static let toggleDictationEnabled = true
  static let togglePromptingEnabled = true
  static let toggleVoiceResponseEnabled = true
  static let readClipboardEnabled = true

  // MARK: - Model & Prompt Settings
  static let selectedTranscriptionModel = TranscriptionModel.gpt4oMiniTranscribe
  static let selectedPromptModel = GPTModel.gpt5Mini
  static let selectedVoiceResponseModel = GPTModel.gpt5Mini
  static let customPromptText = ""
  static let promptModeSystemPrompt = ""
  static let voiceResponseSystemPrompt = ""
  static let voiceResponsePlaybackSpeed = 1.0
  static let readSelectedTextPlaybackSpeed = 1.0
  static let conversationTimeout = ConversationTimeout.fiveMinutes

  // Reasoning effort settings for GPT-5 models
  static let promptReasoningEffort = ReasoningEffort.minimal
  static let voiceResponseReasoningEffort = ReasoningEffort.minimal

  // MARK: - Notification Settings
  static let showPopupNotifications = true

  // MARK: - UI State
  static let errorMessage = ""
  static let isLoading = false
  static let showAlert = false
}

// MARK: - Settings Data Models
struct SettingsData {
  // MARK: - Global Settings
  var apiKey: String = SettingsDefaults.apiKey

  // MARK: - Toggle Shortcut Settings
  var toggleDictation: String = SettingsDefaults.toggleDictation
  var togglePrompting: String = SettingsDefaults.togglePrompting
  var toggleVoiceResponse: String = SettingsDefaults.toggleVoiceResponse
  var readClipboard: String = SettingsDefaults.readClipboard

  // MARK: - Toggle Shortcut Enable States
  var toggleDictationEnabled: Bool = SettingsDefaults.toggleDictationEnabled
  var togglePromptingEnabled: Bool = SettingsDefaults.togglePromptingEnabled
  var toggleVoiceResponseEnabled: Bool = SettingsDefaults.toggleVoiceResponseEnabled
  var readClipboardEnabled: Bool = SettingsDefaults.readClipboardEnabled

  // MARK: - Model & Prompt Settings
  var selectedTranscriptionModel: TranscriptionModel = SettingsDefaults.selectedTranscriptionModel
  var selectedPromptModel: GPTModel = SettingsDefaults.selectedPromptModel
  var selectedVoiceResponseModel: GPTModel = SettingsDefaults.selectedVoiceResponseModel
  var customPromptText: String = SettingsDefaults.customPromptText
  var promptModeSystemPrompt: String = SettingsDefaults.promptModeSystemPrompt
  var voiceResponseSystemPrompt: String = SettingsDefaults.voiceResponseSystemPrompt
  var voiceResponsePlaybackSpeed: Double = SettingsDefaults.voiceResponsePlaybackSpeed
  var readSelectedTextPlaybackSpeed: Double = SettingsDefaults.readSelectedTextPlaybackSpeed
  var conversationTimeout: ConversationTimeout = SettingsDefaults.conversationTimeout

  // Reasoning effort settings for GPT-5 models
  var promptReasoningEffort: ReasoningEffort = SettingsDefaults.promptReasoningEffort
  var voiceResponseReasoningEffort: ReasoningEffort = SettingsDefaults.voiceResponseReasoningEffort

  // MARK: - Notification Settings
  var showPopupNotifications: Bool = SettingsDefaults.showPopupNotifications

  // MARK: - UI State
  var errorMessage: String = SettingsDefaults.errorMessage
  var isLoading: Bool = SettingsDefaults.isLoading
  var showAlert: Bool = SettingsDefaults.showAlert
}

// MARK: - Focus States Enum
enum SettingsFocusField: Hashable {
  case apiKey
  case toggleDictation
  case togglePrompting
  case toggleVoiceResponse
  case readClipboard
  case customPrompt
  case promptModeSystemPrompt
  case voiceResponseSystemPrompt
}

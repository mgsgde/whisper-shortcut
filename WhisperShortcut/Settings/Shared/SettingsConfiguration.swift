import Foundation

// MARK: - GPT Model Enum (for Prompt Mode)
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

  var supportsReasoning: Bool {
    switch self {
    case .gpt5:
      return true
    case .gpt5Nano, .gpt5Mini, .gpt5ChatLatest:
      return false
    }
  }
}

// MARK: - Reasoning Effort Enum
enum ReasoningEffort: String, CaseIterable {
  case low = "low"
  case medium = "medium"
  case high = "high"
  
  var displayName: String {
    switch self {
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
    case .low:
      return "Fast • Lower cost • Basic reasoning"
    case .medium:
      return "Balanced • Good quality • Recommended"
    case .high:
      return "Thorough • Higher cost • Deep reasoning"
    }
  }
  
  var isRecommended: Bool {
    return self == .medium
  }
}

// MARK: - GPT Audio Model Enum (for Voice Response Mode)
enum GPTAudioModel: String, CaseIterable {
  case gptAudio = "gpt-audio"
  case gptAudioMini = "gpt-audio-mini"
  
  var displayName: String {
    switch self {
    case .gptAudio:
      return "GPT-Audio"
    case .gptAudioMini:
      return "GPT-Audio Mini"
    }
  }
  
  var description: String {
    switch self {
    case .gptAudio:
      return "Best quality • Native audio understanding • For complex tasks"
    case .gptAudioMini:
      return "Recommended • Great quality at lower cost • Best for everyday use"
    }
  }
  
  var isRecommended: Bool {
    return self == .gptAudioMini
  }
  
  var costLevel: String {
    switch self {
    case .gptAudio:
      return "High"
    case .gptAudioMini:
      return "Low"
    }
  }
  
  var supportsReasoning: Bool {
    // GPT-Audio models don't support reasoning parameters
    return false
  }
}

// MARK: - Conversation Timeout Enum
enum ConversationTimeout: Double, CaseIterable {
  case noMemory = 0.0        // No memory - instant expiry
  case thirtySeconds = 0.5   // 30 Sekunden
  case oneMinute = 1.0
  case fiveMinutes = 5.0

  var displayName: String {
    switch self {
    case .noMemory:
      return "0 Seconds (No Memory)"
    case .thirtySeconds:
      return "30 Seconds"
    case .oneMinute:
      return "1 Minute"
    case .fiveMinutes:
      return "5 Minutes"
    }
  }

  var isRecommended: Bool {
    return self == .thirtySeconds
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
  static let selectedGPTAudioModel = GPTAudioModel.gptAudioMini
  static let customPromptText = ""
  static let promptModeSystemPrompt = ""
  static let voiceResponseSystemPrompt = ""
  static let readSelectedTextPlaybackSpeed = 1.0
  
  // MARK: - Reasoning Effort Settings
  static let promptReasoningEffort = ReasoningEffort.medium
  static let voiceResponseReasoningEffort = ReasoningEffort.medium

  // Getrennte Conversation Memory Defaults (je 30 Sekunden als Default)
  static let promptConversationTimeout = ConversationTimeout.thirtySeconds
  static let voiceResponseConversationTimeout = ConversationTimeout.thirtySeconds

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
  var selectedGPTAudioModel: GPTAudioModel = SettingsDefaults.selectedGPTAudioModel
  var customPromptText: String = SettingsDefaults.customPromptText
  var promptModeSystemPrompt: String = SettingsDefaults.promptModeSystemPrompt
  var voiceResponseSystemPrompt: String = SettingsDefaults.voiceResponseSystemPrompt
  var readSelectedTextPlaybackSpeed: Double = SettingsDefaults.readSelectedTextPlaybackSpeed
  
  // MARK: - Reasoning Effort Settings
  var promptReasoningEffort: ReasoningEffort = SettingsDefaults.promptReasoningEffort
  var voiceResponseReasoningEffort: ReasoningEffort = SettingsDefaults.voiceResponseReasoningEffort

  // Getrennte Conversation Memory Settings
  var promptConversationTimeout: ConversationTimeout = SettingsDefaults.promptConversationTimeout
  var voiceResponseConversationTimeout: ConversationTimeout =
    SettingsDefaults.voiceResponseConversationTimeout

  // MARK: - Notification Settings
  var showPopupNotifications: Bool = SettingsDefaults.showPopupNotifications

  // MARK: - UI State
  var errorMessage: String = SettingsDefaults.errorMessage
  var isLoading: Bool = SettingsDefaults.isLoading
  var showAlert: Bool = SettingsDefaults.showAlert
  var appStoreLinkCopied: Bool = false
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

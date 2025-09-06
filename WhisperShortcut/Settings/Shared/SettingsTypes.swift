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
}

// MARK: - Settings Data Models
struct SettingsData {
  // MARK: - Global Settings
  var apiKey: String = ""

  // MARK: - Toggle Shortcut Settings
  var toggleDictation: String = ""
  var togglePrompting: String = ""
  var toggleVoiceResponse: String = ""

  // MARK: - Toggle Shortcut Enable States
  var toggleDictationEnabled: Bool = true
  var togglePromptingEnabled: Bool = true
  var toggleVoiceResponseEnabled: Bool = true

  // MARK: - Model & Prompt Settings
  var selectedTranscriptionModel: TranscriptionModel = .gpt4oTranscribe
  var selectedPromptModel: GPTModel = .gpt5
  var selectedVoiceResponseModel: GPTModel = .gpt5
  var customPromptText: String = ""
  var promptModeSystemPrompt: String = ""
  var voiceResponseSystemPrompt: String = ""
  var audioPlaybackSpeed: Double = 1.0
  var conversationTimeout: ConversationTimeout = .fiveMinutes

  // MARK: - UI State
  var errorMessage: String = ""
  var isLoading: Bool = false
  var showAlert: Bool = false
}

// MARK: - Focus States Enum
enum SettingsFocusField: Hashable {
  case apiKey
  case toggleDictation
  case togglePrompting
  case toggleVoiceResponse
  case customPrompt
  case promptModeSystemPrompt
  case voiceResponseSystemPrompt
}

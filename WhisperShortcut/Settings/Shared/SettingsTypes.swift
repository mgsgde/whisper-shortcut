import Foundation

// MARK: - GPT Model Enum
enum GPTModel: String, CaseIterable {
  case gpt5 = "gpt-5"
  case gpt5Mini = "gpt-5-mini"

  var displayName: String {
    switch self {
    case .gpt5:
      return "GPT-5"
    case .gpt5Mini:
      return "GPT-5 Mini"
    }
  }

  var isRecommended: Bool {
    switch self {
    case .gpt5Mini:
      return true
    case .gpt5:
      return false
    }
  }

  var costLevel: String {
    switch self {
    case .gpt5Mini:
      return "Low"
    case .gpt5:
      return "High"
    }
  }
}

// MARK: - Settings Tab Definition
enum SettingsTab: String, CaseIterable {
  case general = "General"
  case speechToText = "Speech to Text"
  case speechToPrompt = "Speech to Prompt"
  case speechToPromptWithVoiceResponse = "Speech to Prompt with Voice Response"
}

// MARK: - Settings Data Models
struct SettingsData {
  // MARK: - Global Settings
  var apiKey: String = ""

  // MARK: - Shortcut Settings
  var startShortcut: String = ""
  var stopShortcut: String = ""
  var startPrompting: String = ""
  var stopPrompting: String = ""
  var startVoiceResponse: String = ""
  var stopVoiceResponse: String = ""
  var openChatGPT: String = ""

  // MARK: - Shortcut Enable States
  var startShortcutEnabled: Bool = true
  var stopShortcutEnabled: Bool = true
  var startPromptingEnabled: Bool = true
  var stopPromptingEnabled: Bool = true
  var startVoiceResponseEnabled: Bool = true
  var stopVoiceResponseEnabled: Bool = true
  var openChatGPTEnabled: Bool = true

  // MARK: - Model & Prompt Settings
  var selectedModel: TranscriptionModel = .gpt4oTranscribe
  var selectedGPTModel: GPTModel = .gpt5Mini
  var selectedVoiceResponseGPTModel: GPTModel = .gpt5Mini
  var customPromptText: String = ""
  var promptModeSystemPrompt: String = ""
  var audioPlaybackSpeed: Double = 1.0

  // MARK: - UI State
  var errorMessage: String = ""
  var isLoading: Bool = false
  var showAlert: Bool = false
}

// MARK: - Focus States Enum
enum SettingsFocusField: Hashable {
  case apiKey
  case startShortcut
  case stopShortcut
  case startPrompting
  case stopPrompting
  case startVoiceResponse
  case stopVoiceResponse
  case openChatGPT
  case customPrompt
  case promptModeSystemPrompt
}

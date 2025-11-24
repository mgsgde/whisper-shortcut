import Foundation

// MARK: - GPT Model Enum (for Prompt Mode) - REMOVED
// GPT-5 models removed - only using GPT-Audio models now

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

// MARK: - Unified Prompt Model Enum (for Prompt Mode) - GPT-Audio and Gemini multimodal models
enum PromptModel: String, CaseIterable {
  // GPT-Audio Models (audio-based, direct audio input)
  case gptAudio = "gpt-audio"
  case gptAudioMini = "gpt-audio-mini"
  
  // Gemini Models (multimodal, direct audio input)
  case gemini20Flash = "gemini-2.0-flash"
  case gemini20FlashLite = "gemini-2.0-flash-lite"
  case gemini25Flash = "gemini-2.5-flash"
  case gemini25FlashLite = "gemini-2.5-flash-lite"
  case gemini25Pro = "gemini-2.5-pro"
  case gemini35Pro = "gemini-3.5-pro"
  
  var displayName: String {
    switch self {
    case .gptAudio:
      return "GPT-Audio"
    case .gptAudioMini:
      return "GPT-Audio Mini"
    case .gemini20Flash:
      return "Gemini 2.0 Flash"
    case .gemini20FlashLite:
      return "Gemini 2.0 Flash-Lite"
    case .gemini25Flash:
      return "Gemini 2.5 Flash"
    case .gemini25FlashLite:
      return "Gemini 2.5 Flash-Lite"
    case .gemini25Pro:
      return "Gemini 2.5 Pro"
    case .gemini35Pro:
      return "Gemini 3.5 Pro"
    }
  }
  
  var description: String {
    switch self {
    case .gptAudio:
      return "Best quality • Native audio understanding • For complex tasks"
    case .gptAudioMini:
      return "Recommended • Great quality at lower cost • Best for everyday use"
    case .gemini20Flash:
      return "Google's Gemini 2.0 model • Fast and efficient • Multimodal audio processing"
    case .gemini20FlashLite:
      return "Google's Gemini 2.0 Flash-Lite • Fastest latency • Cost-efficient • Multimodal"
    case .gemini25Flash:
      return "Google's Gemini 2.5 model • Fast and efficient • Multimodal audio processing"
    case .gemini25FlashLite:
      return "Google's fastest Gemini model • Superior latency • Cost-efficient • Multimodal"
    case .gemini25Pro:
      return "Google's Gemini 2.5 Pro model • Higher quality • Best for complex tasks • Multimodal audio processing"
    case .gemini35Pro:
      return "Google's Gemini 3.5 Pro model • Highest quality • Best for complex tasks • Multimodal audio processing"
    }
  }
  
  var isRecommended: Bool {
    switch self {
    case .gptAudioMini:
      return true  // Default GPT-Audio model
    case .gptAudio, .gemini20Flash, .gemini20FlashLite, .gemini25Flash, .gemini25FlashLite, .gemini25Pro, .gemini35Pro:
      return false
    }
  }
  
  var costLevel: String {
    switch self {
    case .gptAudio:
      return "High"
    case .gptAudioMini, .gemini20Flash, .gemini20FlashLite, .gemini25Flash, .gemini25FlashLite:
      return "Low"
    case .gemini25Pro, .gemini35Pro:
      return "Medium"
    }
  }
  
  var supportsReasoning: Bool {
    // GPT-Audio and Gemini models don't support reasoning parameters
    return false
  }
  
  var requiresTranscription: Bool {
    // Both GPT-Audio and Gemini models accept audio directly (multimodal)
    return false
  }
  
  var isGemini: Bool {
    return self == .gemini20Flash || self == .gemini20FlashLite || self == .gemini25Flash || self == .gemini25FlashLite || self == .gemini25Pro || self == .gemini35Pro
  }
  
  // Convert to internal VoiceResponseModel for API calls (only for GPT-Audio models)
  var asVoiceResponseModel: VoiceResponseModel? {
    switch self {
    case .gptAudio:
      return .gptAudio
    case .gptAudioMini:
      return .gptAudioMini
    case .gemini20Flash, .gemini20FlashLite, .gemini25Flash, .gemini25FlashLite, .gemini25Pro, .gemini35Pro:
      return nil
    }
  }
  
  // Convert to TranscriptionModel for API endpoint access (for Gemini models)
  var asTranscriptionModel: TranscriptionModel? {
    switch self {
    case .gemini20Flash:
      return .gemini20Flash
    case .gemini20FlashLite:
      return .gemini20FlashLite
    case .gemini25Flash:
      return .gemini25Flash
    case .gemini25FlashLite:
      return .gemini25FlashLite
    case .gemini25Pro:
      return .gemini25Pro
    case .gemini35Pro:
      return .gemini35Pro
    case .gptAudio, .gptAudioMini:
      return nil
    }
  }
}

// MARK: - Voice Response Model Enum (for Voice Response Mode) - GPT-Audio and Gemini multimodal models
enum VoiceResponseModel: String, CaseIterable {
  case gptAudio = "gpt-audio"
  case gptAudioMini = "gpt-audio-mini"
  
  // Gemini Models (multimodal, direct audio input)
  case gemini20Flash = "gemini-2.0-flash"
  case gemini20FlashLite = "gemini-2.0-flash-lite"
  case gemini25Flash = "gemini-2.5-flash"
  case gemini25FlashLite = "gemini-2.5-flash-lite"
  case gemini25Pro = "gemini-2.5-pro"
  case gemini35Pro = "gemini-3.5-pro"
  
  var displayName: String {
    switch self {
    case .gptAudio:
      return "GPT-Audio"
    case .gptAudioMini:
      return "GPT-Audio Mini"
    case .gemini20Flash:
      return "Gemini 2.0 Flash"
    case .gemini20FlashLite:
      return "Gemini 2.0 Flash-Lite"
    case .gemini25Flash:
      return "Gemini 2.5 Flash"
    case .gemini25FlashLite:
      return "Gemini 2.5 Flash-Lite"
    case .gemini25Pro:
      return "Gemini 2.5 Pro"
    case .gemini35Pro:
      return "Gemini 3.5 Pro"
    }
  }
  
  var description: String {
    switch self {
    case .gptAudio:
      return "Best quality • Native audio understanding • For complex tasks"
    case .gptAudioMini:
      return "Recommended • Great quality at lower cost • Best for everyday use"
    case .gemini20Flash:
      return "Google's Gemini 2.0 model • Fast and efficient • Multimodal audio processing"
    case .gemini20FlashLite:
      return "Google's Gemini 2.0 Flash-Lite • Fastest latency • Cost-efficient • Multimodal"
    case .gemini25Flash:
      return "Google's Gemini 2.5 model • Fast and efficient • Multimodal audio processing"
    case .gemini25FlashLite:
      return "Google's fastest Gemini model • Superior latency • Cost-efficient • Multimodal"
    case .gemini25Pro:
      return "Google's Gemini 2.5 Pro model • Higher quality • Best for complex tasks • Multimodal audio processing"
    case .gemini35Pro:
      return "Google's Gemini 3.5 Pro model • Highest quality • Best for complex tasks • Multimodal audio processing"
    }
  }
  
  var isRecommended: Bool {
    return self == .gptAudioMini
  }
  
  var costLevel: String {
    switch self {
    case .gptAudio:
      return "High"
    case .gptAudioMini, .gemini20Flash, .gemini20FlashLite, .gemini25Flash, .gemini25FlashLite:
      return "Low"
    case .gemini25Pro, .gemini35Pro:
      return "Medium"
    }
  }
  
  var supportsReasoning: Bool {
    // GPT-Audio and Gemini models don't support reasoning parameters
    return false
  }
  
  var requiresTranscription: Bool {
    // Both GPT-Audio and Gemini models accept audio directly (multimodal)
    return false
  }
  
  var isGemini: Bool {
    return self == .gemini20Flash || self == .gemini20FlashLite || self == .gemini25Flash || self == .gemini25FlashLite || self == .gemini25Pro || self == .gemini35Pro
  }
  
  // Convert to TranscriptionModel for API endpoint access (for Gemini models)
  var asTranscriptionModel: TranscriptionModel? {
    switch self {
    case .gemini20Flash:
      return .gemini20Flash
    case .gemini20FlashLite:
      return .gemini20FlashLite
    case .gemini25Flash:
      return .gemini25Flash
    case .gemini25FlashLite:
      return .gemini25FlashLite
    case .gemini25Pro:
      return .gemini25Pro
    case .gemini35Pro:
      return .gemini35Pro
    case .gptAudio, .gptAudioMini:
      return nil
    }
  }
}

// MARK: - TTS Provider Enum
enum TTSProvider: String, CaseIterable {
  case openAI = "openai"
  case google = "google"
  
  var displayName: String {
    switch self {
    case .openAI:
      return "OpenAI"
    case .google:
      return "Google"
    }
  }
  
  var description: String {
    switch self {
    case .openAI:
      return "OpenAI TTS (gpt-4o-mini-tts)"
    case .google:
      return "Google Cloud Text-to-Speech"
    }
  }
  
  var isRecommended: Bool {
    return self == .openAI
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

// MARK: - Notification Position Enum
enum NotificationPosition: String, CaseIterable {
  case leftBottom = "left-bottom"
  case rightBottom = "right-bottom"
  case leftTop = "left-top"
  case rightTop = "right-top"
  case centerTop = "center-top"
  case centerBottom = "center-bottom"
  
  var displayName: String {
    switch self {
    case .leftBottom:
      return "Links unten"
    case .rightBottom:
      return "Rechts unten"
    case .leftTop:
      return "Links oben"
    case .rightTop:
      return "Rechts oben"
    case .centerTop:
      return "Mittig oben"
    case .centerBottom:
      return "Mittig unten"
    }
  }
  
  var isRecommended: Bool {
    return self == .leftBottom
  }
}

// MARK: - Notification Duration Enum
enum NotificationDuration: Double, CaseIterable {
  case oneSecond = 1.0
  case threeSeconds = 3.0
  case fiveSeconds = 5.0
  case sevenSeconds = 7.0
  case tenSeconds = 10.0
  case fifteenSeconds = 15.0
  case thirtySeconds = 30.0
  
  var displayName: String {
    switch self {
    case .oneSecond:
      return "1 Sekunde"
    case .threeSeconds:
      return "3 Sekunden"
    case .fiveSeconds:
      return "5 Sekunden"
    case .sevenSeconds:
      return "7 Sekunden"
    case .tenSeconds:
      return "10 Sekunden"
    case .fifteenSeconds:
      return "15 Sekunden"
    case .thirtySeconds:
      return "30 Sekunden"
    }
  }
  
  var isRecommended: Bool {
    return self == .threeSeconds
  }
}

// MARK: - Settings Tab Definition
enum SettingsTab: String, CaseIterable {
  case general = "General"
  case speechToText = "Dictate"
  case speechToPrompt = "Dictate Prompt"
  case speechToPromptWithVoiceResponse = "Dictate Prompt and Speak"
}

// MARK: - Default Settings Configuration
struct SettingsDefaults {
  // MARK: - Global Settings
  static let apiKey = ""
  static let googleAPIKey = ""

  // MARK: - Toggle Shortcut Settings
  static let toggleDictation = ""
  static let togglePrompting = ""
  static let toggleVoiceResponse = ""

  // MARK: - Toggle Shortcut Enable States
  static let toggleDictationEnabled = true
  static let togglePromptingEnabled = true
  static let toggleVoiceResponseEnabled = true

  // MARK: - Model & Prompt Settings
  static let selectedTranscriptionModel = TranscriptionModel.gemini20FlashLite
  static let selectedPromptModel = PromptModel.gemini25Pro
  static let selectedVoiceResponseModel = VoiceResponseModel.gemini25Pro
  static let customPromptText = ""
  static let dictationDifficultWords = ""
  static let promptModeSystemPrompt = ""
  static let voiceResponseSystemPrompt = ""
  
  // MARK: - Reasoning Effort Settings
  static let promptReasoningEffort = ReasoningEffort.medium
  static let voiceResponseReasoningEffort = ReasoningEffort.medium

  // Getrennte Conversation Memory Defaults (je 30 Sekunden als Default)
  static let promptConversationTimeout = ConversationTimeout.thirtySeconds
  static let voiceResponseConversationTimeout = ConversationTimeout.thirtySeconds

  // MARK: - Notification Settings
  static let showPopupNotifications = true
  static let notificationPosition = NotificationPosition.leftBottom
  static let notificationDuration = NotificationDuration.threeSeconds
  static let errorNotificationDuration = NotificationDuration.thirtySeconds

  // MARK: - UI State
  static let errorMessage = ""
  static let isLoading = false
  static let showAlert = false
}

// MARK: - Settings Data Models
struct SettingsData {
  // MARK: - Global Settings
  var apiKey: String = SettingsDefaults.apiKey
  var googleAPIKey: String = SettingsDefaults.googleAPIKey

  // MARK: - Toggle Shortcut Settings
  var toggleDictation: String = SettingsDefaults.toggleDictation
  var togglePrompting: String = SettingsDefaults.togglePrompting
  var toggleVoiceResponse: String = SettingsDefaults.toggleVoiceResponse

  // MARK: - Toggle Shortcut Enable States
  var toggleDictationEnabled: Bool = SettingsDefaults.toggleDictationEnabled
  var togglePromptingEnabled: Bool = SettingsDefaults.togglePromptingEnabled
  var toggleVoiceResponseEnabled: Bool = SettingsDefaults.toggleVoiceResponseEnabled

  // MARK: - Model & Prompt Settings
  var selectedTranscriptionModel: TranscriptionModel = SettingsDefaults.selectedTranscriptionModel
  var selectedPromptModel: PromptModel = SettingsDefaults.selectedPromptModel
  var selectedVoiceResponseModel: VoiceResponseModel = SettingsDefaults.selectedVoiceResponseModel
  var customPromptText: String = SettingsDefaults.customPromptText
  var dictationDifficultWords: String = SettingsDefaults.dictationDifficultWords
  var promptModeSystemPrompt: String = SettingsDefaults.promptModeSystemPrompt
  var voiceResponseSystemPrompt: String = SettingsDefaults.voiceResponseSystemPrompt
  
  // MARK: - Reasoning Effort Settings
  var promptReasoningEffort: ReasoningEffort = SettingsDefaults.promptReasoningEffort
  var voiceResponseReasoningEffort: ReasoningEffort = SettingsDefaults.voiceResponseReasoningEffort

  // Getrennte Conversation Memory Settings
  var promptConversationTimeout: ConversationTimeout = SettingsDefaults.promptConversationTimeout
  var voiceResponseConversationTimeout: ConversationTimeout =
    SettingsDefaults.voiceResponseConversationTimeout

  // MARK: - Notification Settings
  var showPopupNotifications: Bool = SettingsDefaults.showPopupNotifications
  var notificationPosition: NotificationPosition = SettingsDefaults.notificationPosition
  var notificationDuration: NotificationDuration = SettingsDefaults.notificationDuration
  var errorNotificationDuration: NotificationDuration = SettingsDefaults.errorNotificationDuration

  // MARK: - UI State
  var errorMessage: String = SettingsDefaults.errorMessage
  var isLoading: Bool = SettingsDefaults.isLoading
  var showAlert: Bool = SettingsDefaults.showAlert
  var appStoreLinkCopied: Bool = false
}

// MARK: - Focus States Enum
enum SettingsFocusField: Hashable {
  case apiKey
  case googleAPIKey
  case toggleDictation
  case togglePrompting
  case toggleVoiceResponse
  case customPrompt
  case dictationDifficultWords
  case promptModeSystemPrompt
  case voiceResponseSystemPrompt
}

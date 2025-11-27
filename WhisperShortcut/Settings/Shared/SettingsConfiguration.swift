import Foundation

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

// MARK: - Unified Prompt Model Enum (for Prompt Mode) - Gemini multimodal models only
enum PromptModel: String, CaseIterable {
  // Gemini Models (multimodal, direct audio input)
  case gemini20Flash = "gemini-2.0-flash"
  case gemini20FlashLite = "gemini-2.0-flash-lite"
  case gemini25Flash = "gemini-2.5-flash"
  case gemini25FlashLite = "gemini-2.5-flash-lite"
  
  var displayName: String {
    switch self {
    case .gemini20Flash:
      return "Gemini 2.0 Flash"
    case .gemini20FlashLite:
      return "Gemini 2.0 Flash-Lite"
    case .gemini25Flash:
      return "Gemini 2.5 Flash"
    case .gemini25FlashLite:
      return "Gemini 2.5 Flash-Lite"
    }
  }
  
  var description: String {
    switch self {
    case .gemini20Flash:
      return "Google's Gemini 2.0 Flash model • Fast and efficient • Multimodal audio processing"
    case .gemini20FlashLite:
      return "Google's Gemini 2.0 Flash-Lite • Fastest latency • Cost-efficient • Multimodal"
    case .gemini25Flash:
      return "Google's Gemini 2.5 Flash model • Fast and efficient • Multimodal audio processing"
    case .gemini25FlashLite:
      return "Google's Gemini 2.5 Flash-Lite • Fastest latency • Cost-efficient • Multimodal"
    }
  }
  
  var isRecommended: Bool {
    switch self {
    case .gemini20Flash:
      return true
    case .gemini20FlashLite, .gemini25Flash, .gemini25FlashLite:
      return false
    }
  }
  
  var costLevel: String {
    switch self {
    case .gemini20Flash, .gemini20FlashLite, .gemini25Flash, .gemini25FlashLite:
      return "Low"
    }
  }
  
  var supportsReasoning: Bool {
    return false
  }
  
  var requiresTranscription: Bool {
    return false
  }
  
  var isGemini: Bool {
    return true
  }
  
  var supportsNativeAudioOutput: Bool {
    return false
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
    }
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
}

// MARK: - Default Settings Configuration
struct SettingsDefaults {
  // MARK: - Global Settings
  static let googleAPIKey = ""
  static let launchAtLogin = false

  // MARK: - Toggle Shortcut Settings
  static let toggleDictation = ""
  static let togglePrompting = ""

  // MARK: - Toggle Shortcut Enable States
  static let toggleDictationEnabled = true
  static let togglePromptingEnabled = true

  // MARK: - Model & Prompt Settings
  static let selectedTranscriptionModel = TranscriptionModel.gemini20Flash
  static let selectedPromptModel = PromptModel.gemini20Flash
  static let customPromptText = ""
  static let dictationDifficultWords = ""
  static let promptModeSystemPrompt = ""
  
  // MARK: - Reasoning Effort Settings
  static let promptReasoningEffort = ReasoningEffort.medium

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
  var googleAPIKey: String = SettingsDefaults.googleAPIKey
  var launchAtLogin: Bool = SettingsDefaults.launchAtLogin

  // MARK: - Toggle Shortcut Settings
  var toggleDictation: String = SettingsDefaults.toggleDictation
  var togglePrompting: String = SettingsDefaults.togglePrompting

  // MARK: - Toggle Shortcut Enable States
  var toggleDictationEnabled: Bool = SettingsDefaults.toggleDictationEnabled
  var togglePromptingEnabled: Bool = SettingsDefaults.togglePromptingEnabled

  // MARK: - Model & Prompt Settings
  var selectedTranscriptionModel: TranscriptionModel = SettingsDefaults.selectedTranscriptionModel
  var selectedPromptModel: PromptModel = SettingsDefaults.selectedPromptModel
  var customPromptText: String = SettingsDefaults.customPromptText
  var dictationDifficultWords: String = SettingsDefaults.dictationDifficultWords
  var promptModeSystemPrompt: String = SettingsDefaults.promptModeSystemPrompt
  
  // MARK: - Reasoning Effort Settings
  var promptReasoningEffort: ReasoningEffort = SettingsDefaults.promptReasoningEffort

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
  case googleAPIKey
  case toggleDictation
  case togglePrompting
  case customPrompt
  case dictationDifficultWords
  case promptModeSystemPrompt
}

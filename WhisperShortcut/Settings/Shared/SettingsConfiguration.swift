import Foundation

// MARK: - Unified Prompt Model Enum (for Prompt Mode) - Gemini multimodal models only
// Current Gemini model IDs: https://cloud.google.com/vertex-ai/generative-ai/docs/models/gemini/2-5-flash (and sibling docs)
// GA (stable IDs): gemini-2.5-flash, gemini-2.5-flash-lite; 2.0 deprecated. gemini-2.0-flash-lite removed (API 404). Preview: gemini-3-*.
enum PromptModel: String, CaseIterable {
  // Gemini Models (multimodal, direct audio input)
  case gemini20Flash = "gemini-2.0-flash"
  case gemini25Flash = "gemini-2.5-flash"
  case gemini25FlashLite = "gemini-2.5-flash-lite"
  case gemini25Pro = "gemini-2.5-pro"
  case gemini3Flash = "gemini-3-flash-preview"
  case gemini3Pro = "gemini-3-pro-preview"
  case gemini31Pro = "gemini-3.1-pro-preview"
  case gemini31FlashLite = "gemini-3.1-flash-lite-preview"
  
  var displayName: String {
    switch self {
    case .gemini20Flash:
      return "Gemini 2.0 Flash"
    case .gemini25Flash:
      return "Gemini 2.5 Flash"
    case .gemini25FlashLite:
      return "Gemini 2.5 Flash-Lite"
    case .gemini25Pro:
      return "Gemini 2.5 Pro"
    case .gemini3Flash:
      return "Gemini 3 Flash"
    case .gemini3Pro:
      return "Gemini 3 Pro"
    case .gemini31Pro:
      return "Gemini 3.1 Pro"
    case .gemini31FlashLite:
      return "Gemini 3.1 Flash-Lite"
    }
  }
  
  var description: String {
    switch self {
    case .gemini20Flash:
      return "Google's Gemini 2.0 Flash model • Fast and efficient • Multimodal audio processing"
    case .gemini25Flash:
      return "Google's Gemini 2.5 Flash model • Fast and efficient • Multimodal audio processing"
    case .gemini25FlashLite:
      return "Google's Gemini 2.5 Flash-Lite • Fastest latency • Cost-efficient • Multimodal"
    case .gemini25Pro:
      return "Google's Gemini 2.5 Pro model • Strong reasoning and instruction following • Stable (GA)"
    case .gemini3Flash:
      return "Google's Gemini 3 Flash model • Latest 3-series • Pro-level intelligence at Flash speed • Multimodal"
    case .gemini3Pro:
      return "Google's Gemini 3 Pro model • Best quality and reasoning • Multimodal"
    case .gemini31Pro:
      return "Google's Gemini 3.1 Pro model • Complex reasoning and agentic workflows • Multimodal"
    case .gemini31FlashLite:
      return "Google's Gemini 3.1 Flash-Lite • Fastest, most cost-efficient 3-series • Multimodal"
    }
  }
  
  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.selectedPromptModel
  }
  
  var costLevel: String {
    switch self {
    case .gemini20Flash, .gemini25Flash, .gemini25FlashLite, .gemini3Flash, .gemini31FlashLite:
      return "Low"
    case .gemini25Pro, .gemini3Pro, .gemini31Pro:
      return "Medium"
    }
  }
  
  var supportsReasoning: Bool {
    return false
  }
  
  var requiresTranscription: Bool {
    return false // Gemini models process audio directly
  }
  
  var isGemini: Bool {
    return true // All prompt models are Gemini (offline LLM support planned for future)
  }
  
  var isOffline: Bool {
    return false // Prompt mode doesn't support offline models yet
  }
  
  var supportsNativeAudioOutput: Bool {
    return false
  }
  
  // Convert to TranscriptionModel for API endpoint access (for Gemini models)
  var asTranscriptionModel: TranscriptionModel? {
    switch self {
    case .gemini20Flash:
      return .gemini20Flash
    case .gemini25Flash:
      return .gemini25Flash
    case .gemini25FlashLite:
      return .gemini25FlashLite
    case .gemini25Pro:
      return nil // 2.5 Pro not used for transcription in this app
    case .gemini3Flash:
      return .gemini3Flash
    case .gemini3Pro:
      return .gemini3Pro
    case .gemini31Pro:
      return .gemini31Pro
    case .gemini31FlashLite:
      return .gemini31FlashLite
    }
  }

  /// Migrates deprecated 2.0 Flash models to 2.5; returns the model unchanged otherwise.
  static func migrateIfDeprecated(_ model: PromptModel) -> PromptModel {
    switch model {
    case .gemini20Flash: return .gemini25Flash
    default: return model
    }
  }

  /// Loads the model selected for the Open Gemini window (Settings → Open Gemini).
  static func loadSelectedOpenGemini() -> PromptModel {
    guard let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedOpenGeminiModel),
          let parsed = PromptModel(rawValue: raw) else {
      return SettingsDefaults.selectedOpenGeminiModel
    }
    return migrateIfDeprecated(parsed)
  }

  /// Loads the model selected for meeting summary (rolling and final). Settings → Live Meeting → Summary Model.
  static func loadSelectedMeetingSummary() -> PromptModel {
    guard let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedMeetingSummaryModel),
          let parsed = PromptModel(rawValue: raw) else {
      return SettingsDefaults.selectedMeetingSummaryModel
    }
    return migrateIfDeprecated(parsed)
  }
}

// MARK: - TTS Model Enum (for Text-to-Speech)
// Gemini TTS via Generative Language API (generateContent), not Cloud TTS.
// Docs: https://ai.google.dev/gemini-api/docs/speech-generation
enum TTSModel: String, CaseIterable {
  case gemini25FlashTTS = "gemini-2.5-flash-preview-tts"
  case gemini25ProTTS = "gemini-2.5-pro-preview-tts"
  
  var displayName: String {
    switch self {
    case .gemini25FlashTTS:
      return "Gemini 2.5 Flash TTS"
    case .gemini25ProTTS:
      return "Gemini 2.5 Pro TTS"
    }
  }
  
  var description: String {
    switch self {
    case .gemini25FlashTTS:
      return "Google's Gemini 2.5 Flash TTS model • Fast and efficient • Recommended"
    case .gemini25ProTTS:
      return "Google's Gemini 2.5 Pro TTS model • Higher quality • Better voice synthesis"
    }
  }
  
  /// Generative Language API endpoint (same API key as transcription). Model in path.
  /// https://ai.google.dev/gemini-api/docs/speech-generation
  var apiEndpoint: String {
    return "https://generativelanguage.googleapis.com/v1beta/models/\(rawValue):generateContent"
  }

  var modelName: String {
    return self.rawValue
  }
  
  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.selectedTTSModel
  }
  
  var costLevel: String {
    return "Low"
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
      return "Left bottom"
    case .rightBottom:
      return "Right bottom"
    case .leftTop:
      return "Left top"
    case .rightTop:
      return "Right top"
    case .centerTop:
      return "Center top"
    case .centerBottom:
      return "Center bottom"
    }
  }
  
  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.notificationPosition
  }
}

// MARK: - Notification Duration Enum
enum NotificationDuration: Double, CaseIterable {
  case oneSecond = 1.0
  case twoSeconds = 2.0
  case threeSeconds = 3.0
  case fiveSeconds = 5.0
  case sevenSeconds = 7.0
  case tenSeconds = 10.0
  case fifteenSeconds = 15.0
  case thirtySeconds = 30.0
  
  var displayName: String {
    switch self {
    case .oneSecond:
      return "1 second"
    case .twoSeconds:
      return "2 seconds"
    case .threeSeconds:
      return "3 seconds"
    case .fiveSeconds:
      return "5 seconds"
    case .sevenSeconds:
      return "7 seconds"
    case .tenSeconds:
      return "10 seconds"
    case .fifteenSeconds:
      return "15 seconds"
    case .thirtySeconds:
      return "30 seconds"
    }
  }
  
  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.notificationDuration
  }
}

// MARK: - Confirm Above Duration (Recording Safeguard)
enum ConfirmAboveDuration: Double, CaseIterable {
  case never = 0
  case oneMinute = 60
  case twoMinutes = 120
  case fiveMinutes = 300
  case tenMinutes = 600

  var displayName: String {
    switch self {
    case .never: return "Never"
    case .oneMinute: return "1 minute"
    case .twoMinutes: return "2 minutes"
    case .fiveMinutes: return "5 minutes"
    case .tenMinutes: return "10 minutes"
    }
  }

  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.confirmAboveDuration
  }

  /// Loads value from UserDefaults or returns SettingsDefaults.confirmAboveDuration.
  static func loadFromUserDefaults() -> ConfirmAboveDuration {
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.confirmAboveDurationSeconds) != nil,
       let t = ConfirmAboveDuration(rawValue: UserDefaults.standard.double(forKey: UserDefaultsKeys.confirmAboveDurationSeconds)) {
      return t
    }
    return SettingsDefaults.confirmAboveDuration
  }
}

// MARK: - Meeting Safeguard Duration (Live Meeting)
enum MeetingSafeguardDuration: Double, CaseIterable {
  case never = 0
  case sixtyMinutes = 3600
  case ninetyMinutes = 5400
  case twoHours = 7200

  var displayName: String {
    switch self {
    case .never: return "Never"
    case .sixtyMinutes: return "60 minutes"
    case .ninetyMinutes: return "90 minutes"
    case .twoHours: return "2 hours"
    }
  }

  /// Loads value from UserDefaults or returns SettingsDefaults.liveMeetingSafeguardDuration.
  static func loadFromUserDefaults() -> MeetingSafeguardDuration {
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.liveMeetingSafeguardDurationSeconds) != nil,
       let t = MeetingSafeguardDuration(rawValue: UserDefaults.standard.double(forKey: UserDefaultsKeys.liveMeetingSafeguardDurationSeconds)) {
      return t
    }
    return SettingsDefaults.liveMeetingSafeguardDuration
  }
}

// MARK: - Improve from Usage auto-run interval
enum ImproveFromUsageAutoRunInterval: Int, CaseIterable {
  case off = 0
  case every3Days = 3
  case every7Days = 7
  case every30Days = 30

  /// Number of days between runs; nil when off.
  var dayCount: Int? {
    switch self {
    case .off: return nil
    case .every3Days: return 3
    case .every7Days: return 7
    case .every30Days: return 30
    }
  }

  var displayName: String {
    switch self {
    case .off: return "Off"
    case .every3Days: return "Every 3 days"
    case .every7Days: return "Every 7 days"
    case .every30Days: return "Every 30 days"
    }
  }
}

// MARK: - Whisper Language Enum
enum WhisperLanguage: String, CaseIterable {
  case auto = "auto"
  case en = "en"
  case de = "de"
  case fr = "fr"
  case es = "es"
  case it = "it"
  case pt = "pt"
  case ru = "ru"
  case ja = "ja"
  case ko = "ko"
  case zh = "zh"
  case nl = "nl"
  case pl = "pl"
  case tr = "tr"
  case sv = "sv"
  case da = "da"
  case no = "no"
  case fi = "fi"
  case cs = "cs"
  case hu = "hu"
  case ro = "ro"
  case el = "el"
  case ar = "ar"
  case hi = "hi"
  
  var displayName: String {
    switch self {
    case .auto:
      return "Auto-detect"
    case .en:
      return "English"
    case .de:
      return "German"
    case .fr:
      return "French"
    case .es:
      return "Spanish"
    case .it:
      return "Italian"
    case .pt:
      return "Portuguese"
    case .ru:
      return "Russian"
    case .ja:
      return "Japanese"
    case .ko:
      return "Korean"
    case .zh:
      return "Chinese"
    case .nl:
      return "Dutch"
    case .pl:
      return "Polish"
    case .tr:
      return "Turkish"
    case .sv:
      return "Swedish"
    case .da:
      return "Danish"
    case .no:
      return "Norwegian"
    case .fi:
      return "Finnish"
    case .cs:
      return "Czech"
    case .hu:
      return "Hungarian"
    case .ro:
      return "Romanian"
    case .el:
      return "Greek"
    case .ar:
      return "Arabic"
    case .hi:
      return "Hindi"
    }
  }
  
  /// Recommended is aligned with default; single source of truth in SettingsDefaults.
  var isRecommended: Bool {
    return self == SettingsDefaults.whisperLanguage
  }
  
  var languageCode: String? {
    return self == .auto ? nil : self.rawValue
  }
}

// MARK: - Settings Tab Definition
enum SettingsTab: String, CaseIterable {
  case general = "General"
  case speechToText = "Dictate"
  case speechToPrompt = "Prompt Mode"
  case promptAndRead = "Prompt Read Mode"
  case readAloud = "Read Aloud"
  case openMeeting = "Open Meeting"
  case openGemini = "Open Gemini"
  case context = "Context"
}

// MARK: - Live Meeting Chunk Interval Options
enum LiveMeetingChunkInterval: Double, CaseIterable {
  case fifteenSeconds = 15.0
  case thirtySeconds = 30.0
  case fortyFiveSeconds = 45.0
  case sixtySeconds = 60.0
  
  var displayName: String {
    switch self {
    case .fifteenSeconds: return "15 seconds"
    case .thirtySeconds: return "30 seconds"
    case .fortyFiveSeconds: return "45 seconds"
    case .sixtySeconds: return "60 seconds"
    }
  }
}

// MARK: - Default Settings Configuration
struct SettingsDefaults {
  // MARK: - Global Settings
  static let googleAPIKey = ""
  static let launchAtLogin = false

  // MARK: - Toggle Shortcut Settings
  static let toggleDictation = ""
  static let togglePrompting = ""
  static let readSelectedText = ""
  static let readAloud = ""
  static let toggleMeeting = ""
  static let openSettings = ""
  static let openGemini = ""
  static let openMeeting = ""

  // MARK: - Toggle Shortcut Enable States
  static let toggleDictationEnabled = true
  static let togglePromptingEnabled = true
  static let readSelectedTextEnabled = true
  static let readAloudEnabled = true
  static let toggleMeetingEnabled = true
  static let openSettingsEnabled = true
  static let openGeminiEnabled = true
  static let openMeetingEnabled = true
  // MARK: - Model & Prompt Settings
  static let selectedTranscriptionModel = TranscriptionModel.gemini31FlashLite
  static let selectedPromptModel = PromptModel.gemini3Flash
  static let selectedPromptAndReadModel = PromptModel.gemini3Flash
  #if SUBSCRIPTION_ENABLED
  // MARK: - Subscription fixed models (proxy)
  // When the user is on subscription (no API key, signed in with Google), the backend forces these models per request_type.
  // These constants MUST match apps/api/src/server.ts SUBSCRIPTION_MODEL_BY_REQUEST_TYPE. Use them for API requests and for
  // Settings UI (effective model display) so the user always sees what is actually used.
  /// prompt_mode, prompt_and_read; backend: prompt_mode → gemini-3-flash-preview.
  static let subscriptionPromptModel = PromptModel.gemini3Flash
  /// Transcription (Dictate); backend: transcription → gemini-3.1-flash-lite-preview.
  static let subscriptionTranscriptionModel = TranscriptionModel.gemini31FlashLite
  /// Open Gemini chat window; backend: gemini_chat → gemini-3.1-flash-lite-preview.
  static let subscriptionOpenGeminiModel = PromptModel.gemini3Flash
  /// Smart Improvement (Improve from usage / from voice); backend: smart_improvement → gemini-3-flash-preview.
  static let subscriptionImprovementModel = PromptModel.gemini3Flash
  /// TTS when on subscription; backend uses fixed model. Must match server.ts for display.
  static let subscriptionTTSModel = TTSModel.gemini25FlashTTS
  #endif
  static let selectedImprovementModel = PromptModel.gemini3Flash
  static let selectedOpenGeminiModel = PromptModel.gemini3Flash
  static let geminiCloseOnFocusLoss = true
  static let settingsCloseOnFocusLoss = true
  static let customPromptText = ""
  static let promptModeSystemPrompt = ""
  static let promptAndReadSystemPrompt = ""

  // MARK: - Read Aloud Settings
  static let selectedReadAloudVoice = "Charon"
  static let selectedPromptAndReadVoice = "Charon"
  static let selectedTTSModel = TTSModel.gemini25FlashTTS
  static let readAloudPlaybackRateMin: Float = 0.5
  static let readAloudPlaybackRateMax: Float = 2.0
  static let readAloudPlaybackRate: Float = 1.0

  /// Returns the read-aloud playback rate from UserDefaults, clamped to valid range, or default if not set.
  static func clampedReadAloudPlaybackRate() -> Float {
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.readAloudPlaybackRate) != nil {
      let saved = UserDefaults.standard.float(forKey: UserDefaultsKeys.readAloudPlaybackRate)
      return min(max(saved, readAloudPlaybackRateMin), readAloudPlaybackRateMax)
    }
    return readAloudPlaybackRate
  }

  // MARK: - Whisper Language Settings
  static let whisperLanguage = WhisperLanguage.auto

  // MARK: - Notification Settings
  static let showPopupNotifications = true
  static let notificationPosition = NotificationPosition.leftTop
  static let notificationDuration = NotificationDuration.oneSecond
  static let errorNotificationDuration = NotificationDuration.thirtySeconds

  // MARK: - Recording Safeguards
  static let confirmAboveDuration = ConfirmAboveDuration.fiveMinutes

  // MARK: - Auto-Paste Settings
  static let autoPasteAfterDictation = true

  // MARK: - Live Meeting Settings
  static let liveMeetingChunkInterval = LiveMeetingChunkInterval.fifteenSeconds
  static let liveMeetingSafeguardDuration = MeetingSafeguardDuration.ninetyMinutes
  static let selectedMeetingSummaryModel = PromptModel.gemini3Flash

  // MARK: - Backend API (when signed in, Gemini + usage use this)
  /// Debug: local API (npm run dev) unless WSUseProductionAPI UserDefaults is set. Release: production.
  static var proxyAPIBaseURL: String {
    #if DEBUG
    if UserDefaults.standard.bool(forKey: "WSUseProductionAPI") {
      return "https://whisper-api-797100884157.europe-west3.run.app"
    }
    return "http://localhost:8080"
    #else
    return "https://whisper-api-797100884157.europe-west3.run.app"
    #endif
  }

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
  var readSelectedText: String = SettingsDefaults.readSelectedText
  var readAloud: String = SettingsDefaults.readAloud
  var toggleMeeting: String = SettingsDefaults.toggleMeeting
  var openSettings: String = SettingsDefaults.openSettings
  var openGemini: String = SettingsDefaults.openGemini
  var openMeeting: String = SettingsDefaults.openMeeting

  // MARK: - Toggle Shortcut Enable States
  var toggleDictationEnabled: Bool = SettingsDefaults.toggleDictationEnabled
  var togglePromptingEnabled: Bool = SettingsDefaults.togglePromptingEnabled
  var readSelectedTextEnabled: Bool = SettingsDefaults.readSelectedTextEnabled
  var readAloudEnabled: Bool = SettingsDefaults.readAloudEnabled
  var toggleMeetingEnabled: Bool = SettingsDefaults.toggleMeetingEnabled
  var openSettingsEnabled: Bool = SettingsDefaults.openSettingsEnabled
  var openGeminiEnabled: Bool = SettingsDefaults.openGeminiEnabled
  var openMeetingEnabled: Bool = SettingsDefaults.openMeetingEnabled
  // MARK: - Model & Prompt Settings
  var selectedTranscriptionModel: TranscriptionModel = SettingsDefaults.selectedTranscriptionModel
  var selectedPromptModel: PromptModel = SettingsDefaults.selectedPromptModel
  var selectedPromptAndReadModel: PromptModel = SettingsDefaults.selectedPromptAndReadModel
  var selectedImprovementModel: PromptModel = SettingsDefaults.selectedImprovementModel
  var selectedOpenGeminiModel: PromptModel = SettingsDefaults.selectedOpenGeminiModel
  var geminiCloseOnFocusLoss: Bool = SettingsDefaults.geminiCloseOnFocusLoss
  var settingsCloseOnFocusLoss: Bool = SettingsDefaults.settingsCloseOnFocusLoss
  var customPromptText: String = SettingsDefaults.customPromptText
  var promptModeSystemPrompt: String = SettingsDefaults.promptModeSystemPrompt
  var promptAndReadSystemPrompt: String = SettingsDefaults.promptAndReadSystemPrompt
  
  // MARK: - Read Aloud Settings
  var selectedReadAloudVoice: String = SettingsDefaults.selectedReadAloudVoice
  var selectedPromptAndReadVoice: String = SettingsDefaults.selectedPromptAndReadVoice
  var selectedTTSModel: TTSModel = SettingsDefaults.selectedTTSModel
  var readAloudPlaybackRate: Float = SettingsDefaults.readAloudPlaybackRate

  // MARK: - Whisper Language Settings
  var whisperLanguage: WhisperLanguage = SettingsDefaults.whisperLanguage

  // MARK: - Notification Settings
  var showPopupNotifications: Bool = SettingsDefaults.showPopupNotifications
  var notificationPosition: NotificationPosition = SettingsDefaults.notificationPosition
  var notificationDuration: NotificationDuration = SettingsDefaults.notificationDuration
  var errorNotificationDuration: NotificationDuration = SettingsDefaults.errorNotificationDuration

  // MARK: - Recording Safeguards
  var confirmAboveDuration: ConfirmAboveDuration = SettingsDefaults.confirmAboveDuration

  // MARK: - Auto-Paste Settings
  var autoPasteAfterDictation: Bool = SettingsDefaults.autoPasteAfterDictation

  // MARK: - Live Meeting Settings
  var liveMeetingChunkInterval: LiveMeetingChunkInterval = SettingsDefaults.liveMeetingChunkInterval
  var liveMeetingSafeguardDuration: MeetingSafeguardDuration = SettingsDefaults.liveMeetingSafeguardDuration
  var selectedTranscriptionModelForMeetings: TranscriptionModel = SettingsDefaults.selectedTranscriptionModel
  var selectedMeetingSummaryModel: PromptModel = SettingsDefaults.selectedMeetingSummaryModel

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
  case toggleReadSelectedText
  case toggleReadAloud
  case toggleSettings
  case toggleGemini
  case openMeeting
  case customPrompt
  case promptModeSystemPrompt
  case promptAndReadSystemPrompt
  case readAloudVoice
}

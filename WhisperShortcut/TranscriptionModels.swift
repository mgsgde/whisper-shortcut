//
//  TranscriptionModels.swift
//  WhisperShortcut
//
//  Data models for transcription API interactions (Gemini)
//

import Foundation

// MARK: - Transcription Model Enum
// Current Gemini model IDs: https://cloud.google.com/vertex-ai/generative-ai/docs/models/gemini/2-5-flash (and sibling docs)
// GA (stable IDs, no -preview): gemini-2.5-flash, gemini-2.5-flash-lite, gemini-2.0-flash (2.0 deprecated). gemini-2.0-flash-lite removed (API 404).
// Preview (keep -preview): gemini-3-flash-preview, gemini-3-pro-preview, gemini-3.1-pro-preview.
enum TranscriptionModel: String, CaseIterable {
  // Gemini models (online)
  case gemini20Flash = "gemini-2.0-flash"
  case gemini25Flash = "gemini-2.5-flash"
  case gemini25FlashLite = "gemini-2.5-flash-lite"
  case gemini3Flash = "gemini-3-flash-preview"
  case gemini3Pro = "gemini-3-pro-preview"
  case gemini31Pro = "gemini-3.1-pro-preview"
  
  // Offline Whisper models
  case whisperTiny = "whisper-tiny"
  case whisperBase = "whisper-base"
  case whisperSmall = "whisper-small"
  case whisperMedium = "whisper-medium"

  var displayName: String {
    switch self {
    case .gemini20Flash:
      return "Gemini 2.0 Flash (Deprecated)"
    case .gemini25Flash:
      return "Gemini 2.5 Flash"
    case .gemini25FlashLite:
      return "Gemini 2.5 Flash-Lite"
    case .gemini3Flash:
      return "Gemini 3 Flash"
    case .gemini3Pro:
      return "Gemini 3 Pro"
    case .gemini31Pro:
      return "Gemini 3.1 Pro"
    case .whisperTiny:
      return "Whisper Tiny (Offline)"
    case .whisperBase:
      return "Whisper Base (Offline)"
    case .whisperSmall:
      return "Whisper Small (Offline)"
    case .whisperMedium:
      return "Whisper Medium (Offline)"
    }
  }

  /// Uses v1beta so Gemini 3 preview models are available (v1 returns 404 for them).
  var apiEndpoint: String {
    switch self {
    case .gemini20Flash:
      return "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
    case .gemini25Flash:
      return "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
    case .gemini25FlashLite:
      return "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent"
    case .gemini3Flash:
      return "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent"
    case .gemini3Pro:
      return "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-preview:generateContent"
    case .gemini31Pro:
      return "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro-preview:generateContent"
    case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium:
      return "" // Offline models don't use API endpoints
    }
  }

  var isRecommended: Bool {
    switch self {
    case .gemini25FlashLite, .gemini25Flash, .whisperBase:
      return true
    case .gemini20Flash, .gemini3Flash, .gemini3Pro, .gemini31Pro, .whisperTiny, .whisperSmall, .whisperMedium:
      return false
    }
  }

  /// True for Gemini models no longer available to new users (e.g. gemini-2.0-flash). Used to migrate to current default.
  var isDeprecated: Bool {
    switch self {
    case .gemini20Flash:
      return true
    default:
      return false
    }
  }

  var costLevel: String {
    switch self {
    case .gemini20Flash, .gemini25Flash, .gemini25FlashLite, .gemini3Flash:
      return "Low"
    case .gemini3Pro, .gemini31Pro:
      return "Medium"
    case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium:
      return "Free (Offline)"
    }
  }

  var description: String {
    switch self {
    case .gemini20Flash:
      return "Google's Gemini 2.0 Flash model • Fast and efficient"
    case .gemini25Flash:
      return "Google's Gemini 2.5 Flash model • Fast and efficient"
    case .gemini25FlashLite:
      return "Google's Gemini 2.5 Flash-Lite model • Fastest latency • Cost-efficient"
    case .gemini3Flash:
      return "Google's Gemini 3 Flash model • Latest 3-series • Pro-level intelligence at Flash speed"
    case .gemini3Pro:
      return "Google's Gemini 3 Pro model • Best quality and reasoning • Multimodal"
    case .gemini31Pro:
      return "Google's Gemini 3.1 Pro model • Complex reasoning and agentic workflows • Multimodal"
    case .whisperTiny:
      return "OpenAI Whisper Tiny • Fastest • ~75MB • Offline"
    case .whisperBase:
      return "OpenAI Whisper Base • Recommended • ~140MB • Offline"
    case .whisperSmall:
      return "OpenAI Whisper Small • Better quality • ~460MB • Offline"
    case .whisperMedium:
      return "OpenAI Whisper Medium • Best quality • ~1.5GB • Offline"
    }
  }
  
  var isGemini: Bool {
    switch self {
    case .gemini20Flash, .gemini25Flash, .gemini25FlashLite, .gemini3Flash, .gemini3Pro, .gemini31Pro:
      return true
    case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium:
      return false
    }
  }
  
  var isOffline: Bool {
    return !isGemini
  }
  
  var offlineModelType: OfflineModelType? {
    switch self {
    case .whisperTiny: return .whisperTiny
    case .whisperBase: return .whisperBase
    case .whisperSmall: return .whisperSmall
    case .whisperMedium: return .whisperMedium
    default: return nil
    }
  }
  
  // MARK: - Model Loading
  /// Loads the selected transcription model from UserDefaults, or returns the default model.
  /// Migrates removed models (e.g. gemini-2.0-flash-lite → gemini-2.5-flash-lite). Deprecated but still available models (e.g. gemini-2.0-flash) are returned so the user's choice persists.
  static func loadSelected() -> TranscriptionModel {
    guard let savedModelString = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedTranscriptionModel) else {
      return SettingsDefaults.selectedTranscriptionModel
    }
    if savedModelString == "gemini-2.0-flash-lite" {
      UserDefaults.standard.set(TranscriptionModel.gemini25FlashLite.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModel)
      return .gemini25FlashLite
    }
    if let savedModel = TranscriptionModel(rawValue: savedModelString) {
      return savedModel
    }
    UserDefaults.standard.set(
      SettingsDefaults.selectedTranscriptionModel.rawValue,
      forKey: UserDefaultsKeys.selectedTranscriptionModel)
    return SettingsDefaults.selectedTranscriptionModel
  }
  
  // MARK: - Model Availability
  /// Checks if this model is an offline model and if it's available
  /// - Returns: True if the model is offline and available, false otherwise
  func isOfflineModelAvailable() -> Bool {
    guard isOffline, let offlineModelType = offlineModelType else {
      return false
    }
    return ModelManager.shared.isModelAvailable(offlineModelType)
  }
  
}

// MARK: - Gemini Transcription Request Models
struct GeminiTranscriptionRequest: Codable {
  let contents: [GeminiTranscriptionContent]
  
  struct GeminiTranscriptionContent: Codable {
    let parts: [GeminiTranscriptionPart]
  }
  
  struct GeminiTranscriptionPart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
    let fileData: GeminiFileData?
    
    enum CodingKeys: String, CodingKey {
      case text
      case inlineData = "inline_data"
      case fileData = "file_data"
    }
  }
  
  struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String
    
    enum CodingKeys: String, CodingKey {
      case mimeType  // API returns "mimeType" (camelCase), not "mime_type"
      case data
    }
  }
  
  struct GeminiFileData: Codable {
    let fileUri: String
    let mimeType: String
    
    enum CodingKeys: String, CodingKey {
      case fileUri = "file_uri"
      case mimeType = "mime_type"
    }
  }
}

// MARK: - Gemini Response Models
struct GeminiResponse: Codable {
  let candidates: [GeminiCandidate]
  
  struct GeminiCandidate: Codable {
    let content: GeminiContent?
    let groundingMetadata: GeminiGroundingMetadata?
  }

  struct GeminiGroundingMetadata: Codable {
    let groundingChunks: [GeminiGroundingChunk]?
    let groundingSupports: [GeminiGroundingSupport]?
    let webSearchQueries: [String]?

    struct GeminiGroundingChunk: Codable {
      let web: WebSource?

      struct WebSource: Codable {
        let uri: String?
        let title: String?
      }
    }

    struct GeminiGroundingSupport: Codable {
      let segment: GeminiGroundingSegment?
      let groundingChunkIndices: [Int]?

      struct GeminiGroundingSegment: Codable {
        let startIndex: Int?
        let endIndex: Int?
      }
    }
  }
  
  struct GeminiContent: Codable {
    let parts: [GeminiPart]?
  }
  
  struct GeminiPart: Codable {
    let text: String?
    /// Code generated by the model for execution (Python only).
    let executableCode: ExecutableCode?
    /// Result of running the generated code (stdout on success).
    let codeExecutionResult: CodeExecutionResult?

    struct ExecutableCode: Codable {
      let language: String?
      let code: String?
    }

    struct CodeExecutionResult: Codable {
      let outcome: String?
      let output: String?
    }
  }
}

struct GeminiFileInfo: Codable {
  let file: GeminiFile
  
  struct GeminiFile: Codable {
    let uri: String
  }
}

// MARK: - Gemini Chat Request/Response Models (for multimodal prompt/voice response modes)
struct GeminiChatRequest: Codable {
  let contents: [GeminiChatContent]
  let systemInstruction: GeminiSystemInstruction?
  let tools: [GeminiTool]?
  let generationConfig: GeminiGenerationConfig?
  let model: String?  // Optional model field (required for TTS models)
  
  enum CodingKeys: String, CodingKey {
    case contents
    case systemInstruction = "system_instruction"
    case tools
    case generationConfig = "generationConfig"
    case model
  }
  
  // MARK: - Generation Config
  struct GeminiGenerationConfig: Codable {
    let responseModalities: [String]?
    let speechConfig: GeminiSpeechConfig?
    
    enum CodingKeys: String, CodingKey {
      case responseModalities = "responseModalities"
      case speechConfig = "speechConfig"
    }
  }
  
  struct GeminiChatContent: Codable {
    let role: String  // "user" or "model"
    let parts: [GeminiChatPart]
  }
  
  struct GeminiChatPart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
    let fileData: GeminiFileData?
    let url: String?
    
    enum CodingKeys: String, CodingKey {
      case text
      case inlineData = "inline_data"
      case fileData = "file_data"
      case url
    }
  }
  
  struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String
    
    enum CodingKeys: String, CodingKey {
      case mimeType  // API returns "mimeType" (camelCase), not "mime_type"
      case data
    }
  }
  
  struct GeminiFileData: Codable {
    let fileUri: String
    let mimeType: String
    
    enum CodingKeys: String, CodingKey {
      case fileUri = "file_uri"
      case mimeType = "mime_type"
    }
  }
  
  struct GeminiSystemInstruction: Codable {
    let parts: [GeminiSystemPart]
  }
  
  struct GeminiSystemPart: Codable {
    let text: String
  }
  
  // MARK: - Gemini Tools
  struct GeminiTool: Codable {
    let googleSearch: GoogleSearch?
    
    enum CodingKeys: String, CodingKey {
      case googleSearch = "google_search"
    }
    
    struct GoogleSearch: Codable {
      // Empty struct - Google Search tool requires no parameters
    }
  }
  
  // MARK: - Audio Output Configuration
  struct GeminiSpeechConfig: Codable {
    let voiceConfig: GeminiVoiceConfig?
    
    enum CodingKeys: String, CodingKey {
      case voiceConfig = "voice_config"
    }
  }
  
  struct GeminiVoiceConfig: Codable {
    let prebuiltVoiceConfig: GeminiPrebuiltVoiceConfig?
    
    enum CodingKeys: String, CodingKey {
      case prebuiltVoiceConfig = "prebuilt_voice_config"
    }
  }
  
  struct GeminiPrebuiltVoiceConfig: Codable {
    let voiceName: String
    
    enum CodingKeys: String, CodingKey {
      case voiceName = "voice_name"
    }
  }
}

struct GeminiChatResponse: Codable {
  let candidates: [GeminiChatCandidate]
  
  struct GeminiChatCandidate: Codable {
    let content: GeminiChatContent
    let finishReason: String?
    
    enum CodingKeys: String, CodingKey {
      case content
      case finishReason = "finish_reason"
    }
  }
  
  struct GeminiChatContent: Codable {
    let parts: [GeminiChatResponsePart]
    let role: String?
  }
  
  struct GeminiChatResponsePart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
    let functionCall: GeminiFunctionCall?
    
    enum CodingKeys: String, CodingKey {
      case text
      case inlineData  // API returns "inlineData" (camelCase), not "inline_data"
      case functionCall = "function_call"
    }
  }
  
  struct GeminiFunctionCall: Codable {
    let name: String?
    let args: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
      case name
      case args
    }
  }
  
  // Helper for decoding arbitrary JSON values in function call args
  struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
      self.value = value
    }
    
    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let bool = try? container.decode(Bool.self) {
        value = bool
      } else if let int = try? container.decode(Int.self) {
        value = int
      } else if let double = try? container.decode(Double.self) {
        value = double
      } else if let string = try? container.decode(String.self) {
        value = string
      } else if let array = try? container.decode([AnyCodable].self) {
        value = array.map { $0.value }
      } else if let dict = try? container.decode([String: AnyCodable].self) {
        value = dict.mapValues { $0.value }
      } else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "AnyCodable value cannot be decoded"
        )
      }
    }
    
    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch value {
      case let bool as Bool:
        try container.encode(bool)
      case let int as Int:
        try container.encode(int)
      case let double as Double:
        try container.encode(double)
      case let string as String:
        try container.encode(string)
      case let array as [Any]:
        try container.encode(array.map { AnyCodable($0) })
      case let dict as [String: Any]:
        try container.encode(dict.mapValues { AnyCodable($0) })
      default:
        throw EncodingError.invalidValue(
          value,
          EncodingError.Context(codingPath: container.codingPath, debugDescription: "AnyCodable value cannot be encoded")
        )
      }
    }
  }
  
  struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String
    
    enum CodingKeys: String, CodingKey {
      case mimeType  // API returns "mimeType" (camelCase), not "mime_type"
      case data
    }
  }
}

// MARK: - Gemini TTS (Generative Language API generateContent)
// Request/response for TTS via generativelanguage.googleapis.com; see https://ai.google.dev/gemini-api/docs/speech-generation
// API expects camelCase in JSON. Official docs use contents + generationConfig only (no systemInstruction).
// Style and literal reading are controlled via the text in contents (e.g. "Say the following: ...").
struct GeminiTTSRequest: Codable {
  let contents: [GeminiTTSContent]
  let generationConfig: GeminiTTSGenerationConfig

  struct GeminiTTSContent: Codable {
    let parts: [GeminiTTSPart]
  }

  struct GeminiTTSPart: Codable {
    let text: String
  }

  struct GeminiTTSGenerationConfig: Codable {
    let responseModalities: [String]
    let speechConfig: GeminiTTSSpeechConfig
  }

  struct GeminiTTSSpeechConfig: Codable {
    let voiceConfig: GeminiTTSVoiceConfig
  }

  struct GeminiTTSVoiceConfig: Codable {
    let prebuiltVoiceConfig: GeminiTTSPrebuiltVoiceConfig
  }

  struct GeminiTTSPrebuiltVoiceConfig: Codable {
    let voiceName: String
  }
}

// MARK: - Transcription Error
enum TranscriptionError: Error, Equatable {
  case noGoogleAPIKey
  case invalidAPIKey
  case incorrectAPIKey
  case countryNotSupported
  case invalidRequest
  case permissionDenied
  case notFound
  case modelDeprecated
  case rateLimited(retryAfter: TimeInterval?)
  case quotaExceeded(retryAfter: TimeInterval?)
  case serverError(Int)
  case serviceUnavailable
  case slowDown
  case networkError(String)
  case requestTimeout
  case resourceTimeout
  case fileError(String)
  case fileTooLarge
  case emptyFile
  case noSpeechDetected
  case textTooShort
  case promptLeakDetected
  case modelNotAvailable(OfflineModelType)
  /// Voice/output (TTS) is not available via Sign in with Google and balance; API key is required.
  case voiceRequiresAPIKey

  var title: String {
    switch self {
    case .noGoogleAPIKey: return "No Google API Key"
    case .invalidAPIKey: return "Invalid Authentication"
    case .incorrectAPIKey: return "Incorrect API Key"
    case .countryNotSupported: return "Country Not Supported"
    case .invalidRequest: return "Invalid Request"
    case .permissionDenied: return "Permission Denied"
    case .notFound: return "Not Found"
    case .modelDeprecated: return "Model No Longer Available"
    case .rateLimited: return "Rate Limited"
    case .quotaExceeded: return "Quota Exceeded"
    case .serverError: return "Server Error"
    case .serviceUnavailable: return "Service Unavailable"
    case .slowDown: return "Slow Down"
    case .networkError: return "Network Error"
    case .requestTimeout: return "Request Timeout"
    case .resourceTimeout: return "Resource Timeout"
    case .fileError: return "File Error"
    case .fileTooLarge: return "File Too Large"
    case .emptyFile: return "Empty File"
    case .noSpeechDetected: return "No Speech Detected"
    case .textTooShort: return "Text Too Short"
    case .promptLeakDetected: return "API Response Issue"
    case .modelNotAvailable: return "Model Not Downloaded"
    case .voiceRequiresAPIKey: return "Voice Requires API Key"
    }
  }

  /// Returns the retry delay if this error has one
  var retryAfter: TimeInterval? {
    switch self {
    case .rateLimited(let retryAfter), .quotaExceeded(let retryAfter):
      return retryAfter
    default:
      return nil
    }
  }
  
  /// Determines if this error is retryable (temporary/transient errors)
  var isRetryable: Bool {
    switch self {
    // Retryable errors (temporary issues)
    case .networkError, .requestTimeout, .resourceTimeout, .serverError, .serviceUnavailable, .slowDown:
      return true
    // Rate limited and quota exceeded are retryable if we have a retry delay
    case .rateLimited(let retryAfter):
      return retryAfter != nil
    case .quotaExceeded(let retryAfter):
      return retryAfter != nil
    // Non-retryable errors (configuration/permanent issues)
    case .noGoogleAPIKey, .invalidAPIKey, .incorrectAPIKey, .countryNotSupported, .permissionDenied, .notFound, .modelDeprecated, .fileError, .fileTooLarge, .emptyFile, .noSpeechDetected, .textTooShort, .promptLeakDetected, .modelNotAvailable, .invalidRequest, .voiceRequiresAPIKey:
      return false
    }
  }

  /// True for server-side errors (500, 503) where exponential backoff is beneficial.
  var isServerOrUnavailable: Bool {
    switch self {
    case .serverError, .serviceUnavailable: return true
    default: return false
    }
  }
}


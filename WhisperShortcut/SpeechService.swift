import AVFoundation
import Foundation

// MARK: - Constants
private enum Constants {
  static let maxFileSize = 25 * 1024 * 1024  // 25MB
  static let requestTimeout: TimeInterval = 30.0
  static let resourceTimeout: TimeInterval = 120.0
  static let validationTimeout: TimeInterval = 10.0
  static let transcriptionEndpoint = "https://api.openai.com/v1/audio/transcriptions"
  static let chatEndpoint = "https://api.openai.com/v1/chat/completions"
  static let responsesEndpoint = "https://api.openai.com/v1/responses"  // New GPT-5 API
  static let modelsEndpoint = "https://api.openai.com/v1/models"

  // Text validation
  static let minimumTextLength = 3

  // Audio validation
  static let supportedAudioExtensions = ["wav", "mp3", "m4a", "flac", "ogg", "webm"]

  // Timing delays
  static let clipboardCopyDelay: UInt64 = 100_000_000  // 0.1 seconds in nanoseconds
}

// MARK: - Transcription Model Enum
enum TranscriptionModel: String, CaseIterable {
  case gpt4oTranscribe = "gpt-4o-transcribe"
  case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"

  var displayName: String {
    switch self {
    case .gpt4oTranscribe:
      return "GPT-4o Transcribe"
    case .gpt4oMiniTranscribe:
      return "GPT-4o Mini Transcribe"
    }
  }

  var apiEndpoint: String {
    return Constants.transcriptionEndpoint
  }

  var isRecommended: Bool {
    switch self {
    case .gpt4oMiniTranscribe:
      return true
    case .gpt4oTranscribe:
      return false
    }
  }

  var costLevel: String {
    switch self {
    case .gpt4oMiniTranscribe:
      return "Low"
    case .gpt4oTranscribe:
      return "High"
    }
  }

  var description: String {
    switch self {
    case .gpt4oTranscribe:
      return "Highest accuracy and quality • Best for critical applications"
    case .gpt4oMiniTranscribe:
      return "Recommended • Great quality at lower cost • Best for everyday use"
    }
  }
}

// MARK: - Core Service
class SpeechService {

  // MARK: - Shared Infrastructure
  private let keychainManager: KeychainManaging
  private let ttsService: TTSService
  private let audioPlaybackService: AudioPlaybackService
  private var clipboardManager: ClipboardManager?

  // Custom session with appropriate timeouts
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = Constants.requestTimeout
    config.timeoutIntervalForResource = Constants.resourceTimeout
    return URLSession(configuration: config)
  }()

  // MARK: - Transcription Mode Properties
  private var selectedTranscriptionModel: TranscriptionModel = .gpt4oMiniTranscribe

  // MARK: - Prompt/Conversation State
  private var previousResponseId: String?            // Store previous response ID for conversation continuity
  private var previousResponseTimestamp: Date?       // Track when the last response was received

  init(
    keychainManager: KeychainManaging = KeychainManager.shared,
    clipboardManager: ClipboardManager? = nil
  ) {
    DebugLogger.logSpeech("🎤 SPEECH: SpeechService init called")
    self.keychainManager = keychainManager
    self.clipboardManager = clipboardManager
    self.ttsService = TTSService(keychainManager: keychainManager)
    self.audioPlaybackService = AudioPlaybackService.shared

  }

  // MARK: - Shared API Key Management
  private var apiKey: String? {
    keychainManager.getAPIKey()
  }

  func updateAPIKey(_ key: String) {
    _ = keychainManager.saveAPIKey(key)
  }

  func clearAPIKey() {
    _ = keychainManager.deleteAPIKey()
  }

  // MARK: - Transcription Mode Configuration
  func setModel(_ model: TranscriptionModel) {
    self.selectedTranscriptionModel = model
  }

  func getCurrentModel() -> TranscriptionModel {
    return selectedTranscriptionModel
  }

  // MARK: - Conversation Management
  func clearConversationHistory() {
    previousResponseId = nil
    previousResponseTimestamp = nil
  }

  internal func isConversationExpired(isVoiceResponse: Bool) -> Bool {
    guard let timestamp = previousResponseTimestamp else {
      return true  // No previous conversation
    }

    // Read per-mode timeout from settings
    let key = isVoiceResponse
      ? "voiceResponseConversationTimeoutMinutes" : "promptConversationTimeoutMinutes"

    // If not set, fall back to defaults (1 minute as requested)
    var timeoutMinutes = UserDefaults.standard.object(forKey: key) as? Double
    if timeoutMinutes == nil {
      // Fallback default per mode
      timeoutMinutes = 1.0
    }

    // Never: 0.0 means no expiry
    if let t = timeoutMinutes, t == 0.0 {
      return false
    }

    let effectiveMinutes = (timeoutMinutes ?? 1.0)
    let expirationTime = timestamp.addingTimeInterval(effectiveMinutes * 60)  // Convert to seconds
    let isExpired = Date() > expirationTime

    if isExpired {
      clearConversationHistory()
    }

    return isExpired
  }

  // MARK: - Shared Validation
  func validateAPIKey(_ key: String) async throws -> Bool {
    guard !key.isEmpty else {
      DebugLogger.logWarning("API key is empty")
      throw TranscriptionError.noAPIKey
    }

    let url = URL(string: Constants.modelsEndpoint)!
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = Constants.validationTimeout

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      DebugLogger.logWarning("Invalid response from API validation")
      throw TranscriptionError.networkError("Invalid response")
    }

    if httpResponse.statusCode != 200 {
      DebugLogger.logWarning("API validation failed with status \(httpResponse.statusCode)")
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    return true
  }

  // MARK: - Transcription Mode
  func transcribe(audioURL: URL) async throws -> String {
    DebugLogger.logSpeech("🎤 TRANSCRIPTION-MODE: Starting transcription for \(audioURL.lastPathComponent)")

    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      DebugLogger.logError("❌ TRANSCRIPTION-MODE: No API key available")
      throw TranscriptionError.noAPIKey
    }

    try validateAudioFile(at: audioURL)

    let request = try createTranscriptionRequest(audioURL: audioURL, apiKey: apiKey)
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      DebugLogger.logError("❌ TRANSCRIPTION-MODE: Invalid response type")
      throw TranscriptionError.networkError("Invalid response")
    }

    if httpResponse.statusCode != 200 {
      DebugLogger.logError("❌ TRANSCRIPTION-MODE: HTTP error \(httpResponse.statusCode)")
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
    try validateSpeechText(result.text, mode: "TRANSCRIPTION-MODE")
    DebugLogger.logSpeech("✅ TRANSCRIPTION-MODE: Returning transcribed text")

    return result.text
  }

  // MARK: - Prompt Modes
  func executePrompt(audioURL: URL) async throws -> String {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      DebugLogger.logWarning("PROMPT-MODE: No API key available")
      throw TranscriptionError.noAPIKey
    }

    let spokenText = try await transcribe(audioURL: audioURL)
    try validateSpeechText(spokenText, mode: "PROMPT-MODE")

    let clipboardContext = getClipboardContext()
    return try await executeGPT5Prompt(
      userMessage: spokenText, clipboardContext: clipboardContext, apiKey: apiKey)
  }

  func executePromptWithVoiceResponse(audioURL: URL, clipboardContext: String? = nil) async throws
    -> String
  {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      DebugLogger.logWarning("VOICE-RESPONSE-MODE: No API key available")
      throw TranscriptionError.noAPIKey
    }

    let spokenText = try await transcribe(audioURL: audioURL)
    try validateSpeechText(spokenText, mode: "PROMPT-MODE")

    let contextToUse = clipboardContext ?? getClipboardContext()

    let response = try await executeGPT5PromptForVoiceResponse(
      userMessage: spokenText, clipboardContext: contextToUse, apiKey: apiKey)

    clipboardManager?.copyToClipboard(text: response)

    let playbackSpeed = UserDefaults.standard.double(forKey: "voiceResponsePlaybackSpeed")
    let speed = playbackSpeed > 0 ? playbackSpeed : 1.0

    let audioData: Data
    do {
      audioData = try await ttsService.generateSpeech(text: response, speed: speed)
    } catch let ttsError as TTSError {
      DebugLogger.logError("VOICE-RESPONSE-MODE: TTS error: \(ttsError.localizedDescription)")
      throw TranscriptionError.ttsError(ttsError)
    } catch {
      DebugLogger.logError(
        "VOICE-RESPONSE-MODE: Unexpected TTS error: \(error.localizedDescription)")
      throw TranscriptionError.networkError("Text-to-speech failed: \(error.localizedDescription)")
    }

    NotificationCenter.default.post(
      name: NSNotification.Name("VoiceResponseReadyToSpeak"), object: nil)

    await MainActor.run {
      NotificationCenter.default.post(
        name: NSNotification.Name("VoicePlaybackStartedWithText"),
        object: nil,
        userInfo: ["responseText": response]
      )
    }

    let playbackResult = try await audioPlaybackService.playAudio(data: audioData)

    switch playbackResult {
    case .completedSuccessfully: break
    case .stoppedByUser: break
    case .failed:
      DebugLogger.logError("VOICE-RESPONSE-MODE: Audio playback failed due to system error")
      throw TranscriptionError.networkError("Audio playback failed")
    }

    return response
  }

  // MARK: - Transcription Mode Helpers
  private func createTranscriptionRequest(audioURL: URL, apiKey: String) throws -> URLRequest {
    let apiURL = URL(string: selectedTranscriptionModel.apiEndpoint)!
    var request = URLRequest(url: apiURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    return try createMultipartRequest(request: &request, audioURL: audioURL)
  }

  private func validateSpeechText(_ text: String, mode: String = "TRANSCRIPTION-MODE") throws {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmedText.isEmpty || trimmedText.count < Constants.minimumTextLength {
      DebugLogger.logWarning("\(mode): No meaningful speech detected")
      throw TranscriptionError.noSpeechDetected
    }

    let defaultPrompt = AppConstants.defaultTranscriptionSystemPrompt
    if trimmedText.contains(defaultPrompt) || trimmedText.hasPrefix("context:") {
      DebugLogger.logWarning("\(mode): System prompt detected in transcription")
      throw TranscriptionError.noSpeechDetected
    }
  }

  private func sanitizeUserInput(_ input: String) -> String {
    let sanitized = input.trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.filter { char in
      let scalar = char.unicodeScalars.first!
      return !CharacterSet.controlCharacters.contains(scalar) || char == "\n" || char == "\t"
    }
  }

  func readSelectedTextAsSpeech() async throws -> String {
    captureSelectedText()
    try await Task.sleep(nanoseconds: Constants.clipboardCopyDelay)

    guard let selectedText = getClipboardContext(), !selectedText.isEmpty else {
      DebugLogger.logWarning("SELECTED-TEXT-TTS: No text found in selection")
      throw TranscriptionError.networkError("No text selected to read")
    }

    let playbackSpeed = UserDefaults.standard.double(forKey: "readSelectedTextPlaybackSpeed")
    let speed = playbackSpeed > 0 ? playbackSpeed : 1.0

    let audioData: Data
    do {
      audioData = try await ttsService.generateSpeech(text: selectedText, speed: speed)
    } catch let ttsError as TTSError {
      DebugLogger.logError("SELECTED-TEXT-TTS: TTS error: \(ttsError.localizedDescription)")
      DebugLogger.logError("SELECTED-TEXT-TTS: TTS error type: \(ttsError)")
      throw TranscriptionError.ttsError(ttsError)
    } catch {
      DebugLogger.logError("SELECTED-TEXT-TTS: Unexpected TTS error: \(error.localizedDescription)")
      throw TranscriptionError.networkError("Text-to-speech failed: \(error.localizedDescription)")
    }

    NotificationCenter.default.post(
      name: NSNotification.Name("ReadSelectedTextReadyToSpeak"),
      object: nil,
      userInfo: ["selectedText": selectedText]
    )

    let playbackResult = try await audioPlaybackService.playAudio(
      data: audioData, playbackType: .readSelectedText)

    switch playbackResult {
    case .completedSuccessfully: break
    case .stoppedByUser: break
    case .failed:
      DebugLogger.logError("SELECTED-TEXT-TTS: Audio playback failed due to system error")
      throw TranscriptionError.networkError("Audio playback failed")
    }

    return selectedText
  }

  // MARK: - Prompt Mode Helpers
  private func getClipboardContext() -> String? {
    guard let clipboardManager = clipboardManager else { return nil }
    guard let clipboardText = clipboardManager.getClipboardText() else { return nil }

    let trimmedText = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return nil }
    return trimmedText
  }

  private func captureSelectedText() {
    let source = CGEventSource(stateID: .combinedSessionState)
    let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)  // C key
    let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
    cmdDown?.flags = .maskCommand
    cmdUp?.flags = .maskCommand
    cmdDown?.post(tap: .cghidEventTap)
    cmdUp?.post(tap: .cghidEventTap)
  }

  private func executeGPT5Prompt(userMessage: String, clipboardContext: String?, apiKey: String)
    async throws -> String
  {
    return try await executeGPT5Response(
      userMessage: userMessage, clipboardContext: clipboardContext, apiKey: apiKey,
      isVoiceResponse: false)
  }

  private func executeGPT5PromptForVoiceResponse(
    userMessage: String, clipboardContext: String?, apiKey: String
  )
    async throws -> String
  {
    return try await executeGPT5Response(
      userMessage: userMessage, clipboardContext: clipboardContext, apiKey: apiKey,
      isVoiceResponse: true)
  }

  private func executeGPT5Response(
    userMessage: String, clipboardContext: String?, apiKey: String, isVoiceResponse: Bool = false
  )
    async throws -> String
  {
    let modelKey = isVoiceResponse ? "selectedVoiceResponseModel" : "selectedPromptModel"
    let selectedGPTModelString =
      UserDefaults.standard.string(forKey: modelKey) ?? "gpt-5-mini"
    let selectedGPTModel = GPTModel(rawValue: selectedGPTModelString) ?? .gpt5Mini

    let url = URL(string: Constants.responsesEndpoint)!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let fullInput = buildPromptInput(
      userMessage: userMessage, clipboardContext: clipboardContext, isVoiceResponse: isVoiceResponse
    )

    let reasoningConfig: GPT5ResponseRequest.ReasoningConfig?
    if selectedGPTModel.supportsReasoning {
      let reasoningEffortKey =
        isVoiceResponse ? "voiceResponseReasoningEffort" : "promptReasoningEffort"
      let defaultReasoningEffort =
        isVoiceResponse
        ? SettingsDefaults.voiceResponseReasoningEffort.rawValue
        : SettingsDefaults.promptReasoningEffort.rawValue
      let savedReasoningEffort =
        UserDefaults.standard.string(forKey: reasoningEffortKey) ?? defaultReasoningEffort
      reasoningConfig = GPT5ResponseRequest.ReasoningConfig(effort: savedReasoningEffort)
      DebugLogger.logInfo(
        "PROMPT-MODE: Using reasoning effort '\(savedReasoningEffort)' for model \(selectedGPTModel.rawValue)"
      )
    } else {
      reasoningConfig = nil
      DebugLogger.logInfo(
        "PROMPT-MODE: Model \(selectedGPTModel.rawValue) does not support reasoning parameters")
    }

    let effectivePreviousResponseId = isConversationExpired(isVoiceResponse: isVoiceResponse)
      ? nil : previousResponseId

    let gpt5Request = GPT5ResponseRequest(
      model: selectedGPTModel.rawValue,
      input: fullInput,
      reasoning: reasoningConfig,
      text: GPT5ResponseRequest.TextConfig(verbosity: "medium"),
      previous_response_id: effectivePreviousResponseId
    )

    request.httpBody = try JSONEncoder().encode(gpt5Request)

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      DebugLogger.logWarning("PROMPT-MODE: Invalid response type from GPT-5")
      throw TranscriptionError.networkError("Invalid response")
    }

    if httpResponse.statusCode != 200 {
      DebugLogger.logWarning("PROMPT-MODE: GPT-5 HTTP error \(httpResponse.statusCode)")
      if let errorBody = String(data: data, encoding: .utf8) {
        DebugLogger.logWarning("PROMPT-MODE: Error response body: \(errorBody)")
      }
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    let result = try parseGPT5Response(data: data)
    return result
  }

  private func buildPromptInput(
    userMessage: String, clipboardContext: String?, isVoiceResponse: Bool = false
  ) -> String {
    let baseSystemPrompt: String
    let customSystemPromptKey: String

    if isVoiceResponse {
      baseSystemPrompt = AppConstants.defaultVoiceResponseSystemPrompt
      customSystemPromptKey = "voiceResponseSystemPrompt"
    } else {
      baseSystemPrompt = AppConstants.defaultPromptModeSystemPrompt
      customSystemPromptKey = "promptModeSystemPrompt"
    }

    let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptKey)

    var fullInput = baseSystemPrompt
    if let customPrompt = customSystemPrompt, !customPrompt.isEmpty {
      fullInput += "\n\nAdditional instructions: \(customPrompt)"
    }

    if let context = clipboardContext {
      fullInput += "\n\nContext (selected text from clipboard):\n\(context)"
    }

    let sanitizedUserMessage = sanitizeUserInput(userMessage)
    fullInput += "\n\nUser: \(sanitizedUserMessage)"
    return fullInput
  }

  private func parseGPT5Response(data: Data) throws -> String {
    do {
      let result = try JSONDecoder().decode(GPT5ResponseResponse.self, from: data)

      previousResponseId = result.id
      previousResponseTimestamp = Date()

      for output in result.output {
        if output.type == "message" {
          for content in output.content ?? [] {
            if content.type == "output_text" {
              return content.text
            }
          }
        }
      }

      if (try? JSONSerialization.jsonObject(with: data, options: [])) != nil {
        DebugLogger.logWarning(
          "PROMPT-MODE: Unexpected response structure, attempting fallback parsing")
      }

      throw TranscriptionError.networkError("Could not extract text from GPT-5 response")
    } catch {
      if (try? JSONSerialization.jsonObject(with: data, options: [])) != nil {
        DebugLogger.logWarning("PROMPT-MODE: Failed to decode response, raw structure available")
      }

      throw error
    }
  }

  // MARK: - Testing and Debugging
  func testGPT5Request() async throws -> String {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      DebugLogger.logWarning("TEST: No API key available")
      throw TranscriptionError.noAPIKey
    }

    let testRequest = GPT5ResponseRequest(
      model: "gpt-5-chat-latest",
      input: "Hello, this is a test message.",
      reasoning: nil,
      text: nil,
      previous_response_id: nil
    )

    let url = URL(string: Constants.responsesEndpoint)!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    request.httpBody = try JSONEncoder().encode(testRequest)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      DebugLogger.logWarning("TEST: Invalid response type")
      throw TranscriptionError.networkError("Invalid response type")
    }

    if httpResponse.statusCode != 200 {
      DebugLogger.logWarning("TEST: HTTP error \(httpResponse.statusCode)")
      if let errorBody = String(data: data, encoding: .utf8) {
        DebugLogger.logWarning("TEST: Error body: \(errorBody)")
      }
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    let result = try JSONDecoder().decode(GPT5ResponseResponse.self, from: data)

    for output in result.output {
      if output.type == "message" {
        for content in output.content ?? [] {
          if content.type == "output_text" {
            return content.text
          }
        }
      }
    }

    throw TranscriptionError.networkError("Could not extract text from test response")
  }

  // MARK: - Shared Infrastructure Helpers
  private func validateAudioFile(at url: URL) throws {
    let fileExtension = url.pathExtension.lowercased()
    if !Constants.supportedAudioExtensions.contains(fileExtension) {
      DebugLogger.logWarning("Unsupported audio format: \(fileExtension)")
      throw TranscriptionError.fileError("Unsupported audio format: \(fileExtension)")
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let fileSize = attributes[.size] as? Int64 else {
      DebugLogger.logWarning("Cannot read file size")
      throw TranscriptionError.fileError("Cannot read file size")
    }

    if fileSize == 0 {
      DebugLogger.logWarning("Empty audio file")
      throw TranscriptionError.emptyFile
    }

    if fileSize > Constants.maxFileSize {
      DebugLogger.logWarning("File too large (\(fileSize) > \(Constants.maxFileSize))")
      throw TranscriptionError.fileTooLarge
    }
  }

  private func createMultipartRequest(request: inout URLRequest, audioURL: URL) throws -> URLRequest {
    let boundary = "Boundary-\(UUID().uuidString)"

    var fields: [String: String] = [
      "model": selectedTranscriptionModel.rawValue,
      "response_format": "json",
    ]

    if selectedTranscriptionModel == .gpt4oTranscribe
      || selectedTranscriptionModel == .gpt4oMiniTranscribe
    {
      if let customPrompt = UserDefaults.standard.string(forKey: "customPromptText"),
        !customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        fields["prompt"] = customPrompt
      }
    }

    let audioData = try Data(contentsOf: audioURL)

    let files: [String: (filename: String, contentType: String, data: Data)] = [
      "file": (filename: "audio.wav", contentType: "audio/wav", data: audioData)
    ]

    request.setMultipartFormData(boundary: boundary, fields: fields, files: files)
    return request
  }

  private func parseErrorResponse(data: Data, statusCode: Int) throws -> TranscriptionError {
    if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
      return parseOpenAIError(errorResponse, statusCode: statusCode)
    }
    return parseStatusCodeError(statusCode)
  }

  private func parseOpenAIError(_ errorResponse: OpenAIErrorResponse, statusCode: Int)
    -> TranscriptionError
  {
    let errorMessage = errorResponse.error?.message?.lowercased() ?? ""
    let errorType = errorResponse.error?.type?.lowercased() ?? ""

    switch statusCode {
    case 401:
      if errorMessage.contains("incorrect api key") && !errorMessage.contains("invalid") {
        return .incorrectAPIKey
      } else {
        return .invalidAPIKey
      }
    case 403:
      if errorMessage.contains("country") || errorMessage.contains("region")
        || errorMessage.contains("territory")
      {
        return .countryNotSupported
      } else {
        return .permissionDenied
      }
    case 429:
      if errorMessage.contains("quota") || errorMessage.contains("billing")
        || errorMessage.contains("exceeded")
      {
        return .quotaExceeded
      } else {
        return .rateLimited
      }
    case 503:
      if errorMessage.contains("slow down") || errorType.contains("slow_down") {
        return .slowDown
      } else {
        return .serviceUnavailable
      }
    default:
      return parseStatusCodeError(statusCode)
    }
  }

  private func parseStatusCodeError(_ statusCode: Int) -> TranscriptionError {
    switch statusCode {
    case 400: return .invalidRequest
    case 401: return .invalidAPIKey
    case 403: return .permissionDenied
    case 404: return .notFound
    case 429: return .rateLimited
    case 500: return .serverError(statusCode)
    case 503: return .serviceUnavailable
    default: return .serverError(statusCode)
    }
  }
}

// MARK: - Data Extensions
extension Data {
  mutating func append(_ string: String) {
    if let data = string.data(using: .utf8) {
      append(data)
    }
  }
}

// MARK: - Multipart Form Data Extension
extension URLRequest {
  mutating func setMultipartFormData(
    boundary: String, fields: [String: String],
    files: [String: (filename: String, contentType: String, data: Data)]
  ) {
    setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()

    for (name, value) in fields {
      body.append("--\(boundary)\r\n")
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
      body.append("\(value)\r\n")
    }

    for (name, file) in files {
      body.append("--\(boundary)\r\n")
      body.append(
        "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(file.filename)\"\r\n")
      body.append("Content-Type: \(file.contentType)\r\n\r\n")
      body.append(file.data)
      body.append("\r\n")
    }

    body.append("--\(boundary)--\r\n")
    httpBody = body
  }
}

// MARK: - Models
struct WhisperResponse: Codable {
  let text: String
}

struct ChatCompletionRequest: Codable {
  let model: String
  let messages: [ChatMessage]
  let maxTokens: Int
  let temperature: Double

  enum CodingKeys: String, CodingKey {
    case model, messages, temperature
    case maxTokens = "max_tokens"
  }
}

struct ChatMessage: Codable {
  let role: String
  let content: String
}

struct ChatCompletionResponse: Codable {
  let choices: [ChatChoice]
}

struct ChatChoice: Codable {
  let message: ChatMessage
}

// GPT-5 Responses API Models (New)
struct GPT5ResponseRequest: Codable {
  let model: String
  let input: String
  let reasoning: ReasoningConfig?
  let text: TextConfig?
  let previous_response_id: String?

  struct ReasoningConfig: Codable {
    let effort: String
  }

  struct TextConfig: Codable {
    let verbosity: String
  }
}

struct GPT5ResponseResponse: Codable {
  let output: [GPT5Output]
  let id: String

  struct GPT5Output: Codable {
    let type: String
    let content: [GPT5Content]?

    struct GPT5Content: Codable {
      let type: String
      let text: String
    }
  }
}

struct TranscriptionPrompt {
  let text: String

  static let defaultPrompt = TranscriptionPrompt(
    text: AppConstants.defaultTranscriptionSystemPrompt)
}

struct OpenAIErrorResponse: Codable {
  let error: OpenAIError?
}

struct OpenAIError: Codable {
  let message: String?
  let type: String?
  let code: String?
}

// MARK: - Error Types
enum TranscriptionError: Error, Equatable {
  case noAPIKey
  case invalidAPIKey
  case incorrectAPIKey
  case countryNotSupported
  case invalidRequest
  case permissionDenied
  case notFound
  case rateLimited
  case quotaExceeded
  case serverError(Int)
  case serviceUnavailable
  case slowDown
  case networkError(String)
  case fileError(String)
  case fileTooLarge
  case emptyFile
  case noSpeechDetected
  case ttsError(TTSError)

  var title: String {
    switch self {
    case .noAPIKey: return "No API Key"
    case .invalidAPIKey: return "Invalid Authentication"
    case .incorrectAPIKey: return "Incorrect API Key"
    case .countryNotSupported: return "Country Not Supported"
    case .invalidRequest: return "Invalid Request"
    case .permissionDenied: return "Permission Denied"
    case .notFound: return "Not Found"
    case .rateLimited: return "Rate Limited"
    case .quotaExceeded: return "Quota Exceeded"
    case .serverError: return "Server Error"
    case .serviceUnavailable: return "Service Unavailable"
    case .slowDown: return "Slow Down"
    case .networkError: return "Network Error"
    case .fileError: return "File Error"
    case .fileTooLarge: return "File Too Large"
    case .emptyFile: return "Empty File"
    case .noSpeechDetected: return "No Speech Detected"
    case .ttsError: return "Text-to-Speech Error"
    }
  }
}

// MARK: - Error Result Parser
extension SpeechService {
  static func parseTranscriptionResult(_ text: String) -> (
    isError: Bool, errorType: TranscriptionError?
  ) {
    let errorPrefixes = ["❌", "⚠️", "⏰", "⏳", "🔄"]
    let isError = errorPrefixes.contains { text.hasPrefix($0) }

    guard isError else {
      return (false, nil)
    }

    if text.contains("No API Key") {
      return (true, .noAPIKey)
    } else if text.contains("Incorrect API Key") {
      return (true, .incorrectAPIKey)
    } else if text.contains("Country Not Supported") {
      return (true, .countryNotSupported)
    } else if text.contains("Authentication") || text.contains("invalid API key") {
      return (true, .invalidAPIKey)
    } else if text.contains("Rate Limit") {
      return (true, .rateLimited)
    } else if text.contains("Quota Exceeded") {
      return (true, .quotaExceeded)
    } else if text.contains("Timeout") {
      return (true, .networkError("Timeout"))
    } else if text.contains("Network Error") {
      return (true, .networkError("Network"))
    } else if text.contains("Server Error") {
      return (true, .serverError(500))
    } else if text.contains("Service Unavailable") {
      return (true, .serviceUnavailable)
    } else if text.contains("Slow Down") {
      return (true, .slowDown)
    } else if text.contains("File Too Large") {
      return (true, .fileTooLarge)
    } else if text.contains("Empty") {
      return (true, .emptyFile)
    } else {
      return (true, .serverError(0))
    }
  }
}

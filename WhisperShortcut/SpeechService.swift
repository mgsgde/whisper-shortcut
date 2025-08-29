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
  private var selectedModel: TranscriptionModel = .gpt4oMiniTranscribe

  // MARK: - Prompt Mode Properties
  private var previousResponseId: String?  // Store previous response ID for conversation continuity

  init(
    keychainManager: KeychainManaging = KeychainManager.shared,
    clipboardManager: ClipboardManager? = nil
  ) {
    self.keychainManager = keychainManager
    self.clipboardManager = clipboardManager
    self.ttsService = TTSService(keychainManager: keychainManager)
    self.audioPlaybackService = AudioPlaybackService()
    NSLog("🔧 SpeechService initialized with keychain, clipboard, TTS, and audio playback services")
  }

  // MARK: - Shared API Key Management
  private var apiKey: String? {
    keychainManager.getAPIKey()
  }

  func updateAPIKey(_ key: String) {
    NSLog("🔑 API key updated")
    _ = keychainManager.saveAPIKey(key)
  }

  func clearAPIKey() {
    NSLog("🔑 API key cleared")
    _ = keychainManager.deleteAPIKey()
  }

  // MARK: - Transcription Mode Configuration
  func setModel(_ model: TranscriptionModel) {
    NSLog("🎙️ TRANSCRIPTION-MODE: Model set to \(model.displayName)")
    self.selectedModel = model
  }

  func getCurrentModel() -> TranscriptionModel {
    return selectedModel
  }

  // MARK: - Prompt Mode Configuration
  func clearConversationHistory() {
    NSLog("🤖 PROMPT-MODE: Conversation history cleared")
    previousResponseId = nil
  }

  // MARK: - Shared Validation
  func validateAPIKey(_ key: String) async throws -> Bool {
    NSLog("🔑 Validating API key...")

    guard !key.isEmpty else {
      NSLog("⚠️ Error: API key is empty")
      throw TranscriptionError.noAPIKey
    }

    let url = URL(string: Constants.modelsEndpoint)!
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = Constants.validationTimeout

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      NSLog("⚠️ Error: Invalid response from API validation")
      throw TranscriptionError.networkError("Invalid response")
    }

    if httpResponse.statusCode != 200 {
      NSLog("⚠️ Error: API validation failed with status \(httpResponse.statusCode)")
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    NSLog("✅ API key validation successful")
    return true
  }

  // MARK: - Transcription Mode
  /// Pure transcription using GPT-4o-transcribe models
  func transcribe(audioURL: URL) async throws -> String {
    NSLog("🎙️ TRANSCRIPTION-MODE: Starting transcription with model \(selectedModel.displayName)")

    // Validate API key
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      NSLog("⚠️ TRANSCRIPTION-MODE: No API key available")
      throw TranscriptionError.noAPIKey
    }

    // Validate file
    try validateAudioFile(at: audioURL)
    NSLog("🎙️ TRANSCRIPTION-MODE: Audio file validated")

    // Create transcription request
    let request = try createTranscriptionRequest(audioURL: audioURL, apiKey: apiKey)

    // Execute request
    NSLog("🎙️ TRANSCRIPTION-MODE: Sending request to \(selectedModel.apiEndpoint)")
    let (data, response) = try await session.data(for: request)

    // Validate response
    guard let httpResponse = response as? HTTPURLResponse else {
      NSLog("⚠️ TRANSCRIPTION-MODE: Invalid response type")
      throw TranscriptionError.networkError("Invalid response")
    }

    // Check if the response indicates an error
    if httpResponse.statusCode != 200 {
      NSLog("⚠️ TRANSCRIPTION-MODE: HTTP error \(httpResponse.statusCode)")
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    // Parse result
    let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
    NSLog("✅ TRANSCRIPTION-MODE: Transcription successful, text length: \(result.text.count)")

    // Validate transcribed text for empty/silent audio
    try validateTranscribedText(result.text)
    NSLog("✅ TRANSCRIPTION-MODE: Text validation passed")

    return result.text
  }

  // MARK: - Prompt Mode
  /// Transcribe audio and execute as prompt with GPT-5
  func executePrompt(audioURL: URL) async throws -> String {
    NSLog("🤖 PROMPT-MODE: Starting prompt execution")

    // Validate API key
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      NSLog("⚠️ PROMPT-MODE: No API key available")
      throw TranscriptionError.noAPIKey
    }

    // First, transcribe the audio to get the user's spoken text
    NSLog("🤖 PROMPT-MODE: Transcribing user input...")
    let spokenText = try await transcribe(audioURL: audioURL)
    NSLog("🤖 PROMPT-MODE: User input transcribed: '\(spokenText)'")

    // Validate spoken text
    try validateSpokenText(spokenText)
    NSLog("🤖 PROMPT-MODE: Spoken text validation passed")

    // Get clipboard content as context if available
    let clipboardContext = getClipboardContext()
    if let context = clipboardContext {
      NSLog("🤖 PROMPT-MODE: Clipboard context found (length: \(context.count))")
    } else {
      NSLog("🤖 PROMPT-MODE: No clipboard context available")
    }

    // Execute prompt with GPT-5
    return try await executeGPT5Prompt(
      userMessage: spokenText, clipboardContext: clipboardContext, apiKey: apiKey)
  }

  /// Execute prompt and play response as speech instead of copying to clipboard
  func executePromptWithVoiceResponse(audioURL: URL, clipboardContext: String? = nil) async throws
    -> String
  {
    NSLog("🔊 VOICE-RESPONSE-MODE: Starting prompt execution for voice output")

    // Validate API key
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      NSLog("⚠️ VOICE-RESPONSE-MODE: No API key available")
      throw TranscriptionError.noAPIKey
    }

    // First, transcribe the audio to get the user's spoken text
    NSLog("🔊 VOICE-RESPONSE-MODE: Transcribing user input...")
    let spokenText = try await transcribe(audioURL: audioURL)
    NSLog("🔊 VOICE-RESPONSE-MODE: User input transcribed: '\(spokenText)'")

    // Validate spoken text
    try validateSpokenText(spokenText)
    NSLog("🔊 VOICE-RESPONSE-MODE: Spoken text validation passed")

    // Use provided clipboard context or get current clipboard
    let contextToUse = clipboardContext ?? getClipboardContext()
    if let context = contextToUse {
      NSLog("🔊 VOICE-RESPONSE-MODE: Context found (length: \(context.count))")
    } else {
      NSLog("🔊 VOICE-RESPONSE-MODE: No context available")
    }

    // Execute prompt with GPT-5
    NSLog("🔊 VOICE-RESPONSE-MODE: Executing GPT-5 prompt...")
    let response = try await executeGPT5Prompt(
      userMessage: spokenText, clipboardContext: contextToUse, apiKey: apiKey)
    NSLog("🔊 VOICE-RESPONSE-MODE: GPT-5 response received (length: \(response.count))")

    // Copy response to clipboard immediately (same as normal prompt mode)
    NSLog("🔊 VOICE-RESPONSE-MODE: Copying response to clipboard...")
    clipboardManager?.copyToClipboard(text: response)
    NSLog("✅ VOICE-RESPONSE-MODE: Response copied to clipboard")

    // Generate speech from response
    NSLog("🔊 VOICE-RESPONSE-MODE: Generating speech from response...")

    let audioData: Data
    do {
      audioData = try await ttsService.generateSpeech(text: response)
      NSLog("🔊 VOICE-RESPONSE-MODE: Speech generated (\(audioData.count) bytes)")
    } catch let ttsError as TTSError {
      NSLog("❌ VOICE-RESPONSE-MODE: TTS error: \(ttsError.localizedDescription)")
      throw TranscriptionError.networkError(ttsError.localizedDescription)
    } catch {
      NSLog("❌ VOICE-RESPONSE-MODE: Unexpected TTS error: \(error.localizedDescription)")
      throw TranscriptionError.networkError("Text-to-speech failed: \(error.localizedDescription)")
    }

    // Play the audio response
    NSLog("🔊 VOICE-RESPONSE-MODE: Playing audio response...")
    let playbackSuccess = try await audioPlaybackService.playAudio(data: audioData)

    if playbackSuccess {
      NSLog("✅ VOICE-RESPONSE-MODE: Audio response played successfully")
    } else {
      NSLog("⚠️ VOICE-RESPONSE-MODE: Audio playback failed")
      throw TranscriptionError.networkError("Audio playback failed")
    }

    return response
  }

  // MARK: - Transcription Mode Helpers
  private func createTranscriptionRequest(audioURL: URL, apiKey: String) throws -> URLRequest {
    NSLog("🎙️ TRANSCRIPTION-MODE: Creating request for \(selectedModel.rawValue)")

    let apiURL = URL(string: selectedModel.apiEndpoint)!
    var request = URLRequest(url: apiURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    // Create multipart form data using a more elegant approach
    return try createMultipartRequest(request: &request, audioURL: audioURL)
  }

  private func validateTranscribedText(_ transcribedText: String) throws {
    NSLog("🎙️ TRANSCRIPTION-MODE: Validating transcribed text")

    // Check if meaningful speech was detected
    let trimmedText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)

    // Check for empty or very short text
    if trimmedText.isEmpty || trimmedText.count < 3 {
      NSLog("⚠️ TRANSCRIPTION-MODE: No meaningful speech detected")
      throw TranscriptionError.noSpeechDetected
    }

    // Check if the transcription returned the system prompt itself (common with silent audio)
    let defaultPrompt = AppConstants.defaultTranscriptionSystemPrompt
    if trimmedText.contains(defaultPrompt) || trimmedText.hasPrefix("context:") {
      NSLog("⚠️ TRANSCRIPTION-MODE: System prompt detected in transcription")
      throw TranscriptionError.noSpeechDetected
    }

    NSLog("🎙️ TRANSCRIPTION-MODE: Text validation successful")
  }

  // MARK: - Prompt Mode Helpers
  private func validateSpokenText(_ spokenText: String) throws {
    // Check if meaningful speech was detected
    let trimmedText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)

    // Check for empty or very short text
    if trimmedText.isEmpty || trimmedText.count < 3 {
      NSLog("⚠️ PROMPT-MODE: No meaningful speech detected")
      throw TranscriptionError.noSpeechDetected
    }

    // Check if the transcription returned the system prompt itself (common with silent audio)
    let defaultPrompt = AppConstants.defaultTranscriptionSystemPrompt
    if trimmedText.contains(defaultPrompt) || trimmedText.hasPrefix("context:") {
      NSLog("⚠️ PROMPT-MODE: System prompt detected in transcription")
      throw TranscriptionError.noSpeechDetected
    }
  }

  private func getClipboardContext() -> String? {
    guard let clipboardManager = clipboardManager else {
      return nil
    }

    guard let clipboardText = clipboardManager.getClipboardText() else {
      return nil
    }

    let trimmedText = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedText.isEmpty else {
      return nil
    }

    return trimmedText
  }

  private func executeGPT5Prompt(userMessage: String, clipboardContext: String?, apiKey: String)
    async throws -> String
  {
    NSLog("🤖 PROMPT-MODE: Executing GPT-5 prompt")
    return try await executeGPT5Response(
      userMessage: userMessage, clipboardContext: clipboardContext, apiKey: apiKey)
  }

  private func executeGPT5Response(userMessage: String, clipboardContext: String?, apiKey: String)
    async throws -> String
  {
    NSLog("🤖 PROMPT-MODE: Building GPT-5 request")

    let url = URL(string: Constants.responsesEndpoint)!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // Build prompt input
    let fullInput = buildPromptInput(userMessage: userMessage, clipboardContext: clipboardContext)
    NSLog("🤖 PROMPT-MODE: Prompt input built (length: \(fullInput.count))")

    let gpt5Request = GPT5ResponseRequest(
      model: "gpt-5",
      input: fullInput,
      reasoning: GPT5ResponseRequest.ReasoningConfig(effort: "minimal"),
      text: GPT5ResponseRequest.TextConfig(verbosity: "medium"),
      previous_response_id: previousResponseId
    )

    request.httpBody = try JSONEncoder().encode(gpt5Request)

    // Execute request
    NSLog("🤖 PROMPT-MODE: Sending request to GPT-5 API")
    let (data, response) = try await session.data(for: request)

    // Validate response
    guard let httpResponse = response as? HTTPURLResponse else {
      NSLog("⚠️ PROMPT-MODE: Invalid response type from GPT-5")
      throw TranscriptionError.networkError("Invalid response")
    }

    if httpResponse.statusCode != 200 {
      NSLog("⚠️ PROMPT-MODE: GPT-5 HTTP error \(httpResponse.statusCode)")
      if let errorBody = String(data: data, encoding: .utf8) {
        NSLog("⚠️ PROMPT-MODE: Error response body: \(errorBody)")
      }
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    // Parse and extract response
    return try parseGPT5Response(data: data)
  }

  private func buildPromptInput(userMessage: String, clipboardContext: String?) -> String {
    // Get system prompt from settings
    let baseSystemPrompt = AppConstants.defaultPromptModeSystemPrompt
    let customSystemPrompt = UserDefaults.standard.string(forKey: "promptModeSystemPrompt")

    // Combine base system prompt with custom prompt if available
    var fullInput = baseSystemPrompt
    if let customPrompt = customSystemPrompt, !customPrompt.isEmpty {
      fullInput += "\n\nAdditional instructions: \(customPrompt)"
      NSLog("🤖 PROMPT-MODE: Custom system prompt added")
    }

    if let context = clipboardContext {
      fullInput += "\n\nContext (selected text from clipboard):\n\(context)"
      NSLog("🤖 PROMPT-MODE: Clipboard context added to prompt")
    }

    fullInput += "\n\nUser: \(userMessage)"
    return fullInput
  }

  private func parseGPT5Response(data: Data) throws -> String {
    NSLog("🤖 PROMPT-MODE: Parsing GPT-5 response")

    do {
      let result = try JSONDecoder().decode(GPT5ResponseResponse.self, from: data)

      // Store the response ID for conversation continuity
      previousResponseId = result.id
      NSLog("🤖 PROMPT-MODE: Response ID stored for conversation continuity")

      // Extract text from the response structure
      for output in result.output {
        if output.type == "message" {
          for content in output.content ?? [] {
            if content.type == "output_text" {
              NSLog(
                "✅ PROMPT-MODE: Successfully extracted response text (length: \(content.text.count))"
              )
              return content.text
            }
          }
        }
      }

      // Fallback: if we can't find the expected structure, try to extract any text
      if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [])
        as? [String: Any]
      {
        NSLog("⚠️ PROMPT-MODE: Unexpected response structure, attempting fallback parsing")
      }

      throw TranscriptionError.networkError("Could not extract text from GPT-5 response")
    } catch {
      // Try to parse as a generic dictionary to see the actual structure
      if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [])
        as? [String: Any]
      {
        NSLog("⚠️ PROMPT-MODE: Failed to decode response, raw structure available")
      }

      throw error
    }
  }

  // MARK: - Testing and Debugging
  func testGPT5Request() async throws -> String {
    NSLog("🧪 Testing GPT-5 request")

    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      NSLog("⚠️ TEST: No API key available")
      throw TranscriptionError.noAPIKey
    }

    // Test with a simple request
    let testRequest = GPT5ResponseRequest(
      model: "gpt-5",
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

    NSLog("🧪 TEST: Sending test request to GPT-5")
    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      NSLog("⚠️ TEST: Invalid response type")
      throw TranscriptionError.networkError("Invalid response type")
    }

    if httpResponse.statusCode != 200 {
      NSLog("⚠️ TEST: HTTP error \(httpResponse.statusCode)")
      if let errorBody = String(data: data, encoding: .utf8) {
        NSLog("⚠️ TEST: Error body: \(errorBody)")
      }
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    // Parse result using the new structure
    let result = try JSONDecoder().decode(GPT5ResponseResponse.self, from: data)

    // Extract text from the response structure
    for output in result.output {
      if output.type == "message" {
        for content in output.content ?? [] {
          if content.type == "output_text" {
            NSLog("✅ TEST: GPT-5 test successful")
            return content.text
          }
        }
      }
    }

    NSLog("⚠️ TEST: Could not extract text from test response")
    throw TranscriptionError.networkError("Could not extract text from test response")
  }

  // MARK: - Shared Infrastructure Helpers
  private func validateAudioFile(at url: URL) throws {
    NSLog("🔧 Validating audio file at: \(url.lastPathComponent)")

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let fileSize = attributes[.size] as? Int64 else {
      NSLog("⚠️ Error: Cannot read file size")
      throw TranscriptionError.fileError("Cannot read file size")
    }

    NSLog("🔧 Audio file size: \(fileSize) bytes")

    if fileSize == 0 {
      NSLog("⚠️ Error: Empty audio file")
      throw TranscriptionError.emptyFile
    }

    // GPT-4o-transcribe has a 25MB limit, same as Whisper-1
    if fileSize > Constants.maxFileSize {
      NSLog("⚠️ Error: File too large (\(fileSize) > \(Constants.maxFileSize))")
      throw TranscriptionError.fileTooLarge
    }

    NSLog("✅ Audio file validation passed")
  }

  private func createMultipartRequest(request: inout URLRequest, audioURL: URL) throws -> URLRequest
  {
    NSLog("🔧 Creating multipart form data request")

    let boundary = "Boundary-\(UUID().uuidString)"

    // Prepare form fields
    var fields: [String: String] = [
      "model": selectedModel.rawValue,
      "response_format": "json",
    ]

    NSLog("🔧 Using model: \(selectedModel.rawValue)")

    // Add prompt for GPT-4o models only if custom prompt is not empty
    if selectedModel == .gpt4oTranscribe || selectedModel == .gpt4oMiniTranscribe {
      if let customPrompt = UserDefaults.standard.string(forKey: "customPromptText"),
        !customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        fields["prompt"] = customPrompt
        NSLog("🔧 Custom transcription prompt added")
      }
      // If prompt is empty or nil, don't send any prompt field to OpenAI
    }

    // Prepare file
    let audioData = try Data(contentsOf: audioURL)
    NSLog("🔧 Audio data loaded: \(audioData.count) bytes")

    let files: [String: (filename: String, contentType: String, data: Data)] = [
      "file": (filename: "audio.wav", contentType: "audio/wav", data: audioData)
    ]

    // Set multipart form data using the elegant extension
    request.setMultipartFormData(boundary: boundary, fields: fields, files: files)
    NSLog("🔧 Multipart request created successfully")

    return request
  }

  private func parseErrorResponse(data: Data, statusCode: Int) throws -> TranscriptionError {
    NSLog("🔧 Parsing error response (status: \(statusCode))")

    // Try to parse the error response as JSON
    if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
      NSLog("🔧 Parsed OpenAI error response")
      return parseOpenAIError(errorResponse, statusCode: statusCode)
    }

    // If we can't parse JSON, fall back to status code
    NSLog("🔧 Using status code fallback for error parsing")
    return parseStatusCodeError(statusCode)
  }

  private func parseOpenAIError(_ errorResponse: OpenAIErrorResponse, statusCode: Int)
    -> TranscriptionError
  {
    let errorMessage = errorResponse.error?.message?.lowercased() ?? ""
    let errorType = errorResponse.error?.type?.lowercased() ?? ""

    switch statusCode {
    case 401:
      // Check for organization-specific errors first
      if errorMessage.contains("member of an organization")
        || errorMessage.contains("organization")
      {
        return .organizationRequired
      } else if errorMessage.contains("incorrect api key") && !errorMessage.contains("invalid") {
        // Only return incorrectAPIKey for very specific "incorrect api key" messages
        // that don't also contain "invalid" (to avoid conflicts)
        return .incorrectAPIKey
      } else {
        // Default to invalidAPIKey for all other authentication failures
        // This includes "invalid api key", "authentication", and general 401 errors
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

    // Add form fields
    for (name, value) in fields {
      body.append("--\(boundary)\r\n")
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
      body.append("\(value)\r\n")
    }

    // Add files
    for (name, file) in files {
      body.append("--\(boundary)\r\n")
      body.append(
        "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(file.filename)\"\r\n")
      body.append("Content-Type: \(file.contentType)\r\n\r\n")
      body.append(file.data)
      body.append("\r\n")
    }

    // Close boundary
    body.append("--\(boundary)--\r\n")

    httpBody = body
  }
}

// MARK: - Models
struct WhisperResponse: Codable {
  let text: String
}

// Chat API Models
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
    let effort: String  // "minimal", "low", "medium", "high"
  }

  struct TextConfig: Codable {
    let verbosity: String  // "low", "medium", "high"
  }
}

struct GPT5ResponseResponse: Codable {
  let output: [GPT5Output]
  let id: String  // Added for conversation continuity

  struct GPT5Output: Codable {
    let type: String
    let content: [GPT5Content]?

    struct GPT5Content: Codable {
      let type: String
      let text: String
    }
  }
}

// GPT-4o-transcribe models support prompts for better transcription quality
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
  case organizationRequired
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

  var isRetryable: Bool {
    switch self {
    case .rateLimited, .quotaExceeded, .serverError, .serviceUnavailable, .slowDown, .networkError:
      return true
    default:
      return false
    }
  }

  var title: String {
    switch self {
    case .noAPIKey:
      return "No API Key"
    case .invalidAPIKey:
      return "Invalid Authentication"
    case .incorrectAPIKey:
      return "Incorrect API Key"
    case .organizationRequired:
      return "Organization Required"
    case .countryNotSupported:
      return "Country Not Supported"
    case .invalidRequest:
      return "Invalid Request"
    case .permissionDenied:
      return "Permission Denied"
    case .notFound:
      return "Not Found"
    case .rateLimited:
      return "Rate Limited"
    case .quotaExceeded:
      return "Quota Exceeded"
    case .serverError:
      return "Server Error"
    case .serviceUnavailable:
      return "Service Unavailable"
    case .slowDown:
      return "Slow Down"
    case .networkError:
      return "Network Error"
    case .fileError:
      return "File Error"
    case .fileTooLarge:
      return "File Too Large"
    case .emptyFile:
      return "Empty File"
    case .noSpeechDetected:
      return "No Speech Detected"
    }
  }
}

// MARK: - Error Result Parser
extension SpeechService {
  /// Parse transcription result to determine if it contains an error message
  static func parseTranscriptionResult(_ text: String) -> (
    isError: Bool, isRetryable: Bool, errorType: TranscriptionError?
  ) {
    // Check for error indicators
    let errorPrefixes = ["❌", "⚠️", "⏰", "⏳", "🔄"]
    let isError = errorPrefixes.contains { text.hasPrefix($0) }

    guard isError else {
      return (false, false, nil)
    }

    // Map error messages to error types
    if text.contains("No API Key") {
      return (true, false, .noAPIKey)
    } else if text.contains("Incorrect API Key") {
      return (true, false, .incorrectAPIKey)
    } else if text.contains("Organization Required") {
      return (true, false, .organizationRequired)
    } else if text.contains("Country Not Supported") {
      return (true, false, .countryNotSupported)
    } else if text.contains("Authentication") || text.contains("invalid API key") {
      return (true, false, .invalidAPIKey)
    } else if text.contains("Rate Limit") {
      return (true, true, .rateLimited)
    } else if text.contains("Quota Exceeded") {
      return (true, true, .quotaExceeded)
    } else if text.contains("Timeout") {
      return (true, true, .networkError("Timeout"))
    } else if text.contains("Network Error") {
      return (true, true, .networkError("Network"))
    } else if text.contains("Server Error") {
      return (true, true, .serverError(500))
    } else if text.contains("Service Unavailable") {
      return (true, true, .serviceUnavailable)
    } else if text.contains("Slow Down") {
      return (true, true, .slowDown)
    } else if text.contains("File Too Large") {
      return (true, false, .fileTooLarge)
    } else if text.contains("Empty") {
      return (true, false, .emptyFile)
    } else {
      return (true, false, .serverError(0))
    }
  }
}

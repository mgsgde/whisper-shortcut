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
class TranscriptionService {
  private let keychainManager: KeychainManaging
  private var selectedModel: TranscriptionModel = .gpt4oMiniTranscribe
  private var previousResponseId: String?  // Store previous response ID for conversation continuity

  // Custom session with appropriate timeouts
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = Constants.requestTimeout
    config.timeoutIntervalForResource = Constants.resourceTimeout
    return URLSession(configuration: config)
  }()

  init(keychainManager: KeychainManaging = KeychainManager.shared) {
    self.keychainManager = keychainManager
  }

  // MARK: - Model Selection
  func setModel(_ model: TranscriptionModel) {
    self.selectedModel = model
  }

  func getCurrentModel() -> TranscriptionModel {
    return selectedModel
  }

  // MARK: - API Key Management
  private var apiKey: String? {
    keychainManager.getAPIKey()
  }

  func updateAPIKey(_ key: String) {
    _ = keychainManager.saveAPIKey(key)
  }

  func clearAPIKey() {
    _ = keychainManager.deleteAPIKey()
  }

  // MARK: - Conversation Management
  func clearConversationHistory() {
    previousResponseId = nil
  }

  // MARK: - Validation
  func validateAPIKey(_ key: String) async throws -> Bool {
    guard !key.isEmpty else {
      throw TranscriptionError.noAPIKey
    }

    let url = URL(string: Constants.modelsEndpoint)!
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = Constants.validationTimeout

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }

    if httpResponse.statusCode != 200 {
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    return true
  }

  // MARK: - Transcription
  func transcribe(audioURL: URL) async throws -> String {
    // Validate API key
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      throw TranscriptionError.noAPIKey
    }

    // Validate file
    try validateAudioFile(at: audioURL)

    // Create request based on selected model
    let request = try createRequest(audioURL: audioURL, apiKey: apiKey)

    // Execute request
    let (data, response) = try await session.data(for: request)

    // Validate response
    guard let httpResponse = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }

    // Check if the response indicates an error
    if httpResponse.statusCode != 200 {
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    // Parse result
    let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
    return result.text
  }

  // MARK: - Prompt Execution
  func executePrompt(audioURL: URL) async throws -> String {
    // Validate API key
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      throw TranscriptionError.noAPIKey
    }

    // First, transcribe the audio to get the user's spoken text
    let spokenText = try await transcribe(audioURL: audioURL)

    // Then send the transcribed text to the chat API
    return try await executeChatCompletion(userMessage: spokenText, apiKey: apiKey)
  }

  private func executeChatCompletion(userMessage: String, apiKey: String) async throws -> String {
    // Always use GPT-5 with Responses API
    return try await executeGPT5Response(userMessage: userMessage, apiKey: apiKey)
  }

  private func executeGPT5Response(userMessage: String, apiKey: String) async throws -> String {
    let url = URL(string: Constants.responsesEndpoint)!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // Get system prompt from settings
    let systemPrompt =
      UserDefaults.standard.string(forKey: "promptModeSystemPrompt")
      ?? "You are a helpful assistant that executes user commands. Provide clear, actionable responses."

    // Create input with system prompt and user message
    let fullInput = "\(systemPrompt)\n\nUser: \(userMessage)"

    let gpt5Request = GPT5ResponseRequest(
      model: "gpt-5",
      input: fullInput,
      reasoning: GPT5ResponseRequest.ReasoningConfig(effort: "minimal"),
      text: GPT5ResponseRequest.TextConfig(verbosity: "medium"),
      previous_response_id: previousResponseId
    )

    request.httpBody = try JSONEncoder().encode(gpt5Request)

    // Execute request
    let (data, response) = try await session.data(for: request)

    // Validate response
    guard let httpResponse = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }

    if httpResponse.statusCode != 200 {
      // Log error response body for debugging
      if let errorBody = String(data: data, encoding: .utf8) {
        NSLog("🤖 PROMPT-MODE: GPT-5 Error Response Body: \(errorBody)")
      }
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    // Parse result
    do {
      let result = try JSONDecoder().decode(GPT5ResponseResponse.self, from: data)

      // Store the response ID for conversation continuity
      previousResponseId = result.id

      // Extract text from the response structure
      for output in result.output {
        if output.type == "message" {
          for content in output.content ?? [] {
            if content.type == "output_text" {
              return content.text
            }
          }
        }
      }

      // Fallback: if we can't find the expected structure, try to extract any text
      NSLog("🤖 PROMPT-MODE: GPT-5 Could not find expected text structure, trying fallback...")
      if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [])
        as? [String: Any]
      {
        NSLog("🤖 PROMPT-MODE: GPT-5 Raw JSON Structure: \(jsonObject)")
      }

      throw TranscriptionError.networkError("Could not extract text from GPT-5 response")
    } catch {
      NSLog("🤖 PROMPT-MODE: GPT-5 JSON Parsing Error: \(error)")

      // Try to parse as a generic dictionary to see the actual structure
      if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [])
        as? [String: Any]
      {
        NSLog("🤖 PROMPT-MODE: GPT-5 Raw JSON Structure: \(jsonObject)")
      }

      throw error
    }
  }

  // MARK: - Testing and Debugging
  func testGPT5Request() async throws -> String {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
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

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response type")
    }

    if httpResponse.statusCode != 200 {
      if let errorBody = String(data: data, encoding: .utf8) {
        NSLog("🧪 TEST: Test Error Response Body: \(errorBody)")
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
            return content.text
          }
        }
      }
    }

    throw TranscriptionError.networkError("Could not extract text from test response")
  }

  // MARK: - Private Helpers
  private func validateAudioFile(at url: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let fileSize = attributes[.size] as? Int64 else {
      throw TranscriptionError.fileError("Cannot read file size")
    }

    if fileSize == 0 {
      throw TranscriptionError.emptyFile
    }

    // GPT-4o-transcribe has a 25MB limit, same as Whisper-1
    if fileSize > Constants.maxFileSize {
      throw TranscriptionError.fileTooLarge
    }
  }

  private func createRequest(audioURL: URL, apiKey: String) throws -> URLRequest {
    let apiURL = URL(string: selectedModel.apiEndpoint)!
    var request = URLRequest(url: apiURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    // Create multipart form data using a more elegant approach
    return try createMultipartRequest(request: &request, audioURL: audioURL)
  }

  private func createMultipartRequest(request: inout URLRequest, audioURL: URL) throws -> URLRequest
  {
    let boundary = "Boundary-\(UUID().uuidString)"

    // Prepare form fields
    var fields: [String: String] = [
      "model": selectedModel.rawValue,
      "response_format": "json",
    ]

    // Add prompt for GPT-4o models only if custom prompt is not empty
    if selectedModel == .gpt4oTranscribe || selectedModel == .gpt4oMiniTranscribe {
      if let customPrompt = UserDefaults.standard.string(forKey: "customPromptText"),
        !customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        fields["prompt"] = customPrompt
      }
      // If prompt is empty or nil, don't send any prompt field to OpenAI
    }

    // Prepare file
    let audioData = try Data(contentsOf: audioURL)
    let files: [String: (filename: String, contentType: String, data: Data)] = [
      "file": (filename: "audio.wav", contentType: "audio/wav", data: audioData)
    ]

    // Set multipart form data using the elegant extension
    request.setMultipartFormData(boundary: boundary, fields: fields, files: files)

    return request
  }

  private func parseErrorResponse(data: Data, statusCode: Int) throws -> TranscriptionError {
    // Try to parse the error response as JSON
    if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
      return parseOpenAIError(errorResponse, statusCode: statusCode)
    }

    // If we can't parse JSON, fall back to status code
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
    text: "Please transcribe this audio accurately, preserving punctuation and filler words.")
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
    }
  }
}

// MARK: - Error Result Parser
extension TranscriptionService {
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

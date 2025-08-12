import Foundation

// MARK: - Transcription Model Enum
enum TranscriptionModel: String, CaseIterable {
  case gpt4oTranscribe = "gpt-4o-transcribe"
  case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
  case whisper1 = "whisper-1"

  var displayName: String {
    switch self {
    case .gpt4oTranscribe:
      return "GPT-4o Transcribe"
    case .gpt4oMiniTranscribe:
      return "GPT-4o Mini Transcribe"
    case .whisper1:
      return "Whisper-1"
    }
  }

  var apiEndpoint: String {
    switch self {
    case .whisper1:
      return "https://api.openai.com/v1/audio/transcriptions"
    case .gpt4oTranscribe:
      return "https://api.openai.com/v1/audio/transcriptions"
    case .gpt4oMiniTranscribe:
      return "https://api.openai.com/v1/audio/transcriptions"
    }
  }

  var requiresMultipartForm: Bool {
    switch self {
    case .whisper1, .gpt4oTranscribe, .gpt4oMiniTranscribe:
      return true
    }
  }
}

// MARK: - Core Service
class TranscriptionService {
  private let keychainManager: KeychainManaging
  private var selectedModel: TranscriptionModel = .whisper1

  // Custom session with appropriate timeouts
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30.0
    config.timeoutIntervalForResource = 120.0
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

  // MARK: - Validation
  func validateAPIKey(_ key: String) async throws -> Bool {
    guard !key.isEmpty else {
      throw TranscriptionError.noAPIKey
    }

    let url = URL(string: "https://api.openai.com/v1/models")!
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 10.0

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
    if fileSize > 25 * 1024 * 1024 {  // 25MB limit
      throw TranscriptionError.fileTooLarge
    }
  }

  private func createRequest(audioURL: URL, apiKey: String) throws -> URLRequest {
    let apiURL = URL(string: selectedModel.apiEndpoint)!
    var request = URLRequest(url: apiURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    // All models use multipart form data
    return try createMultipartRequest(request: &request, audioURL: audioURL)
  }

  private func createMultipartRequest(request: inout URLRequest, audioURL: URL) throws -> URLRequest
  {
    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()

    // Add model
    body.append("--\(boundary)\r\n")
    body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
    body.append("\(selectedModel.rawValue)\r\n")

    // Add response format
    body.append("--\(boundary)\r\n")
    body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
    body.append("json\r\n")

    // Add prompt for GPT-4o models (they support prompts for better quality)
    if selectedModel == .gpt4oTranscribe || selectedModel == .gpt4oMiniTranscribe {
      body.append("--\(boundary)\r\n")
      body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
      body.append(
        "Please transcribe this audio accurately, preserving punctuation and filler words.\r\n")
    }

    // Add audio file
    body.append("--\(boundary)\r\n")
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
    body.append("Content-Type: audio/wav\r\n\r\n")

    let audioData = try Data(contentsOf: audioURL)
    body.append(audioData)
    body.append("\r\n--\(boundary)--\r\n")

    request.httpBody = body
    return request
  }

  private func validateStatusCode(_ statusCode: Int) throws {
    switch statusCode {
    case 200: return
    case 400: throw TranscriptionError.invalidRequest
    case 401: throw TranscriptionError.invalidAPIKey
    case 403: throw TranscriptionError.permissionDenied
    case 404: throw TranscriptionError.notFound
    case 429: throw TranscriptionError.rateLimited
    case 500: throw TranscriptionError.serverError(statusCode)
    case 503: throw TranscriptionError.serviceUnavailable
    default: throw TranscriptionError.serverError(statusCode)
    }
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

// MARK: - Models
struct WhisperResponse: Codable {
  let text: String
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

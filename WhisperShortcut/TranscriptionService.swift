import Foundation

// MARK: - Core Service
class TranscriptionService {
  private let apiURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
  private let keychainManager: KeychainManaging

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

    let (_, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }

    switch httpResponse.statusCode {
    case 200: return true
    case 401: throw TranscriptionError.invalidAPIKey
    case 429: throw TranscriptionError.rateLimited
    default: throw TranscriptionError.serverError(httpResponse.statusCode)
    }
  }

  // MARK: - Transcription
  func transcribe(audioURL: URL) async throws -> String {
    // Validate API key
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      throw TranscriptionError.noAPIKey
    }

    // Validate file
    try validateAudioFile(at: audioURL)

    // Create request
    let request = try createRequest(audioURL: audioURL, apiKey: apiKey)

    // Execute request
    let (data, response) = try await session.data(for: request)

    // Validate response
    guard let httpResponse = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }

    try validateStatusCode(httpResponse.statusCode)

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

    if fileSize > 25 * 1024 * 1024 {  // 25MB limit
      throw TranscriptionError.fileTooLarge
    }
  }

  private func createRequest(audioURL: URL, apiKey: String) throws -> URLRequest {
    var request = URLRequest(url: apiURL)
    request.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    var body = Data()

    // Add model
    body.append("--\(boundary)\r\n")
    body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
    body.append("whisper-1\r\n")

    // Add response format
    body.append("--\(boundary)\r\n")
    body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
    body.append("json\r\n")

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

// MARK: - Error Types
enum TranscriptionError: Error, Equatable {
  case noAPIKey
  case invalidAPIKey
  case invalidRequest
  case permissionDenied
  case notFound
  case rateLimited
  case serverError(Int)
  case serviceUnavailable
  case networkError(String)
  case fileError(String)
  case fileTooLarge
  case emptyFile

  var isRetryable: Bool {
    switch self {
    case .rateLimited, .serverError, .serviceUnavailable, .networkError:
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
      return "Invalid Key"
    case .invalidRequest:
      return "Invalid Request"
    case .permissionDenied:
      return "Permission Denied"
    case .notFound:
      return "Not Found"
    case .rateLimited:
      return "Rate Limited"
    case .serverError:
      return "Server Error"
    case .serviceUnavailable:
      return "Service Down"
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
    } else if text.contains("Authentication") || text.contains("invalid API key") {
      return (true, false, .invalidAPIKey)
    } else if text.contains("Rate Limit") {
      return (true, true, .rateLimited)
    } else if text.contains("Timeout") {
      return (true, true, .networkError("Timeout"))
    } else if text.contains("Network Error") {
      return (true, true, .networkError("Network"))
    } else if text.contains("Server Error") {
      return (true, true, .serverError(500))
    } else if text.contains("Service Unavailable") {
      return (true, true, .serviceUnavailable)
    } else if text.contains("File Too Large") {
      return (true, false, .fileTooLarge)
    } else if text.contains("Empty") {
      return (true, false, .emptyFile)
    } else {
      return (true, false, .serverError(0))
    }
  }
}

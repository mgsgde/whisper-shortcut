import Foundation

class TranscriptionService {
  private let baseURL = "https://api.openai.com/v1/audio/transcriptions"
  private let session = URLSession.shared
  private let keychainManager: KeychainManaging

  // Custom session with reasonable timeout for transcription requests
  private lazy var transcriptionSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30.0  // 30 seconds for request timeout
    config.timeoutIntervalForResource = 120.0  // 2 minutes for resource timeout
    return URLSession(configuration: config)
  }()

  init(keychainManager: KeychainManaging = KeychainManager.shared) {
    self.keychainManager = keychainManager
    // Check if API key is configured
    if let apiKey = self.apiKey, !apiKey.isEmpty {
      print("✅ API key configured")
    } else {
      print("⚠️ Warning: No API key configured. Please set it in Settings.")
    }
  }

  private var apiKey: String? {
    return keychainManager.getAPIKey()
  }

  // Method for updating API key (useful for testing and settings)
  func updateAPIKey(_ newAPIKey: String) {
    if keychainManager.saveAPIKey(newAPIKey) {
      print("✅ API key updated in Keychain")
    } else {
      print("❌ Failed to update API key in Keychain")
    }
  }

  // Test-specific method to clear API key
  func clearAPIKey() {
    _ = keychainManager.deleteAPIKey()
  }

  // Method to validate API key by making a simple test request
  func validateAPIKey(_ apiKey: String, completion: @escaping (Result<Bool, Error>) -> Void) {
    guard !apiKey.isEmpty else {
      completion(
        .failure(
          NSError(
            domain: "WhisperShortcut", code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "No API key provided"])))
      return
    }

    // Create a simple request to test the API key
    // We'll use the models endpoint which is lightweight and only requires authentication
    guard let url = URL(string: "https://api.openai.com/v1/models") else {
      completion(
        .failure(
          NSError(
            domain: "WhisperShortcut", code: 1002,
            userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 10.0  // Short timeout for validation

    session.dataTask(with: request) { data, response, error in
      if let error = error {
        completion(.failure(error))
        return
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        completion(
          .failure(
            NSError(
              domain: "WhisperShortcut", code: 1003,
              userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])))
        return
      }

      switch httpResponse.statusCode {
      case 200:
        completion(.success(true))
      case 401:
        completion(
          .failure(
            NSError(
              domain: "WhisperShortcut", code: 401,
              userInfo: [NSLocalizedDescriptionKey: "Authentication failed - invalid API key"])))
      case 429:
        completion(
          .failure(
            NSError(
              domain: "WhisperShortcut", code: 429,
              userInfo: [NSLocalizedDescriptionKey: "Rate limit exceeded"])))
      default:
        completion(
          .failure(
            NSError(
              domain: "WhisperShortcut", code: httpResponse.statusCode,
              userInfo: [NSLocalizedDescriptionKey: "HTTP error: \(httpResponse.statusCode)"])))
      }
    }.resume()
  }

  func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      let errorResult = TranscriptionErrorResult(type: .noAPIKey)
      print("❌ No API key configured - returning error message as transcription")
      completion(.success(errorResult.message))
      return
    }

    print("🔑 API key found (length: \(apiKey.count) characters)")
    print("🔍 Starting transcription for file: \(audioURL.path)")

    // Check file size (Whisper API has 25MB limit)
    do {
      let fileAttributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
      if let fileSize = fileAttributes[.size] as? Int64 {
        let maxSize: Int64 = 25 * 1024 * 1024  // 25MB
        print("📁 Audio file size: \(fileSize) bytes")
        if fileSize > maxSize {
          let errorResult = TranscriptionErrorResult(type: .fileTooLarge)
          print("❌ File too large - returning error message as transcription")
          completion(.success(errorResult.message))
          return
        }
        if fileSize == 0 {
          print("⚠️ Warning: Audio file is empty (0 bytes)")
          let errorResult = TranscriptionErrorResult(type: .emptyFile)
          completion(.success(errorResult.message))
          return
        }
      }
    } catch {
      let errorResult = TranscriptionErrorResult(
        type: .internalServerError, details: error.localizedDescription)
      print("❌ File read error - returning error message as transcription")
      completion(.success(errorResult.message))
      return
    }

    // Create multipart form data request
    let request = createMultipartRequest(audioURL: audioURL, apiKey: apiKey)
    print("🌐 Making API request to OpenAI Whisper...")

    // Execute request
    transcriptionSession.dataTask(with: request) { data, response, error in
      if let error = error {
        print("❌ Network error: \(error)")

        // Debug error details
        let nsError = error as NSError
        print("🔍 Error details:")
        print("   - Error code: \(nsError.code)")
        print("   - Error domain: \(nsError.domain)")
        print("   - Error description: \(nsError.localizedDescription)")
        print("   - NSURLErrorTimedOut constant: \(NSURLErrorTimedOut)")

        // Check if it's a timeout error (multiple ways to detect)
        let isTimeout =
          nsError.code == NSURLErrorTimedOut || nsError.localizedDescription.contains("timed out")
          || nsError.localizedDescription.contains("timeout")

        print("⏰ Is timeout error: \(isTimeout)")

        if isTimeout {
          let errorResult = TranscriptionErrorResult(type: .timeout)
          print("⏰ Timeout error detected")
          completion(.success(errorResult.message))
        } else {
          let errorResult = TranscriptionErrorResult(
            type: .networkError, details: error.localizedDescription)
          completion(.success(errorResult.message))
        }
        return
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        print("❌ Invalid HTTP response")
        let errorResult = TranscriptionErrorResult(type: .internalServerError)
        completion(.success(errorResult.message))
        return
      }

      print("📡 HTTP Status Code: \(httpResponse.statusCode)")

      guard let data = data else {
        print("❌ No data received from API")
        let errorResult = TranscriptionErrorResult(type: .internalServerError)
        completion(.success(errorResult.message))
        return
      }

      // Log response data for debugging
      if let responseString = String(data: data, encoding: .utf8) {
        print("📄 Raw API Response: \(responseString)")
      }

      // Handle response based on status code (following OpenAI API error codes)
      switch httpResponse.statusCode {
      case 200:
        self.parseSuccessResponse(data: data, completion: completion)
      case 400:
        print("❌ Bad request - check audio format")
        let errorResult = TranscriptionErrorResult(
          type: .invalidRequest, details: "Bad request - check audio format")
        completion(.success(errorResult.message))
      case 401:
        print("❌ Unauthorized - check API key")
        let errorResult = TranscriptionErrorResult(type: .authenticationError)
        completion(.success(errorResult.message))
      case 403:
        print("❌ Permission denied")
        let errorResult = TranscriptionErrorResult(type: .permissionDenied)
        completion(.success(errorResult.message))
      case 404:
        print("❌ Resource not found")
        let errorResult = TranscriptionErrorResult(type: .notFound)
        completion(.success(errorResult.message))
      case 429:
        print("❌ Rate limited")
        let errorResult = TranscriptionErrorResult(type: .rateLimitExceeded)
        completion(.success(errorResult.message))
      case 500:
        print("❌ Internal server error")
        let errorResult = TranscriptionErrorResult(type: .internalServerError)
        completion(.success(errorResult.message))
      case 503:
        print("🔄 Service unavailable")
        let errorResult = TranscriptionErrorResult(type: .serviceUnavailable)
        completion(.success(errorResult.message))
      default:
        let errorResult = TranscriptionErrorResult(
          type: .internalServerError, details: "HTTP \(httpResponse.statusCode)")
        print("❌ HTTP error: \(httpResponse.statusCode)")
        completion(.success(errorResult.message))
      }
    }.resume()
  }

  private func createMultipartRequest(audioURL: URL, apiKey: String) -> URLRequest {
    var request = URLRequest(url: URL(string: baseURL)!)
    request.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    // Create multipart body
    var body = Data()

    // Add model parameter
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
    body.append("whisper-1\r\n".data(using: .utf8)!)

    // Add language parameter (optional - let Whisper auto-detect)
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
      "Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
    body.append("json\r\n".data(using: .utf8)!)

    // Add audio file
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
      "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(
        using: .utf8)!)
    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)

    if let audioData = try? Data(contentsOf: audioURL) {
      body.append(audioData)
    }

    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    request.httpBody = body
    return request
  }

  private func parseSuccessResponse(
    data: Data, completion: @escaping (Result<String, Error>) -> Void
  ) {
    do {
      let response = try JSONDecoder().decode(WhisperResponse.self, from: data)
      print("✅ Parsed transcription: '\(response.text)'")
      completion(.success(response.text))
    } catch {
      print("❌ JSON parsing error: \(error)")
      let errorResult = TranscriptionErrorResult(
        type: .parseError, details: error.localizedDescription)
      completion(.success(errorResult.message))
    }
  }
}

// MARK: - Error Parsing Helper
extension TranscriptionService {
  /// Parse a transcription result to determine if it's an error and if it's retryable
  static func parseTranscriptionResult(_ transcription: String) -> (
    isError: Bool, isRetryable: Bool, errorType: TranscriptionErrorType?
  ) {
    // Check if this is an error message by looking for error emojis
    let errorEmojis = ["❌", "⚠️", "⏰", "⏳", "🔄"]
    let isError = errorEmojis.contains { transcription.hasPrefix($0) }

    if !isError {
      return (isError: false, isRetryable: false, errorType: nil)
    }

    // Determine error type and retryability based on OpenAI API error codes
    if transcription.contains("⏰ Request Timeout") {
      return (isError: true, isRetryable: true, errorType: .timeout)
    } else if transcription.contains("❌ Network Error") {
      return (isError: true, isRetryable: true, errorType: .networkError)
    } else if transcription.contains("❌ Internal Server Error") {
      return (isError: true, isRetryable: true, errorType: .internalServerError)
    } else if transcription.contains("⏳ Rate Limit Exceeded") {
      return (isError: true, isRetryable: true, errorType: .rateLimitExceeded)
    } else if transcription.contains("🔄 Service Unavailable") {
      return (isError: true, isRetryable: true, errorType: .serviceUnavailable)
    } else if transcription.contains("❌ Authentication Error") {
      return (isError: true, isRetryable: false, errorType: .authenticationError)
    } else if transcription.contains("❌ Invalid Request") {
      return (isError: true, isRetryable: false, errorType: .invalidRequest)
    } else if transcription.contains("❌ Permission Denied") {
      return (isError: true, isRetryable: false, errorType: .permissionDenied)
    } else if transcription.contains("❌ Resource Not Found") {
      return (isError: true, isRetryable: false, errorType: .notFound)
    } else if transcription.contains("❌ File Too Large") {
      return (isError: true, isRetryable: false, errorType: .fileTooLarge)
    } else if transcription.contains("❌ Empty Audio File") {
      return (isError: true, isRetryable: false, errorType: .emptyFile)
    } else if transcription.contains("⚠️ No API Key Configured") {
      return (isError: true, isRetryable: false, errorType: .noAPIKey)
    } else {
      // Generic error - assume not retryable
      return (isError: true, isRetryable: false, errorType: .internalServerError)
    }
  }
}

// MARK: - Models
struct WhisperResponse: Codable {
  let text: String
}

// MARK: - Error Types (Based on OpenAI API Error Codes)
enum TranscriptionErrorType: CaseIterable {
  // OpenAI API Errors
  case invalidRequest  // 400 - Bad request
  case authenticationError  // 401 - Invalid API key
  case permissionDenied  // 403 - Insufficient permissions
  case notFound  // 404 - Resource not found
  case rateLimitExceeded  // 429 - Rate limit exceeded
  case internalServerError  // 500 - OpenAI server error
  case serviceUnavailable  // 503 - Service temporarily unavailable

  // Network/Client Errors
  case timeout  // Network timeout
  case networkError  // General network error
  case fileTooLarge  // File exceeds 25MB limit
  case emptyFile  // Empty audio file
  case noAPIKey  // No API key configured
  case parseError  // JSON parsing error

  var isRetryable: Bool {
    switch self {
    case .rateLimitExceeded, .internalServerError, .serviceUnavailable, .timeout, .networkError:
      return true
    case .invalidRequest, .authenticationError, .permissionDenied, .notFound, .fileTooLarge,
      .emptyFile, .noAPIKey, .parseError:
      return false
    }
  }

  var emoji: String {
    switch self {
    case .timeout: return "⏰"
    case .rateLimitExceeded: return "⏳"
    case .serviceUnavailable: return "🔄"
    case .invalidRequest, .authenticationError, .permissionDenied, .notFound, .internalServerError,
      .networkError, .fileTooLarge, .emptyFile, .noAPIKey, .parseError:
      return "❌"
    }
  }

  var title: String {
    switch self {
    case .invalidRequest: return "Invalid Request"
    case .authenticationError: return "Authentication Error"
    case .permissionDenied: return "Permission Denied"
    case .notFound: return "Resource Not Found"
    case .rateLimitExceeded: return "Rate Limit Exceeded"
    case .internalServerError: return "Internal Server Error"
    case .serviceUnavailable: return "Service Unavailable"
    case .timeout: return "Request Timeout"
    case .networkError: return "Network Error"
    case .fileTooLarge: return "File Too Large"
    case .emptyFile: return "Empty Audio File"
    case .noAPIKey: return "No API Key Configured"
    case .parseError: return "Response Processing Error"
    }
  }

  func message(details: String = "") -> String {
    let baseMessage: String
    switch self {
    case .invalidRequest:
      baseMessage = """
        ❌ Invalid Request

        The request was malformed or contained invalid parameters.
        \(details.isEmpty ? "Please check your audio file format and try again." : details)
        """
    case .authenticationError:
      baseMessage = """
        ❌ Authentication Error

        Your API key is invalid or has expired.
        Please check your OpenAI API key in Settings.
        """
    case .permissionDenied:
      baseMessage = """
        ❌ Permission Denied

        You don't have permission to access this resource.
        Please check your API key permissions.
        """
    case .notFound:
      baseMessage = """
        ❌ Resource Not Found

        The requested resource was not found.
        Please try again.
        """
    case .rateLimitExceeded:
      baseMessage = """
        ⏳ Rate Limit Exceeded

        You have exceeded the rate limit for this API.
        Please wait a moment and try again.
        """
    case .internalServerError:
      baseMessage = """
        ❌ Internal Server Error

        An error occurred on OpenAI's servers.
        Please try again later.
        """
    case .serviceUnavailable:
      baseMessage = """
        🔄 Service Unavailable

        OpenAI's service is temporarily unavailable.
        Please try again in a few moments.
        """
    case .timeout:
      baseMessage = """
        ⏰ Request Timeout

        The request took too long and was cancelled.

        Possible causes:
        • Slow internet connection
        • Large audio file
        • OpenAI servers overloaded

        Tips:
        • Try again
        • Use shorter recordings
        • Check your internet connection
        """
    case .networkError:
      baseMessage = """
        ❌ Network Error

        Error: \(details)

        Please check your internet connection and try again.
        """
    case .fileTooLarge:
      baseMessage = """
        ❌ File Too Large

        The audio file is larger than 25MB and cannot be transcribed.
        Please use a shorter recording.
        """
    case .emptyFile:
      baseMessage = """
        ❌ Empty Audio File

        The recording contains no audio data.
        Please try again.
        """
    case .noAPIKey:
      baseMessage = """
        ⚠️ No API Key Configured

        Please open Settings and add your OpenAI API key.

        Without a valid API key, transcription cannot be performed.
        """
    case .parseError:
      baseMessage = """
        ❌ Response Processing Error

        Error: \(details)

        The server response could not be processed.
        Please try again.
        """
    }
    return baseMessage
  }
}

// MARK: - Error Result
struct TranscriptionErrorResult {
  let type: TranscriptionErrorType
  let details: String

  init(type: TranscriptionErrorType, details: String = "") {
    self.type = type
    self.details = details
  }

  var message: String {
    return type.message(details: details)
  }

  var isRetryable: Bool {
    return type.isRetryable
  }
}

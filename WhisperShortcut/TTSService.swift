import AVFoundation
import Foundation

// MARK: - TTS Service Constants
private enum TTSConstants {
  static let endpoint = "https://api.openai.com/v1/audio/speech"
  static let requestTimeout: TimeInterval = 30.0
  static let maxTextLength = 4096  // OpenAI TTS text limit
  static let defaultVoice = "onyx"  // OpenAI voice options: alloy, echo, fable, onyx, nova, shimmer, coral, verse, ballad, ash, sage, marin, cedar
  static let defaultModel = "gpt-4o-mini-tts"  // gpt-4o-mini-tts, gpt-4o-tts, tts-1, tts-1-hd
  static let outputFormat = "mp3"  // mp3, opus, aac, flac, wav, pcm
}

// MARK: - TTS Service Implementation
class TTSService {
  private let keychainManager: KeychainManaging
  private let session: URLSession

  private var apiKey: String? {
    return keychainManager.getAPIKey()
  }

  init(keychainManager: KeychainManaging) {
    self.keychainManager = keychainManager

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = TTSConstants.requestTimeout
    config.timeoutIntervalForResource = TTSConstants.requestTimeout
    self.session = URLSession(configuration: config)
  }

  func updateAPIKey(_ apiKey: String) {
    _ = keychainManager.saveAPIKey(apiKey)
  }

  // MARK: - Main TTS Generation Method
  func generateSpeech(
    text: String, voice: String = TTSConstants.defaultVoice,
    model: String = TTSConstants.defaultModel, speed: Double = 1.0
  ) async throws -> Data {
    NSLog("🔊 TTS-SERVICE: Starting text-to-speech generation")
    NSLog("🔊 TTS-SERVICE: Text length: \(text.count) characters")
    NSLog("🔊 TTS-SERVICE: Speech speed: \(speed)x")

    // Validate API key
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      NSLog("⚠️ TTS-SERVICE: No API key available")
      throw TTSError.noAPIKey
    }

    // Validate input text
    try validateInputText(text)
    NSLog("🔊 TTS-SERVICE: Input text validation passed")

    // Implement retry logic for server errors
    var lastError: TTSError?
    let maxRetries = 3
    let baseDelay: UInt64 = 1_000_000_000  // 1 second in nanoseconds

    for attempt in 1...maxRetries {
      do {
        NSLog("🔊 TTS-SERVICE: Attempt \(attempt)/\(maxRetries)")

        // Create request
        let request = try createTTSRequest(
          text: text, voice: voice, model: model, apiKey: apiKey, speed: speed)
        NSLog("🔊 TTS-SERVICE: TTS request created")

        // Execute request
        NSLog("🔊 TTS-SERVICE: Sending request to OpenAI TTS API")
        let (data, response) = try await session.data(for: request)

        // Validate response
        guard let httpResponse = response as? HTTPURLResponse else {
          NSLog("⚠️ TTS-SERVICE: Invalid response type from OpenAI TTS")
          throw TTSError.networkError("Invalid response type")
        }

        if httpResponse.statusCode != 200 {
          NSLog("⚠️ TTS-SERVICE: OpenAI TTS HTTP error \(httpResponse.statusCode)")
          if let errorBody = String(data: data, encoding: .utf8) {
            NSLog("⚠️ TTS-SERVICE: Error response body: \(errorBody)")
          }
          let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)

          // Retry only for server errors (5xx)
          if httpResponse.statusCode >= 500 && httpResponse.statusCode < 600 && attempt < maxRetries
          {
            NSLog(
              "🔄 TTS-SERVICE: Server error \(httpResponse.statusCode), retrying in \(attempt) seconds..."
            )
            lastError = error
            let delay = baseDelay * UInt64(attempt)  // Exponential backoff
            try await Task.sleep(nanoseconds: delay)
            continue
          }

          throw error
        }

        // Validate audio data
        try validateAudioData(data)

        NSLog("✅ TTS-SERVICE: Successfully generated \(data.count) bytes of audio")
        return data

      } catch let error as TTSError {
        lastError = error
        NSLog("❌ TTS-SERVICE: Error on attempt \(attempt): \(error.localizedDescription)")

        // Only retry for server errors
        if error.isRetryable && attempt < maxRetries {
          NSLog(
            "🔄 TTS-SERVICE: Retryable error on attempt \(attempt): \(error.localizedDescription)")
          let delay = baseDelay * UInt64(attempt)
          try await Task.sleep(nanoseconds: delay)
          continue
        } else {
          NSLog(
            "🚫 TTS-SERVICE: Non-retryable error or max retries reached: \(error.localizedDescription)"
          )
          throw error
        }
      } catch {
        // Handle unexpected errors
        let wrappedError = TTSError.networkError("Unexpected error: \(error.localizedDescription)")
        lastError = wrappedError
        NSLog(
          "❌ TTS-SERVICE: Unexpected error on attempt \(attempt): \(error.localizedDescription)")

        if attempt < maxRetries {
          NSLog("🔄 TTS-SERVICE: Retrying unexpected error...")
          let delay = baseDelay * UInt64(attempt)
          try await Task.sleep(nanoseconds: delay)
          continue
        } else {
          throw wrappedError
        }
      }
    }

    // If we get here, all retries failed
    throw lastError ?? TTSError.networkError("All retry attempts failed")
  }

  // MARK: - Request Creation
  private func createTTSRequest(
    text: String, voice: String, model: String, apiKey: String, speed: Double
  ) throws
    -> URLRequest
  {
    NSLog(
      "🔧 TTS-SERVICE: Creating TTS request for model: \(model), voice: \(voice), speed: \(speed)x")

    guard let url = URL(string: TTSConstants.endpoint) else {
      throw TTSError.networkError("Invalid TTS endpoint URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let requestBody = TTSRequest(
      model: model,
      input: text,
      voice: voice,
      response_format: TTSConstants.outputFormat,
      speed: speed
    )

    request.httpBody = try JSONEncoder().encode(requestBody)

    NSLog("🔧 TTS-SERVICE: TTS request created successfully")
    return request
  }

  // MARK: - Validation Methods
  private func validateInputText(_ text: String) throws {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmedText.isEmpty {
      NSLog("⚠️ TTS-SERVICE: Input text is empty")
      throw TTSError.invalidInput
    }

    if trimmedText.count > TTSConstants.maxTextLength {
      NSLog(
        "⚠️ TTS-SERVICE: Input text too long: \(trimmedText.count) > \(TTSConstants.maxTextLength)")
      throw TTSError.invalidInput
    }
  }

  private func validateAudioData(_ data: Data) throws {
    if data.isEmpty {
      NSLog("⚠️ TTS-SERVICE: Received empty audio data")
      throw TTSError.audioGenerationFailed
    }

    if data.count < 100 {
      NSLog("⚠️ TTS-SERVICE: Audio data suspiciously small: \(data.count) bytes")
      throw TTSError.audioGenerationFailed
    }

    // Log first few bytes for debugging
    let headerBytes = Array(data.prefix(16))
    let headerHex = headerBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    NSLog("🔧 TTS-SERVICE: Audio header bytes: \(headerHex)")

    // More flexible audio format validation - OpenAI may return different formats
    let header = Array(data.prefix(10))
    let hasValidAudioHeader =
      header.starts(with: [0x49, 0x44, 0x33])  // ID3 tag
      || header.starts(with: [0xFF, 0xFB])  // MPEG Layer 3 (MP3)
      || header.starts(with: [0xFF, 0xFA])  // MPEG Layer 3 (MP3)
      || header.starts(with: [0xFF, 0xF3])  // MPEG Layer 3 (MP3)
      || header.starts(with: [0xFF, 0xF2])  // MPEG Layer 3 (MP3)
      || (header[0] == 0xFF && (header[1] & 0xE0) == 0xE0)  // Any MPEG audio frame
      || header.starts(with: Array("RIFF".utf8))  // WAV
      || header.starts(with: Array("OggS".utf8))  // OGG
      || header.starts(with: [0x66, 0x74, 0x79, 0x70])  // MP4/M4A (ftyp)

    if !hasValidAudioHeader {
      NSLog("⚠️ TTS-SERVICE: Unrecognized audio format - continuing anyway")
      // Don't throw error, let the audio player try to handle it
    } else {
      NSLog("✅ TTS-SERVICE: Recognized audio format")
    }

    NSLog("✅ TTS-SERVICE: Audio data validation passed (\(data.count) bytes)")
  }

  // MARK: - Error Handling
  private func parseErrorResponse(data: Data, statusCode: Int) throws -> TTSError {
    NSLog("🔧 TTS-SERVICE: Parsing error response (status: \(statusCode))")

    // Try to parse OpenAI error response
    if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
      NSLog("🔧 TTS-SERVICE: Parsed OpenAI error response")
      return parseOpenAIError(errorResponse, statusCode: statusCode)
    }

    // Fallback to status code error
    NSLog("🔧 TTS-SERVICE: Using status code fallback for error parsing")
    return parseStatusCodeError(statusCode)
  }

  private func parseOpenAIError(_ errorResponse: OpenAIErrorResponse, statusCode: Int) -> TTSError {
    let errorMessage = errorResponse.error?.message ?? "Unknown OpenAI error"
    NSLog("🔧 TTS-SERVICE: OpenAI error message: \(errorMessage)")

    switch statusCode {
    case 401:
      return .authenticationError
    case 400:
      return .invalidInput
    case 429:
      return .networkError("Rate limit exceeded")
    case 500...599:
      return .networkError("Server error: \(errorMessage)")
    default:
      return .networkError("HTTP \(statusCode): \(errorMessage)")
    }
  }

  private func parseStatusCodeError(_ statusCode: Int) -> TTSError {
    switch statusCode {
    case 401:
      return .authenticationError
    case 400:
      return .invalidInput
    case 429:
      return .networkError("Rate limit exceeded")
    case 500...599:
      return .networkError("Server error")
    default:
      return .networkError("HTTP error \(statusCode)")
    }
  }
}

// MARK: - TTS Request Model
struct TTSRequest: Codable {
  let model: String
  let input: String
  let voice: String
  let response_format: String?
  let speed: Double?
}

// MARK: - TTS Error Types
enum TTSError: Error, Equatable {
  case noAPIKey
  case invalidInput
  case authenticationError
  case networkError(String)
  case audioGenerationFailed

  var isRetryable: Bool {
    switch self {
    case .networkError:
      return true
    case .noAPIKey, .invalidInput, .authenticationError, .audioGenerationFailed:
      return false
    }
  }

  var localizedDescription: String {
    switch self {
    case .noAPIKey:
      return "No OpenAI API key available"
    case .invalidInput:
      return "Invalid input text for TTS"
    case .authenticationError:
      return "Authentication failed with OpenAI API"
    case .networkError(let message):
      return "Network error: \(message)"
    case .audioGenerationFailed:
      return "Failed to generate audio"
    }
  }

  // Add NSError compatibility for better error reporting
  var nsError: NSError {
    let domain = "WhisperShortcut.TTSError"
    let code: Int
    let userInfo: [String: Any]

    switch self {
    case .noAPIKey:
      code = 1
      userInfo = [NSLocalizedDescriptionKey: self.localizedDescription]
    case .invalidInput:
      code = 2
      userInfo = [NSLocalizedDescriptionKey: self.localizedDescription]
    case .authenticationError:
      code = 3
      userInfo = [NSLocalizedDescriptionKey: self.localizedDescription]
    case .networkError(let message):
      code = 4
      userInfo = [
        NSLocalizedDescriptionKey: "Network error: \(message)", "originalMessage": message,
      ]
    case .audioGenerationFailed:
      code = 5
      userInfo = [NSLocalizedDescriptionKey: self.localizedDescription]
    }

    return NSError(domain: domain, code: code, userInfo: userInfo)
  }
}

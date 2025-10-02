import AVFoundation
import Foundation

// MARK: - TTS Service Constants
private enum TTSConstants {
  static let endpoint = "https://api.openai.com/v1/audio/speech"
  static let requestTimeout: TimeInterval = 30.0
  static let maxTextLength = 4096  // OpenAI TTS text limit
  static let defaultVoice = "onyx"  // OpenAI TTS voice options: alloy, echo, fable, onyx, nova, shimmer, coral, verse, ballad, ash, sage, cedar
  // Realtime API voice options: alloy, ash, ballad, coral, echo, sage, shimmer, verse
  static let defaultModel = "gpt-4o-mini-tts"  // gpt-4o-mini-tts, gpt-4o-tts, tts-1, tts-1-hd
  static let outputFormat = "mp3"  // mp3, opus, aac, flac, wav, pcm
}

// MARK: - TTS Service Implementation
class TTSService {
  private let keychainManager: KeychainManaging
  private let session: URLSession

  // Expose maximum allowed text length for external callers
  static var maxAllowedTextLength: Int { TTSConstants.maxTextLength }

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

    // Validate API key
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      DebugLogger.logWarning("TTS-SERVICE: No API key available")
      throw TTSError.noAPIKey
    }

    // Validate input text
    try validateInputText(text)

    // Create request
    let request = try createTTSRequest(
      text: text, voice: voice, model: model, apiKey: apiKey, speed: speed)

    // Execute request
    let (data, response) = try await session.data(for: request)

    // Validate response
    guard let httpResponse = response as? HTTPURLResponse else {
      DebugLogger.logWarning("TTS-SERVICE: Invalid response type from OpenAI TTS")
      throw TTSError.networkError("Invalid response type")
    }

    if httpResponse.statusCode != 200 {
      DebugLogger.logWarning("TTS-SERVICE: OpenAI TTS HTTP error \(httpResponse.statusCode)")
      if let errorBody = String(data: data, encoding: .utf8) {
        DebugLogger.logWarning("TTS-SERVICE: Error response body: \(errorBody)")
      }
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    // Validate audio data
    try validateAudioData(data)

    DebugLogger.logSuccess("TTS-SERVICE: Successfully generated \(data.count) bytes of audio")
    return data
  }

  // MARK: - Request Creation
  private func createTTSRequest(
    text: String, voice: String, model: String, apiKey: String, speed: Double
  ) throws
    -> URLRequest
  {

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

    return request
  }

  // MARK: - Validation Methods
  private func validateInputText(_ text: String) throws {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmedText.isEmpty {
      DebugLogger.logWarning("TTS-SERVICE: Input text is empty")
      throw TTSError.invalidInput
    }

    if trimmedText.count > TTSConstants.maxTextLength {
      DebugLogger.logWarning("TTS-SERVICE: Input text too long: \(trimmedText.count) > \(TTSConstants.maxTextLength)")
      throw TTSError.textTooLong(characterCount: trimmedText.count, maxLength: TTSConstants.maxTextLength)
    }
  }

  private func validateAudioData(_ data: Data) throws {
    if data.isEmpty {
      DebugLogger.logWarning("TTS-SERVICE: Received empty audio data")
      throw TTSError.audioGenerationFailed
    }

    if data.count < 100 {
      DebugLogger.logWarning("TTS-SERVICE: Audio data suspiciously small: \(data.count) bytes")
      throw TTSError.audioGenerationFailed
    }

    let header = Array(data.prefix(10))
    let hasValidAudioHeader =
      header.starts(with: [0x49, 0x44, 0x33])  // ID3 tag
      || header.starts(with: [0xFF, 0xFB])  // MPEG Layer 3 (MP3)
      || header.starts(with: [0xFF, 0xFA])  // MPEG Layer 3 (MP3)
      || header.starts(with: [0xFF, 0xF3])  // MPEG Layer 3 (MP3)
      || header.starts(with: [0xFF, 0xF2])  // MPEG Layer 3 (MP3)
      || (header.first == 0xFF && header.count > 1 && (header[1] & 0xE0) == 0xE0)  // Any MPEG audio frame
      || header.starts(with: Array("RIFF".utf8))  // WAV
      || header.starts(with: Array("OggS".utf8))  // OGG
      || header.starts(with: [0x66, 0x74, 0x79, 0x70])  // MP4/M4A (ftyp)

    if !hasValidAudioHeader {
      DebugLogger.logWarning("TTS-SERVICE: Unrecognized audio format - proceeding")
    }

  }

  // MARK: - Error Handling
  private func parseErrorResponse(data: Data, statusCode: Int) throws -> TTSError {

    // Try to parse OpenAI error response
    if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
      return parseOpenAIError(errorResponse, statusCode: statusCode)
    }

    // Fallback to status code error
    return parseStatusCodeError(statusCode)
  }

  private func parseOpenAIError(_ errorResponse: OpenAIErrorResponse, statusCode: Int) -> TTSError {
    let errorMessage = errorResponse.error?.message ?? "Unknown OpenAI error"

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
  case textTooLong(characterCount: Int, maxLength: Int)
  case authenticationError
  case networkError(String)
  case audioGenerationFailed

  var localizedDescription: String {
    switch self {
    case .noAPIKey:
      return "No OpenAI API key available"
    case .invalidInput:
      return "Invalid input text for TTS"
    case .textTooLong(let characterCount, let maxLength):
      return "Text too long for speech synthesis: \(characterCount) characters (maximum: \(maxLength))"
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
    case .textTooLong(let characterCount, let maxLength):
      code = 6
      userInfo = [
        NSLocalizedDescriptionKey: self.localizedDescription,
        "characterCount": characterCount,
        "maxLength": maxLength
      ]
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

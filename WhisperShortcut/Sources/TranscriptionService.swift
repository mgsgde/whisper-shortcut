import Foundation

class TranscriptionService {
  private let baseURL = "https://api.openai.com/v1/audio/transcriptions"
  private let session = URLSession.shared
  private let keychainManager: KeychainManaging

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
      completion(.failure(TranscriptionError.noAPIKey))
      return
    }

    // Create a simple request to test the API key
    // We'll use the models endpoint which is lightweight and only requires authentication
    guard let url = URL(string: "https://api.openai.com/v1/models") else {
      completion(.failure(TranscriptionError.invalidResponse))
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
        completion(.failure(TranscriptionError.invalidResponse))
        return
      }

      switch httpResponse.statusCode {
      case 200:
        completion(.success(true))
      case 401:
        completion(.failure(TranscriptionError.unauthorized))
      case 429:
        completion(.failure(TranscriptionError.rateLimited))
      default:
        completion(.failure(TranscriptionError.httpError(httpResponse.statusCode)))
      }
    }.resume()
  }

  func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      let error = TranscriptionError.noAPIKey
      completion(.failure(error))
      return
    }

    // Check file size (Whisper API has 25MB limit)
    do {
      let fileAttributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
      if let fileSize = fileAttributes[.size] as? Int64 {
        let maxSize: Int64 = 25 * 1024 * 1024  // 25MB
        if fileSize > maxSize {
          completion(.failure(TranscriptionError.fileTooLarge))
          return
        }
      }
    } catch {
      completion(.failure(error))
      return
    }

    // Create multipart form data request
    let request = createMultipartRequest(audioURL: audioURL, apiKey: apiKey)

    // Execute request
    session.dataTask(with: request) { data, response, error in
      if let error = error {
        completion(.failure(error))
        return
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        completion(.failure(TranscriptionError.invalidResponse))
        return
      }

      guard let data = data else {
        completion(.failure(TranscriptionError.noData))
        return
      }

      // Handle response based on status code
      switch httpResponse.statusCode {
      case 200:
        self.parseSuccessResponse(data: data, completion: completion)
      case 400:
        completion(.failure(TranscriptionError.badRequest))
      case 401:
        completion(.failure(TranscriptionError.unauthorized))
      case 429:
        completion(.failure(TranscriptionError.rateLimited))
      default:
        let error = TranscriptionError.httpError(httpResponse.statusCode)
        completion(.failure(error))
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
      completion(.success(response.text))
    } catch {
      completion(.failure(TranscriptionError.parseError(error)))
    }
  }
}

// MARK: - Models
struct WhisperResponse: Codable {
  let text: String
}

// MARK: - Errors
enum TranscriptionError: LocalizedError {
  case noAPIKey
  case fileTooLarge
  case invalidResponse
  case noData
  case badRequest
  case unauthorized
  case rateLimited
  case httpError(Int)
  case parseError(Error)

  var errorDescription: String? {
    switch self {
    case .noAPIKey:
      return "OpenAI API key not configured"
    case .fileTooLarge:
      return "Audio file too large (max 25MB)"
    case .invalidResponse:
      return "Invalid response from server"
    case .noData:
      return "No data received from server"
    case .badRequest:
      return "Bad request - check audio file format"
    case .unauthorized:
      return "Unauthorized - check API key"
    case .rateLimited:
      return "Rate limited - please try again later"
    case .httpError(let code):
      return "HTTP error: \(code)"
    case .parseError(let error):
      return "Parse error: \(error.localizedDescription)"
    }
  }
}

import Foundation

// MARK: - Gemini Credential
/// Authentication for Gemini API: API key (query param).
enum GeminiCredential {
  case apiKey(String)
}

// MARK: - Gemini Error Response Models
/// Structured error response from Gemini API
struct GeminiErrorResponse: Codable {
    let error: GeminiErrorDetail

    struct GeminiErrorDetail: Codable {
        let code: Int
        let message: String
        let status: String?
    }

    /// Extracts the retry delay in seconds from the message text.
    /// Parses patterns like "Please retry in 55.764008118s." from the message.
    func extractRetryDelay() -> TimeInterval? {
        return Self.parseRetryDelayFromMessage(error.message)
    }

    /// Parses "Please retry in X.Xs" from an error message string
    static func parseRetryDelayFromMessage(_ message: String) -> TimeInterval? {
        // Pattern: "Please retry in 55.764008118s." or "retry in 30s"
        // Use regex to find the pattern
        let pattern = #"[Rr]etry in\s+(\d+(?:\.\d+)?)\s*s"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(
                  in: message,
                  options: [],
                  range: NSRange(message.startIndex..., in: message)
              ),
              let numberRange = Range(match.range(at: 1), in: message) else {
            return nil
        }

        let numberString = String(message[numberRange])
        return Double(numberString)
    }
}

// MARK: - Gemini API Client
/// Centralized client for all Gemini API interactions
/// Eliminates code duplication and improves maintainability
class GeminiAPIClient {
  
  // MARK: - Constants
  private enum Constants {
    static let requestTimeout: TimeInterval = 60.0
    static let resourceTimeout: TimeInterval = 300.0
    static let maxRetryAttempts = 4  // Increased to handle rate limiting with proper delays
    static let retryDelaySeconds: TimeInterval = 1.5
    static let filesAPIBaseURL = "https://generativelanguage.googleapis.com/upload/v1beta/files"
  }
  
  // MARK: - Properties
  private let session: URLSession
  
  // MARK: - Initialization
  init(session: URLSession? = nil) {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = Constants.requestTimeout
    config.timeoutIntervalForResource = Constants.resourceTimeout
    self.session = session ?? URLSession(configuration: config)
  }
  
  // MARK: - Request Creation
  /// Creates a URLRequest for Gemini API with credential (API key).
  func createRequest(endpoint: String, credential: GeminiCredential) throws -> URLRequest {
    guard let baseURL = URL(string: endpoint),
          var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw TranscriptionError.invalidRequest
    }

    switch credential {
    case .apiKey(let key):
      components.queryItems = [URLQueryItem(name: "key", value: key)]
    }

    guard let url = components.url else {
      throw TranscriptionError.invalidRequest
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = Constants.resourceTimeout
    return request
  }

  /// Creates a URLRequest using API key (convenience for callers that only have a key).
  func createRequest(endpoint: String, apiKey: String) throws -> URLRequest {
    try createRequest(endpoint: endpoint, credential: .apiKey(apiKey))
  }
  
  // MARK: - Request Execution
  /// Generic helper to perform Gemini API requests with error handling and retry logic
  func performRequest<T: Decodable>(
    _ request: URLRequest,
    responseType: T.Type,
    mode: String = "GEMINI",
    withRetry: Bool = false
  ) async throws -> T {
    var lastError: Error?
    let maxAttempts = withRetry ? Constants.maxRetryAttempts : 1
    
    for attempt in 1...maxAttempts {
      do {
        if attempt > 1 {
          DebugLogger.log("\(mode)-RETRY: Attempt \(attempt)/\(maxAttempts)")
        }
        
        DebugLogger.log("\(mode): Sending request (attempt \(attempt)/\(maxAttempts))")
        let (data, response) = try await session.data(for: request)
        DebugLogger.log("\(mode): Received response")
        
        guard let httpResponse = response as? HTTPURLResponse else {
          throw TranscriptionError.networkError("Invalid response")
        }
        
        if httpResponse.statusCode != 200 {
          // Log detailed error information
          let errorBody = String(data: data, encoding: .utf8) ?? "Unable to decode error response"
          DebugLogger.log("\(mode)-ERROR: HTTP \(httpResponse.statusCode)")
          DebugLogger.log("\(mode)-ERROR: Response body: \(errorBody.prefix(500))")
          
          // Check for rate limiting or quota issues
          if httpResponse.statusCode == 429 {
            DebugLogger.log("\(mode)-ERROR: Rate limit exceeded - API may be throttling requests")
          } else if httpResponse.statusCode == 403 {
            DebugLogger.log("\(mode)-ERROR: Forbidden - Check API key permissions and quota")
          } else if httpResponse.statusCode == 401 {
            DebugLogger.log("\(mode)-ERROR: Unauthorized - Invalid API key")
          }
          
          let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
          throw error
        }
        
        // Parse response
        DebugLogger.log("\(mode): Parsing response (data size: \(data.count) bytes)")
        
        // Log raw response for debugging (especially for TTS) - BEFORE decoding
        if mode == "TTS" {
          DebugLogger.log("TTS: Starting response analysis...")
          // Check if data is valid
          guard data.count > 0 else {
            DebugLogger.logError("TTS: Response data is empty")
            throw TranscriptionError.networkError("Empty response from TTS API")
          }
          
          // Try to parse as JSON first to validate structure
          do {
            let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let jsonObject = jsonObject {
              DebugLogger.log("TTS: Response is valid JSON with keys: \(jsonObject.keys.joined(separator: ", "))")
              
              if let candidates = jsonObject["candidates"] as? [[String: Any]], let firstCandidate = candidates.first {
                DebugLogger.log("TTS: Found \(candidates.count) candidate(s), first candidate keys: \(firstCandidate.keys.joined(separator: ", "))")
                
                if let content = firstCandidate["content"] as? [String: Any] {
                  DebugLogger.log("TTS: Content keys: \(content.keys.joined(separator: ", "))")
                  
                  if let parts = content["parts"] as? [[String: Any]], let firstPart = parts.first {
                    DebugLogger.log("TTS: Found \(parts.count) part(s), first part keys: \(firstPart.keys.joined(separator: ", "))")
                    
                    if let inlineData = firstPart["inlineData"] as? [String: Any] {
                      DebugLogger.log("TTS: ✅ inlineData found with keys: \(inlineData.keys.joined(separator: ", "))")
                      if let mimeType = inlineData["mimeType"] as? String {
                        DebugLogger.log("TTS: MIME type: \(mimeType)")
                      }
                      if let dataString = inlineData["data"] as? String {
                        DebugLogger.log("TTS: Base64 data length: \(dataString.count) chars (approx \(dataString.count * 3 / 4) bytes when decoded)")
                      } else {
                        DebugLogger.logError("TTS: inlineData exists but 'data' field is missing or wrong type")
                      }
                    } else {
                      DebugLogger.logError("TTS: ❌ No inlineData found in first part")
                      // Log what we actually have
                      for (key, value) in firstPart {
                        DebugLogger.log("TTS: Part has key '\(key)' with type: \(type(of: value))")
                      }
                    }
                  } else {
                    DebugLogger.logError("TTS: No parts found in content")
                  }
                } else {
                  DebugLogger.logError("TTS: No content found in candidate")
                }
              } else {
                DebugLogger.logError("TTS: No candidates found in response")
              }
            } else {
              DebugLogger.logError("TTS: Response is not a dictionary")
            }
          } catch {
            DebugLogger.logError("TTS: Failed to parse JSON: \(error.localizedDescription)")
            // Try to log first 500 chars anyway
            if let jsonString = String(data: data.prefix(500), encoding: .utf8) {
              DebugLogger.log("TTS: First 500 bytes as string: \(jsonString)")
            }
          }
        }
        
        // Now try to decode
        do {
          DebugLogger.log("\(mode): Attempting to decode response...")
          let result = try JSONDecoder().decode(T.self, from: data)
          DebugLogger.log("\(mode): ✅ Decoding successful")
          
          if attempt > 1 {
            DebugLogger.log("\(mode)-RETRY: Success on attempt \(attempt)")
          }
          
          return result
        } catch let decodingError as DecodingError {
          DebugLogger.logError("\(mode): ❌ Decoding error: \(decodingError)")
          switch decodingError {
          case .keyNotFound(let key, let context):
            DebugLogger.logError("\(mode): Missing key '\(key.stringValue)' at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
          case .typeMismatch(let type, let context):
            DebugLogger.logError("\(mode): Type mismatch for type '\(type)' at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
          case .valueNotFound(let type, let context):
            DebugLogger.logError("\(mode): Value not found for type '\(type)' at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
          case .dataCorrupted(let context):
            DebugLogger.logError("\(mode): Data corrupted at path: \(context.codingPath.map { $0.stringValue }.joined(separator: ".")), error: \(context.debugDescription)")
          @unknown default:
            DebugLogger.logError("\(mode): Unknown decoding error: \(decodingError)")
          }
          throw decodingError
        } catch {
          DebugLogger.logError("\(mode): Unexpected parsing error: \(error.localizedDescription)")
          throw error
        }
        
      } catch is CancellationError {
        DebugLogger.log("\(mode)-RETRY: Cancelled on attempt \(attempt)")
        throw CancellationError()
      } catch let error as URLError {
        // Log detailed network error information
        DebugLogger.logError("\(mode)-NETWORK-ERROR: URLError code: \(error.code.rawValue), description: \(error.localizedDescription)")
        if let failingURL = error.userInfo["NSErrorFailingURLStringKey"] as? String {
          DebugLogger.logError("\(mode)-NETWORK-ERROR: Failing URL: \(failingURL)")
        }
        if let underlyingError = error.userInfo["NSUnderlyingErrorKey"] as? Error {
          DebugLogger.logError("\(mode)-NETWORK-ERROR: Underlying error: \(underlyingError.localizedDescription)")
        }
        
        if error.code == .cancelled {
          DebugLogger.log("\(mode)-RETRY: Request cancelled by user")
          throw CancellationError()
        } else if error.code == .timedOut {
          DebugLogger.logError("\(mode)-NETWORK-ERROR: Request timed out")
          throw error.localizedDescription.contains("request")
            ? TranscriptionError.requestTimeout
            : TranscriptionError.resourceTimeout
        } else if error.code.rawValue == -1005 || error.localizedDescription.contains("connection was lost") || error.localizedDescription.contains("network connection") {
          // Network connection lost (code -1005)
          DebugLogger.logError("\(mode)-NETWORK-ERROR: Connection lost (URLError code: \(error.code.rawValue)) - will retry if attempts remaining")
          lastError = TranscriptionError.networkError("Network connection lost: \(error.localizedDescription)")
          if attempt < maxAttempts {
            DebugLogger.log("\(mode)-RETRY: Connection lost, retrying in \(Constants.retryDelaySeconds)s...")
            try? await Task.sleep(nanoseconds: UInt64(Constants.retryDelaySeconds * 1_000_000_000))
            continue
          }
          throw TranscriptionError.networkError("Network connection lost: \(error.localizedDescription)")
        } else {
          DebugLogger.logError("\(mode)-NETWORK-ERROR: Other network error: \(error.localizedDescription)")
          lastError = TranscriptionError.networkError(error.localizedDescription)
          if attempt < maxAttempts {
            DebugLogger.log("\(mode)-RETRY: Network error, retrying in \(Constants.retryDelaySeconds)s...")
            try? await Task.sleep(nanoseconds: UInt64(Constants.retryDelaySeconds * 1_000_000_000))
            continue
          }
          throw TranscriptionError.networkError(error.localizedDescription)
        }
      } catch {
        lastError = error

        // Do not retry on invalid/incorrect API key – fail immediately
        if let te = error as? TranscriptionError, te == .invalidAPIKey || te == .incorrectAPIKey {
          DebugLogger.log("\(mode)-RETRY: API key error – not retrying")
          throw error
        }

        // Only handle rate limit retries when withRetry is enabled
        // When withRetry: false, the caller (e.g., chunk services) handles retries with their own coordinator
        if withRetry {
          // Check if this is a rate limit error with a retry delay
          if let transcriptionError = error as? TranscriptionError,
             let retryAfter = transcriptionError.retryAfter {
            // Use the API-provided retry delay
            let waitTime = retryAfter + 2.0  // Add small buffer
            DebugLogger.log("\(mode)-RETRY: Rate limited, waiting \(String(format: "%.1f", waitTime))s as requested by API...")

            // Notify UI about rate limit waiting
            await MainActor.run {
              NotificationCenter.default.post(
                name: .rateLimitWaiting,
                object: nil,
                userInfo: ["waitTime": waitTime]
              )
            }

            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))

            // Notify UI that wait is complete
            await MainActor.run {
              NotificationCenter.default.post(name: .rateLimitResolved, object: nil)
            }

            continue  // Always retry after API-requested wait
          }
        }

        if attempt < maxAttempts {
          let delay: TimeInterval
          if let te = error as? TranscriptionError, te.isServerOrUnavailable {
            delay = 2.0 * pow(2.0, Double(attempt - 1))
          } else {
            delay = Constants.retryDelaySeconds
          }
          DebugLogger.log("\(mode)-RETRY: Attempt \(attempt) failed, retrying in \(String(format: "%.1f", delay))s: \(error.localizedDescription)")
          try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
      }
    }

    DebugLogger.log("\(mode)-RETRY: All \(maxAttempts) attempts failed")
    throw lastError ?? TranscriptionError.networkError("Gemini request failed after retries")
  }
  
  // MARK: - Chat

  /// Sends a multi-turn chat request to Gemini and returns the model's text reply plus optional grounding sources.
  /// - Parameters:
  ///   - model: Gemini model ID, e.g. "gemini-2.5-flash"
  ///   - contents: Array of turn dicts in Gemini format: [["role": "user", "parts": [["text": "..."]]]]
  ///   - apiKey: Google API key
  ///   - useGrounding: When true, adds the `google_search` tool so Gemini can ground answers in live search results
  ///   - systemInstruction: Optional system instruction (e.g. style guidance). API format: ["parts": [["text": "..."]]]
  func sendChatMessage(
    model: String,
    contents: [[String: Any]],
    apiKey: String,
    useGrounding: Bool = false,
    systemInstruction: [String: Any]? = nil
  ) async throws -> (text: String, sources: [GroundingSource], supports: [GroundingSupport]) {
    let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
    var request = try createRequest(endpoint: endpoint, apiKey: apiKey)

    var body: [String: Any] = ["contents": contents]
    if useGrounding {
      body["tools"] = [["google_search": [:]]]
      DebugLogger.logNetwork("GEMINI-CHAT: Google Search grounding enabled")
    }
    if let sys = systemInstruction {
      body["system_instruction"] = sys
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let response: GeminiResponse = try await performRequest(
      request, responseType: GeminiResponse.self, mode: "GEMINI-CHAT", withRetry: true)

    let text = extractText(from: response)
    guard !text.isEmpty else {
      throw TranscriptionError.networkError("Empty response from Gemini")
    }

    let sources = extractGroundingSources(from: response)
    let supports = extractGroundingSupports(from: response)
    if !sources.isEmpty {
      DebugLogger.logNetwork("GEMINI-CHAT: \(sources.count) grounding source(s) returned")
    }
    if !supports.isEmpty {
      DebugLogger.logNetwork("GEMINI-CHAT: \(supports.count) grounding support(s) for inline citations")
    }
    return (text: text, sources: sources, supports: supports)
  }

  /// Extracts grounding sources (web URIs + titles) from a Gemini response.
  private func extractGroundingSources(from response: GeminiResponse) -> [GroundingSource] {
    guard let candidate = response.candidates.first,
      let metadata = candidate.groundingMetadata,
      let chunks = metadata.groundingChunks
    else { return [] }

    return chunks.compactMap { chunk -> GroundingSource? in
      guard let uri = chunk.web?.uri, !uri.isEmpty else { return nil }
      let title = chunk.web?.title ?? uri
      return GroundingSource(uri: uri, title: title)
    }
  }

  /// Extracts grounding supports (text ranges → chunk indices) for inline citations.
  private func extractGroundingSupports(from response: GeminiResponse) -> [GroundingSupport] {
    guard let candidate = response.candidates.first,
          let metadata = candidate.groundingMetadata,
          let raw = metadata.groundingSupports
    else { return [] }

    return raw.compactMap { s -> GroundingSupport? in
      guard let seg = s.segment,
            let start = seg.startIndex,
            let end = seg.endIndex,
            start >= 0, end > start,
            let indices = s.groundingChunkIndices, !indices.isEmpty
      else { return nil }
      return GroundingSupport(startIndex: start, endIndex: end, groundingChunkIndices: indices)
    }
  }

  // MARK: - File Upload
  /// Uploads a file to Gemini using resumable upload protocol.
  func uploadFile(audioURL: URL, credential: GeminiCredential) async throws -> String {
    let audioData = try Data(contentsOf: audioURL)

    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = getMimeType(for: fileExtension)
    let numBytes = audioData.count
    DebugLogger.log("GEMINI-FILES-API: Uploading file (\(numBytes) bytes, \(mimeType))")

    guard let baseURL = URL(string: Constants.filesAPIBaseURL),
          var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw TranscriptionError.invalidRequest
    }

    switch credential {
    case .apiKey(let key):
      components.queryItems = [URLQueryItem(name: "key", value: key)]
    }

    guard let initURL = components.url else {
      throw TranscriptionError.invalidRequest
    }

    var initRequest = URLRequest(url: initURL)
    initRequest.httpMethod = "POST"
    initRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    initRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
    initRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
    initRequest.setValue("\(numBytes)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
    initRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")

    let metadata: [String: Any] = [
      "file": [
        "display_name": "audio_\(Date().timeIntervalSince1970)"
      ]
    ]
    initRequest.httpBody = try JSONSerialization.data(withJSONObject: metadata)
    
    let (initData, initResponse) = try await session.data(for: initRequest)
    
    guard let httpResponse = initResponse as? HTTPURLResponse else {
      DebugLogger.log("GEMINI-FILES-API: ERROR - Invalid response type")
      throw TranscriptionError.networkError("Invalid response")
    }
    
    guard httpResponse.statusCode == 200 else {
      let errorBody = String(data: initData, encoding: .utf8) ?? "Unable to decode error response"
      DebugLogger.log("GEMINI-FILES-API: ERROR - Init failed with status \(httpResponse.statusCode): \(errorBody.prefix(500))")
      let error = try parseErrorResponse(data: initData, statusCode: httpResponse.statusCode)
      throw error
    }
    
    // Extract upload URL from response headers (case-insensitive search)
    let allHeaders = httpResponse.allHeaderFields
    
    // Search for upload URL header case-insensitively
    var uploadURLString: String?
    for (key, value) in allHeaders {
      if let keyString = key as? String,
         keyString.lowercased() == "x-goog-upload-url",
         let valueString = value as? String {
        uploadURLString = valueString
        break
      }
    }
    
    guard let uploadURLString = uploadURLString,
          let uploadURL = URL(string: uploadURLString) else {
      DebugLogger.log("GEMINI-FILES-API: ERROR - Failed to get upload URL from headers")
      throw TranscriptionError.networkError("Failed to get upload URL")
    }
    
    // Step 2: Upload file data
    var uploadRequest = URLRequest(url: uploadURL)
    uploadRequest.httpMethod = "PUT"
    uploadRequest.setValue("\(numBytes)", forHTTPHeaderField: "Content-Length")
    uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
    uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
    uploadRequest.httpBody = audioData
    
    let (uploadData, uploadResponse) = try await session.data(for: uploadRequest)
    
    guard let uploadHttpResponse = uploadResponse as? HTTPURLResponse else {
      DebugLogger.log("GEMINI-FILES-API: ERROR - Invalid upload response type")
      throw TranscriptionError.networkError("Invalid response")
    }
    
    guard uploadHttpResponse.statusCode == 200 else {
      let errorBody = String(data: uploadData, encoding: .utf8) ?? "Unable to decode error response"
      DebugLogger.log("GEMINI-FILES-API: ERROR - Upload failed with status \(uploadHttpResponse.statusCode): \(errorBody.prefix(500))")
      let error = try parseErrorResponse(data: uploadData, statusCode: uploadHttpResponse.statusCode)
      throw error
    }
    
    // Parse file info to get URI
    let fileInfo = try JSONDecoder().decode(GeminiFileInfo.self, from: uploadData)
    DebugLogger.log("GEMINI-FILES-API: Upload successful, file URI: \(fileInfo.file.uri)")
    
    return fileInfo.file.uri
  }
  
  // MARK: - Helper Methods
  
  /// Gets the MIME type for a given file extension
  func getMimeType(for fileExtension: String) -> String {
    switch fileExtension {
    case "wav": return "audio/wav"
    case "mp3": return "audio/mp3"
    case "aiff": return "audio/aiff"
    case "aac": return "audio/aac"
    case "ogg": return "audio/ogg"
    case "flac": return "audio/flac"
    default: return "audio/wav"
    }
  }
  
  /// Extracts text content from a Gemini transcription response
  func extractText(from response: GeminiResponse) -> String {
    guard let candidate = response.candidates.first,
          let content = candidate.content,
          let parts = content.parts else {
      return ""
    }
    
    // Extract text from parts
    var text = ""
    for part in parts {
      if let partText = part.text {
        text += partText
      }
    }
    
    return text
  }
  
  /// Parses Gemini error responses into TranscriptionError
  func parseErrorResponse(data: Data, statusCode: Int) throws -> TranscriptionError {
    // Try to parse structured Gemini error format with RetryInfo
    var retryAfter: TimeInterval? = nil

    if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
      retryAfter = errorResponse.extractRetryDelay()
      if let retryAfter = retryAfter {
        DebugLogger.log("GEMINI-ERROR: Found retryDelay: \(retryAfter)s")
      }

      let message = errorResponse.error.message
      DebugLogger.log("GEMINI-ERROR: \(message)")

      // Map common Gemini errors to TranscriptionError
      let lowerMessage = message.lowercased()
      if lowerMessage.contains("api key") || lowerMessage.contains("authentication") {
        return statusCode == 401 ? .invalidAPIKey : .incorrectAPIKey
      }
      if lowerMessage.contains("quota") || lowerMessage.contains("exceeded") {
        return .quotaExceeded(retryAfter: retryAfter)
      }
      if lowerMessage.contains("rate limit") {
        return .rateLimited(retryAfter: retryAfter)
      }
      if statusCode == 404 && (lowerMessage.contains("no longer available") || lowerMessage.contains("deprecated")) {
        return .modelDeprecated
      }
    } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String {
      // Fallback to manual JSON parsing
      DebugLogger.log("GEMINI-ERROR: \(message)")

      // Try to extract retry delay from the message text
      let fallbackRetryAfter = GeminiErrorResponse.parseRetryDelayFromMessage(message)
      if let fallbackRetryAfter = fallbackRetryAfter {
        DebugLogger.log("GEMINI-ERROR: Found retryDelay in message: \(fallbackRetryAfter)s")
        retryAfter = fallbackRetryAfter
      }

      let lowerMessage = message.lowercased()
      if lowerMessage.contains("api key") || lowerMessage.contains("authentication") {
        return statusCode == 401 ? .invalidAPIKey : .incorrectAPIKey
      }
      if lowerMessage.contains("quota") || lowerMessage.contains("exceeded") {
        return .quotaExceeded(retryAfter: retryAfter)
      }
      if lowerMessage.contains("rate limit") {
        return .rateLimited(retryAfter: retryAfter)
      }
      if statusCode == 404 && (lowerMessage.contains("no longer available") || lowerMessage.contains("deprecated")) {
        return .modelDeprecated
      }
    }

    // Fall back to status code parsing
    return parseStatusCodeError(statusCode, retryAfter: retryAfter)
  }

  /// Maps HTTP status codes to TranscriptionError
  private func parseStatusCodeError(_ statusCode: Int, retryAfter: TimeInterval? = nil) -> TranscriptionError {
    switch statusCode {
    case 400: return .invalidRequest
    case 401: return .invalidAPIKey
    case 403: return .permissionDenied
    case 404: return .notFound
    case 429: return .rateLimited(retryAfter: retryAfter)
    case 500: return .serverError(statusCode)
    case 503: return .serviceUnavailable
    default: return .serverError(statusCode)
    }
  }
}





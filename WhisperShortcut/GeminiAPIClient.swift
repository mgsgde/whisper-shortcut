import Foundation

// MARK: - Gemini Credential
/// Authentication for Gemini: API key (direct to Gemini API) or Bearer ID token (proxy only; SSO).
/// When using SSO, the app only talks to the backend proxy; direct Gemini API is not used.
enum GeminiCredential {
  case apiKey(String)
  /// Bearer ID token for backend proxy (whisper-api). Used when signed in with Google; backend verifies JWT.
  case bearer(String)

  /// True when credential is for proxy (SSO path). Requests must go to backend, not direct Gemini API.
  var isOAuth: Bool {
    if case .bearer = self { return true }
    return false
  }
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
  /// Creates a URLRequest for Gemini API with optional credential (API key). When credential is nil (e.g. proxy mode), no key is added.
  func createRequest(endpoint: String, credential: GeminiCredential?) throws -> URLRequest {
    guard let baseURL = URL(string: endpoint),
          var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw TranscriptionError.invalidRequest
    }

    if let credential = credential {
      switch credential {
      case .apiKey(let key):
        components.queryItems = [URLQueryItem(name: "key", value: key)]
      case .bearer:
        break
      }
    }

    guard let url = components.url else {
      throw TranscriptionError.invalidRequest
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = Constants.resourceTimeout
    if let credential = credential {
      switch credential {
      case .bearer(let token):
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      case .apiKey:
        break
      }
    }
    return request
  }

  /// Creates a URLRequest using API key (convenience for callers that only have a key).
  func createRequest(endpoint: String, apiKey: String) throws -> URLRequest {
    try createRequest(endpoint: endpoint, credential: .apiKey(apiKey))
  }

  // MARK: - Proxy Endpoint Resolution (Phase 1)
  /// Resolves the effective generateContent endpoint and credential.
  /// When user is signed in (OAuth) and proxy base URL is set, uses proxy. Otherwise direct Gemini.
  /// When using SSO (bearer), returns proxy URL and nil (caller must use resolveCredentialForRequest to get Bearer ID token).
  static func resolveGenerateContentEndpoint(directEndpoint: String, credential: GeminiCredential) -> (endpoint: String, credential: GeminiCredential?) {
    let base = SettingsDefaults.proxyAPIBaseURL
    if credential.isOAuth, !base.isEmpty {
      let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
      return (trimmed + "/v1/gemini/generateContent", nil)
    }
    return (directEndpoint, credential)
  }

  /// When resolved credential is nil (proxy path), returns .bearer(ID token) for request auth if signed in; otherwise nil.
  /// Call before createRequest so proxy requests get Authorization: Bearer <Google ID token>.
  static func resolveCredentialForRequest(endpoint: String, resolvedCredential: GeminiCredential?) async -> GeminiCredential? {
    if let cred = resolvedCredential { return cred }
    let base = SettingsDefaults.proxyAPIBaseURL
    guard !base.isEmpty else { return nil }
    let proxyPath = (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/v1/gemini/generateContent"
    guard endpoint == proxyPath, DefaultGoogleAuthService.shared.isSignedIn(),
          let idToken = await DefaultGoogleAuthService.shared.getIDToken(), !idToken.isEmpty else {
      return nil
    }
    return .bearer(idToken)
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
        let requestStart = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await session.data(for: request)
        let roundTripMs = Int(round((CFAbsoluteTimeGetCurrent() - requestStart) * 1000))
        DebugLogger.logNetwork("\(mode): Round-trip \(roundTripMs) ms")
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
        
        // Log raw response parts for GEMINI-CHAT to verify code execution tool usage
        if mode == "GEMINI-CHAT" {
          if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
             let candidates = jsonObject["candidates"] as? [[String: Any]],
             let firstCandidate = candidates.first,
             let content = firstCandidate["content"] as? [String: Any],
             let parts = content["parts"] as? [[String: Any]] {
            let partTypes = parts.map { part -> String in
              return part.keys.sorted().joined(separator: "+")
            }
            DebugLogger.logNetwork("GEMINI-CHAT: Response has \(parts.count) part(s), raw keys: [\(partTypes.joined(separator: ", "))]")
          }
        }

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
  
  // MARK: - Streaming Chat

  /// One event emitted while streaming a Gemini chat reply.
  enum ChatStreamEvent {
    /// Incremental text appended to the model's reply.
    case textDelta(String)
    /// Model requested a local tool call. The caller should execute the tool,
    /// append a `functionResponse` turn to `contents`, and re-invoke the stream.
    /// `thoughtSignature` must be echoed back in the model turn on the next request
    /// (required by Gemini 3 — missing it returns HTTP 400).
    case functionCall(name: String, args: [String: Any], thoughtSignature: String?)
    /// Final event with grounding metadata and finish reason. Emitted exactly once, just before the stream ends.
    case finished(sources: [GroundingSource], supports: [GroundingSupport], finishReason: String?)
  }

  /// Streams a chat reply from Gemini via the backend proxy (SSE). Yields text deltas as they arrive,
  /// then a single `.finished` event with grounding metadata. Cancel the consuming Task to abort the upstream request.
  /// - Parameter functionDeclarations: Optional list of custom function declarations (Gemini Tool format)
  ///   to enable function calling. When the model requests a call, a `.functionCall` event is yielded.
  func sendChatMessageStream(
    model: String,
    contents: [[String: Any]],
    credential: GeminiCredential,
    useGrounding: Bool = false,
    systemInstruction: [String: Any]? = nil,
    functionDeclarations: [[String: Any]] = []
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          // Build endpoint: proxy if OAuth, else direct Gemini streamGenerateContent?alt=sse.
          let proxyBase: String = {
            let base = SettingsDefaults.proxyAPIBaseURL
            return base.hasSuffix("/") ? String(base.dropLast()) : base
          }()
          let endpoint: String
          let credentialForRequest: GeminiCredential?
          switch credential {
          case .bearer:
            endpoint = proxyBase + "/v1/gemini/streamGenerateContent"
            credentialForRequest = await Self.resolveCredentialForRequest(endpoint: endpoint, resolvedCredential: credential)
          case .apiKey:
            endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse"
            credentialForRequest = credential
          }
          var request = try self.createRequest(endpoint: endpoint, credential: credentialForRequest)
          request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
          request.timeoutInterval = Constants.resourceTimeout

          var body: [String: Any] = ["contents": contents]
          var tools: [[String: Any]] = []
          if useGrounding {
            tools.append(["google_search": [:]])
            tools.append(["url_context": [:]])
          }
          // Custom function declarations take precedence: when tools are defined,
          // Gemini's built-in code_execution can conflict on some model versions,
          // so we only include it when no custom tools are provided.
          if functionDeclarations.isEmpty {
            tools.append(["code_execution": [:]])
          } else {
            tools.append(["function_declarations": functionDeclarations])
            // Gemini 3 Flash rejects built-in tools (google_search/url_context)
            // combined with function_declarations unless this flag is set.
            body["tool_config"] = [
              "include_server_side_tool_invocations": true
            ]
          }
          body["tools"] = tools
          if let sys = systemInstruction {
            body["system_instruction"] = sys
          }
          body["generationConfig"] = [
            "temperature": 0.7,
            "topP": 0.95,
            "maxOutputTokens": 8192,
            // Disable thinking for chat: dynamic thinking (-1) delays the first
            // output token by several seconds, defeating the visible-streaming UX.
            "thinkingConfig": ["thinkingBudget": 0]
          ]
          body["safetySettings"] = [
            ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_ONLY_HIGH"],
            ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_ONLY_HIGH"],
            ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_ONLY_HIGH"],
            ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_ONLY_HIGH"]
          ]
          if endpoint.hasPrefix(proxyBase) {
            body["request_type"] = "gemini_chat"
            body["model"] = model
          }
          request.httpBody = try JSONSerialization.data(withJSONObject: body)

          DebugLogger.logNetwork("GEMINI-CHAT-STREAM: POST \(endpoint)")
          let (bytes, response) = try await self.session.bytes(for: request)
          guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.networkError("Invalid response")
          }
          if http.statusCode < 200 || http.statusCode >= 300 {
            var errData = Data()
            for try await b in bytes { errData.append(b) }
            let text = String(data: errData, encoding: .utf8) ?? ""
            DebugLogger.logError("GEMINI-CHAT-STREAM: HTTP \(http.statusCode) body=\(text.prefix(500))")
            throw TranscriptionError.networkError("HTTP \(http.statusCode): \(text)")
          }

          var aggregatedSources: [GroundingSource] = []
          var aggregatedSupports: [GroundingSupport] = []
          var finishReason: String?

          // Decode one complete top-level JSON object from the stream.
          func processChunk(_ jsonData: Data) {
            if let chunk = try? JSONDecoder().decode(GeminiResponse.self, from: jsonData) {
              let deltaText = self.extractText(from: chunk)
              if !deltaText.isEmpty {
                continuation.yield(.textDelta(deltaText))
              }
              let chunkSources = self.extractGroundingSources(from: chunk)
              let chunkSupports = self.extractGroundingSupports(from: chunk)
              if !chunkSources.isEmpty { aggregatedSources = chunkSources }
              if !chunkSupports.isEmpty { aggregatedSupports = chunkSupports }
              if let reason = chunk.candidates.first?.finishReason { finishReason = reason }
              if let usage = chunk.usageMetadata, let total = usage.totalTokenCount, total > 0 {
                DebugLogger.logNetwork(
                  "GEMINI-CHAT-STREAM: usage prompt=\(usage.promptTokenCount ?? 0) output=\(usage.candidatesTokenCount ?? 0) thoughts=\(usage.thoughtsTokenCount ?? 0) total=\(total)")
              }
            }
            // …and also parse as dict to detect functionCall parts (not in Codable model).
            if !functionDeclarations.isEmpty,
               let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let candidates = obj["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
              for part in parts {
                if let fc = part["functionCall"] as? [String: Any] ?? part["function_call"] as? [String: Any],
                   let name = fc["name"] as? String {
                  let args = (fc["args"] as? [String: Any]) ?? [:]
                  // Gemini 3 requires thoughtSignature to be echoed back with the
                  // functionCall part on the follow-up turn, or the API returns 400.
                  let thoughtSignature = part["thoughtSignature"] as? String
                    ?? part["thought_signature"] as? String
                  DebugLogger.logNetwork("GEMINI-CHAT-STREAM: functionCall name=\(name) sig=\(thoughtSignature != nil ? "yes" : "no")")
                  continuation.yield(.functionCall(name: name, args: args, thoughtSignature: thoughtSignature))
                }
              }
            }
          }

          // Byte-level parser: Gemini's streamGenerateContent may return either
          // SSE (`data: {…}\n\n`) or a pretty-printed JSON array (`[ {…}, {…} ]`)
          // depending on whether `?alt=sse` is honored. Parsing at the JSON-object
          // level by tracking brace depth emits complete `{…}` chunks as soon as
          // they arrive in either format.
          var objectBytes = Data()
          var depth = 0
          var inString = false
          var escape = false
          var chunkCount = 0
          for try await byte in bytes {
            try Task.checkCancellation()
            let ch = Character(UnicodeScalar(byte))
            if depth == 0 {
              if ch == "{" {
                objectBytes.removeAll(keepingCapacity: true)
                objectBytes.append(byte)
                depth = 1
                inString = false
                escape = false
              }
              continue
            }
            objectBytes.append(byte)
            if inString {
              if escape {
                escape = false
              } else if ch == "\\" {
                escape = true
              } else if ch == "\"" {
                inString = false
              }
              continue
            }
            if ch == "\"" {
              inString = true
              continue
            }
            if ch == "{" {
              depth += 1
            } else if ch == "}" {
              depth -= 1
              if depth == 0 {
                chunkCount += 1
                processChunk(objectBytes)
                objectBytes.removeAll(keepingCapacity: true)
              }
            }
          }
          DebugLogger.logNetwork("GEMINI-CHAT-STREAM: stream end, totalObjects=\(chunkCount)")

          if let reason = finishReason, reason != "STOP" {
            DebugLogger.logWarning("GEMINI-CHAT-STREAM: finishReason=\(reason)")
          }
          DebugLogger.logNetwork("GEMINI-CHAT-STREAM: grounding sources=\(aggregatedSources.count) supports=\(aggregatedSupports.count)")
          continuation.yield(.finished(sources: aggregatedSources, supports: aggregatedSupports, finishReason: finishReason))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  /// Lightweight single-shot text generation — no tools, no retry, minimal tokens.
  /// Used for background tasks like session title generation. API key only.
  func generateText(model: String, prompt: String, apiKey: String) async throws -> String {
    try await generateText(model: model, prompt: prompt, credential: .apiKey(apiKey))
  }

  /// Lightweight single-shot text generation using credential (API key or Bearer for proxy). When using proxy, sends request_type so backend applies subscription model.
  /// - Parameter requestTypeForProxy: When using proxy (OAuth), request_type sent to backend (e.g. "gemini_chat", "meeting_summary"). Ignored for API key.
  func generateText(model: String, prompt: String, credential: GeminiCredential, requestTypeForProxy: String = "gemini_chat") async throws -> String {
    let directEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
    let (endpoint, resolvedCredential) = Self.resolveGenerateContentEndpoint(directEndpoint: directEndpoint, credential: credential)
    let credentialForRequest = await Self.resolveCredentialForRequest(endpoint: endpoint, resolvedCredential: resolvedCredential)
    var request = try createRequest(endpoint: endpoint, credential: credentialForRequest)
    var body: [String: Any] = [
      "contents": [["role": "user", "parts": [["text": prompt]]]]
    ]
    let proxyPath = {
      let base = SettingsDefaults.proxyAPIBaseURL
      let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
      return trimmed + "/v1/gemini/generateContent"
    }()
    if endpoint == proxyPath {
      body["request_type"] = requestTypeForProxy
      body["model"] = model
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let response: GeminiResponse = try await performRequest(
      request, responseType: GeminiResponse.self, mode: "GEMINI-TITLE", withRetry: false)
    return extractText(from: response)
  }

  /// Updates a rolling meeting summary by merging new transcript content into the existing summary.
  /// Uses credential (API key or Bearer); when OAuth, sends request_type "meeting_summary" so backend uses subscription model.
  func updateRollingSummary(
    model: String,
    currentSummary: String,
    newTranscriptText: String,
    credential: GeminiCredential
  ) async throws -> String {
    let prompt: String
    if currentSummary.isEmpty {
      prompt = """
        You are summarizing a live meeting transcript. Below is a new segment of the transcript.

        STRICT FORMAT RULES:
        1. Use ## headings for sections (e.g. ## Key Points, ## Decisions).
        2. Use - for every bullet point. Each bullet on its own line.
        3. Leave a blank line before each heading and between sections.
        4. Do NOT write plain paragraphs. Every piece of information must be a bullet under a heading.
        5. Write the summary in the same language as the transcript. Output only the Markdown, no preamble.

        Transcript segment:
        \(newTranscriptText)
        """
    } else {
      prompt = """
        You are maintaining a rolling summary of a live meeting. Below are the current Markdown summary and new transcript content. \
        Update the summary to incorporate the new content.

        STRICT FORMAT RULES:
        1. Use ## headings for sections (e.g. ## Key Points, ## Decisions).
        2. Use - for every bullet point. Each bullet on its own line.
        3. Leave a blank line before each heading and between sections.
        4. Do NOT write plain paragraphs. Every piece of information must be a bullet under a heading.
        5. Preserve important points from the current summary and add or refine with the new content.
        6. Write the summary in the same language as the transcript. Output only the updated Markdown, no preamble.

        Current summary:
        \(currentSummary)

        New transcript content:
        \(newTranscriptText)
        """
    }
    return try await generateText(model: model, prompt: prompt, credential: credential, requestTypeForProxy: "meeting_summary")
  }

  /// Legacy API-key-only overload.
  func updateRollingSummary(
    model: String,
    currentSummary: String,
    newTranscriptText: String,
    apiKey: String
  ) async throws -> String {
    try await updateRollingSummary(model: model, currentSummary: currentSummary, newTranscriptText: newTranscriptText, credential: .apiKey(apiKey))
  }

  /// Generates a final Markdown summary of a full meeting transcript (main points, decisions, action items).
  /// Uses credential (API key or Bearer); when OAuth, sends request_type "meeting_summary" so backend uses subscription model.
  func generateMeetingSummary(transcript: String, model: String, credential: GeminiCredential) async throws -> String {
    let prompt = """
      You are summarizing a completed meeting transcript.

      STRICT FORMAT RULES:
      1. Use ## headings for sections (e.g. ## Main Points, ## Key Takeaways, ## Decisions, ## Action Items).
      2. Use - for every bullet point. Each bullet on its own line.
      3. Leave a blank line before each heading and between sections.
      4. Do NOT write plain paragraphs. Every piece of information must be a bullet under a heading.
      5. Include: main points, key takeaways, decisions, action items (if any).
      6. Write the summary in the same language as the transcript. Output only the Markdown, no preamble.

      Transcript:
      \(transcript)
      """
    return try await generateText(model: model, prompt: prompt, credential: credential, requestTypeForProxy: "meeting_summary")
  }

  /// Legacy API-key-only overload. Prefer generateMeetingSummary(transcript:model:credential:) for subscription support.
  func generateMeetingSummary(transcript: String, model: String, apiKey: String) async throws -> String {
    try await generateMeetingSummary(transcript: transcript, model: model, credential: .apiKey(apiKey))
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
    case .bearer:
      break
    }

    guard let initURL = components.url else {
      throw TranscriptionError.invalidRequest
    }

    var initRequest = URLRequest(url: initURL)
    initRequest.httpMethod = "POST"
    initRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if case .bearer(let token) = credential { initRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
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
  /// Marker prefix/suffix for inline images embedded in text content.
  /// Format: ⟦GEMINI_IMG:base64data:mimetype⟧
  static let imageMarkerPrefix = "⟦GEMINI_IMG:"
  static let imageMarkerSuffix = "⟧"

  func extractText(from response: GeminiResponse) -> String {
    guard let candidate = response.candidates.first,
          let content = candidate.content,
          let parts = content.parts else {
      return ""
    }

    // Extract text from parts, including code execution (executable_code, code_execution_result)
    // and inline images (inlineData) embedded as markers in the text.
    var text = ""
    var hadCodeParts = false
    var imageCount = 0
    for part in parts {
      if let partText = part.text {
        text += partText
      }
      if let code = part.executableCode?.code, !code.isEmpty {
        text += "\n\n```\n\(code)\n```"
        hadCodeParts = true
      }
      if let output = part.codeExecutionResult?.output,
         !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        text += "\n\n**Code output:**\n\(output)"
        hadCodeParts = true
      }
      if let inline = part.inlineData, inline.mimeType.hasPrefix("image/") {
        text += "\n\n\(Self.imageMarkerPrefix)\(inline.data):\(inline.mimeType)\(Self.imageMarkerSuffix)\n\n"
        imageCount += 1
      }
    }
    if hadCodeParts {
      DebugLogger.logNetwork("GEMINI-CHAT: Response contained code execution (code/result parts included in reply)")
    }
    if imageCount > 0 {
      DebugLogger.logNetwork("GEMINI-CHAT: Response contained \(imageCount) inline image(s)")
    }
    return text
  }
  
  /// Parses Gemini error responses into TranscriptionError
  func parseErrorResponse(data: Data, statusCode: Int) throws -> TranscriptionError {
    // Backend proxy 402: no active subscription for signed-in user
    if statusCode == 402 {
      #if SUBSCRIPTION_ENABLED
      return .subscriptionRequired
      #else
      return .serverError(402)
      #endif
    }
    // Backend proxy 429: { error: string, code: "rate_limit_exceeded", top_up_url: string }
    if statusCode == 429,
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let code = json["code"] as? String,
       code == "rate_limit_exceeded",
       let topUpUrlString = json["top_up_url"] as? String,
       let topUpURL = URL(string: topUpUrlString) {
      return .rateLimited(retryAfter: nil, topUpURL: topUpURL)
    }

    var retryAfter: TimeInterval? = nil

    if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
      retryAfter = errorResponse.extractRetryDelay()
      if let retryAfter = retryAfter {
        DebugLogger.log("GEMINI-ERROR: Found retryDelay: \(retryAfter)s")
      }

      let message = errorResponse.error.message
      let status = errorResponse.error.status ?? ""
      DebugLogger.log("GEMINI-ERROR: status=\(status) message=\(message)")

      // Map common Gemini errors to TranscriptionError
      let lowerMessage = message.lowercased()
      if lowerMessage.contains("api key") || lowerMessage.contains("authentication") {
        return statusCode == 401 ? .invalidAPIKey : .incorrectAPIKey
      }
      // 400 FAILED_PRECONDITION often means "enable billing" (e.g. free tier not available in region or for preview models)
      if statusCode == 400 && (status == "FAILED_PRECONDITION" || lowerMessage.contains("billing") || lowerMessage.contains("free tier") || lowerMessage.contains("payment")) {
        return .billingRequired
      }
      if lowerMessage.contains("quota") || lowerMessage.contains("exceeded") {
        return .quotaExceeded(retryAfter: retryAfter)
      }
      if lowerMessage.contains("rate limit") {
        return .rateLimited(retryAfter: retryAfter, topUpURL: nil)
      }
      if statusCode == 404 && (lowerMessage.contains("no longer available") || lowerMessage.contains("deprecated")) {
        return .modelDeprecated
      }
      if statusCode == 400 && (lowerMessage.contains("allowlist") || lowerMessage.contains("audio output") || lowerMessage.contains("voice output") || lowerMessage.contains("requires an api key")) {
        return .voiceRequiresAPIKey
      }
    } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String {
      // Fallback to manual JSON parsing
      let status = error["status"] as? String ?? ""
      DebugLogger.log("GEMINI-ERROR: status=\(status) message=\(message)")

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
      if statusCode == 400 && (status == "FAILED_PRECONDITION" || lowerMessage.contains("billing") || lowerMessage.contains("free tier") || lowerMessage.contains("payment")) {
        return .billingRequired
      }
      if lowerMessage.contains("quota") || lowerMessage.contains("exceeded") {
        return .quotaExceeded(retryAfter: retryAfter)
      }
      if lowerMessage.contains("rate limit") {
        return .rateLimited(retryAfter: retryAfter, topUpURL: nil)
      }
      if statusCode == 404 && (lowerMessage.contains("no longer available") || lowerMessage.contains("deprecated")) {
        return .modelDeprecated
      }
      if statusCode == 400 && (lowerMessage.contains("allowlist") || lowerMessage.contains("audio output") || lowerMessage.contains("voice output") || lowerMessage.contains("requires an api key")) {
        return .voiceRequiresAPIKey
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
    #if SUBSCRIPTION_ENABLED
    case 402: return .subscriptionRequired
    #else
    case 402: return .serverError(402)
    #endif
    case 403: return .permissionDenied
    case 404: return .notFound
    case 429: return .rateLimited(retryAfter: retryAfter, topUpURL: nil)
    case 500: return .serverError(statusCode)
    case 503: return .serviceUnavailable
    default: return .serverError(statusCode)
    }
  }
}





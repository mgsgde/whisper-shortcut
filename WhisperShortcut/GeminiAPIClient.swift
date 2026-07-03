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
    static let resourceTimeout: TimeInterval = 300.0
    static let maxRetryAttempts = 5  // Handle rate limiting and transient 503s
    static let maxServerErrorRetryAttempts = 6  // Extra attempts for 503/500 server errors
    static let retryDelaySeconds: TimeInterval = 1.5
    static let filesAPIBaseURL = "https://generativelanguage.googleapis.com/upload/v1beta/files"
  }
  
  // MARK: - Properties
  private let session: URLSession
  
  // MARK: - Initialization
  /// Defaults to `LLMHTTPSession.shared` (same 60s/300s timeouts) so the many GeminiAPIClient
  /// instances across the app share one connection pool instead of each spawning their own.
  init(session: URLSession? = nil) {
    self.session = session ?? LLMHTTPSession.shared
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

  // MARK: - Request Execution
  /// Generic helper to perform Gemini API requests with error handling and retry logic
  func performRequest<T: Decodable>(
    _ request: URLRequest,
    responseType: T.Type,
    mode: String = "GEMINI",
    withRetry: Bool = false
  ) async throws -> T {
    var lastError: Error?
    var maxAttempts = withRetry ? Constants.maxRetryAttempts : 1

    // While-loop (not `for attempt in 1...maxAttempts`): the range form snapshots the bound at
    // entry, so the server-error bump of `maxAttempts` below would never actually add attempts.
    var attempt = 0
    while attempt < maxAttempts {
      attempt += 1
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

        // TTS responses: reject empty bodies and log a compact shape summary before decoding.
        if mode == "TTS" {
          guard data.count > 0 else {
            DebugLogger.logError("TTS: Response data is empty")
            throw TranscriptionError.networkError("Empty response from TTS API")
          }
          if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
             let candidates = json["candidates"] as? [[String: Any]],
             let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] {
            let inline = parts.first?["inlineData"] as? [String: Any]
            let base64Len = (inline?["data"] as? String)?.count ?? 0
            DebugLogger.log("TTS: response candidates=\(candidates.count) parts=\(parts.count) inlineData=\(inline != nil ? "yes (\(base64Len) chars)" : "MISSING")")
          } else {
            DebugLogger.logError("TTS: response JSON missing candidates/content/parts — body: \(String(data: data.prefix(300), encoding: .utf8) ?? "<binary>")")
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
        // User-initiated cancellations (pressing the shortcut again, starting a new
        // request) surface as URLError.cancelled. They are normal control flow, not
        // failures, so handle them first and log at debug — this keeps the on-disk
        // errors log free of benign -999 entries that would otherwise mask real errors.
        if error.code == .cancelled {
          DebugLogger.log("\(mode)-RETRY: Request cancelled by user")
          throw CancellationError()
        }
        // Log detailed network error information. Redact the API key from the failing
        // URL so it never reaches the on-disk error log or the unified log.
        DebugLogger.logError("\(mode)-NETWORK-ERROR: URLError code: \(error.code.rawValue), description: \(error.localizedDescription)")
        if let failingURL = error.userInfo["NSErrorFailingURLStringKey"] as? String {
          DebugLogger.logError("\(mode)-NETWORK-ERROR: Failing URL: \(Self.redactingAPIKey(failingURL))")
        }
        if let underlyingError = error.userInfo["NSUnderlyingErrorKey"] as? Error {
          DebugLogger.logError("\(mode)-NETWORK-ERROR: Underlying error: \(underlyingError.localizedDescription)")
        }

        if error.code == .timedOut {
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

          // A rate/quota error with no API-provided retry delay is a permanent
          // block (e.g. a monthly spending-cap 429, RESOURCE_EXHAUSTED). It will
          // not clear on its own, so retrying just delays the error and burns
          // more requests against an already-capped project — fail fast instead.
          if let te = error as? TranscriptionError {
            switch te {
            case .rateLimited(nil, _), .quotaExceeded(nil):
              DebugLogger.log("\(mode)-RETRY: Permanent rate/quota limit (no retryDelay) – not retrying")
              throw error
            default:
              break
            }
          }
        }

        // For server errors (503/500), allow more retry attempts with longer backoff
        if let te = error as? TranscriptionError, te.isServerOrUnavailable, withRetry {
          maxAttempts = max(maxAttempts, Constants.maxServerErrorRetryAttempts)
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
  enum GeminiStreamEvent {
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
    functionDeclarations: [[String: Any]] = [],
    thinkingLevel: ThinkingLevel = .default,
    disableBuiltInTools: Bool = false
  ) -> AsyncThrowingStream<GeminiStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        // Retry transient pre-stream failures (HTTP 503/500/429) with exponential
        // backoff. We only retry while no event has been yielded yet: the 503 is
        // raised at the HTTP status check before any content is streamed, so a retry
        // is safe there. Once we begin consuming the response body we set
        // `hasYielded` and never retry, since that would duplicate streamed output.
        var attempt = 0
        var hasYielded = false
        while true {
        attempt += 1
        do {
          let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse"
          var request = try self.createRequest(endpoint: endpoint, credential: credential)
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
          // so we only include it when no custom tools are provided. Pure text
          // transforms (Read Aloud rewrite, Smart Improvement) pass
          // `disableBuiltInTools` so the model never runs code and pollutes the
          // reply with executable_code / code_execution_result parts.
          if functionDeclarations.isEmpty {
            if !disableBuiltInTools {
              tools.append(["code_execution": [:]])
            }
          } else {
            tools.append(["function_declarations": functionDeclarations])
            // Gemini 3 Flash rejects built-in tools (google_search/url_context)
            // combined with function_declarations unless this flag is set.
            body["tool_config"] = [
              "include_server_side_tool_invocations": true
            ]
          }
          if !tools.isEmpty {
            body["tools"] = tools
          }
          if let sys = systemInstruction {
            body["system_instruction"] = sys
          }
          // Per-model thinking config. Gemini 3.x uses `thinkingLevel` (Pro→high, Flash→minimal);
          // 2.5 uses `thinkingBudget` (Pro→-1 dynamic, Flash→0 off). Sending `thinkingBudget` to a
          // 3.x model is the wrong knob and can make it leak raw `start_thought` tokens into the
          // reply — see `PromptModel.geminiThinkingConfig`. Unknown models get no thinkingConfig
          // (the model's own default applies).
          let promptModel = PromptModel(rawValue: model)
          if promptModel == nil {
            DebugLogger.logError("GEMINI-CHAT-STREAM: unknown model rawValue \(model), omitting thinkingConfig")
          }
          var generationConfig: [String: Any] = [
            "temperature": 0.7,
            "topP": 0.95,
            "maxOutputTokens": 8192
          ]
          // Start from the model's built-in config, then apply a per-session `/think` override.
          // We reuse the default config's shape to know which knob this model uses: a 3.x model
          // carries `thinkingLevel` (override the level directly); a 2.5 model carries
          // `thinkingBudget` (no granular levels, so map minimal→0 off, anything higher→-1 dynamic).
          var thinkingConfig = promptModel?.geminiThinkingConfig
          if thinkingLevel != .default, var cfg = thinkingConfig {
            if cfg["thinkingLevel"] != nil, let level = thinkingLevel.geminiThinkingLevel {
              cfg["thinkingLevel"] = level
            } else if cfg["thinkingBudget"] != nil {
              cfg["thinkingBudget"] = (thinkingLevel == .minimal) ? 0 : -1
            }
            thinkingConfig = cfg
          }
          if let thinkingConfig {
            generationConfig["thinkingConfig"] = thinkingConfig
          }
          body["generationConfig"] = generationConfig
          body["safetySettings"] = [
            ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_ONLY_HIGH"],
            ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_ONLY_HIGH"],
            ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_ONLY_HIGH"],
            ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_ONLY_HIGH"]
          ]
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
            // Map the body to a specific TranscriptionError (e.g. an expired/invalid key
            // becomes .invalidAPIKey/.incorrectAPIKey) so the user sees an actionable
            // message instead of a raw "HTTP 400: {…}" network error. Fall back to the
            // generic network error only if mapping fails.
            let mapped = (try? self.parseErrorResponse(data: errData, statusCode: http.statusCode))
            throw mapped ?? TranscriptionError.networkError("HTTP \(http.statusCode): \(text)")
          }

          var aggregatedSources: [GroundingSource] = []
          var aggregatedSupports: [GroundingSupport] = []
          var finishReason: String?
          // Accumulate function call parts across streaming chunks. A functionCall
          // and its thoughtSignature do NOT necessarily arrive together: per the
          // Gemini thinking docs the signature streams as its own delta ("the last
          // delta before step.stop"), so the chunk carrying it may not repeat the
          // functionCall part. Echoing a function call back without its signature
          // makes Gemini 3 reject the next request with HTTP 400, so we keep the
          // latest snapshot, preserve any signature already seen, and also pick up
          // a signature that lands on a later signature-only delta.
          var latestFunctionCallParts: [[String: Any]] = []
          func signatureOf(_ part: [String: Any]) -> String? {
            part["thoughtSignature"] as? String ?? part["thought_signature"] as? String
          }

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
            // Snapshot the function call parts from each chunk, then attach
            // signatures that stream separately.
            if !functionDeclarations.isEmpty,
               let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let candidates = obj["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
              let fcParts = parts.filter { $0["functionCall"] != nil || $0["function_call"] != nil }
              if !fcParts.isEmpty {
                // Refresh the snapshot but don't drop a signature we already captured
                // for the call at this position (a later snapshot can omit it).
                latestFunctionCallParts = fcParts.enumerated().map { index, part in
                  var part = part
                  if signatureOf(part) == nil, index < latestFunctionCallParts.count,
                     let prev = signatureOf(latestFunctionCallParts[index]) {
                    part["thoughtSignature"] = prev
                  }
                  return part
                }
              }
              // A signature-only delta (no functionCall part) belongs to the most
              // recent function call still missing one — attach it there.
              for part in parts where part["functionCall"] == nil && part["function_call"] == nil {
                guard let sig = signatureOf(part) else { continue }
                if let index = latestFunctionCallParts.lastIndex(where: { signatureOf($0) == nil }) {
                  latestFunctionCallParts[index]["thoughtSignature"] = sig
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
          // Past this point we may emit deltas to the UI, so disable retries.
          hasYielded = true
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

          // Yield accumulated function calls now that the stream is complete
          // and all thoughtSignatures have been received.
          for part in latestFunctionCallParts {
            if let fc = part["functionCall"] as? [String: Any] ?? part["function_call"] as? [String: Any],
               let name = fc["name"] as? String {
              let args = (fc["args"] as? [String: Any]) ?? [:]
              let thoughtSignature = part["thoughtSignature"] as? String
                ?? part["thought_signature"] as? String
              DebugLogger.logNetwork("GEMINI-CHAT-STREAM: functionCall name=\(name) sig=\(thoughtSignature != nil ? "yes" : "no")")
              continuation.yield(.functionCall(name: name, args: args, thoughtSignature: thoughtSignature))
            }
          }

          if let reason = finishReason, reason != "STOP" {
            DebugLogger.logWarning("GEMINI-CHAT-STREAM: finishReason=\(reason)")
          }
          DebugLogger.logNetwork("GEMINI-CHAT-STREAM: grounding sources=\(aggregatedSources.count) supports=\(aggregatedSupports.count)")
          continuation.yield(.finished(sources: aggregatedSources, supports: aggregatedSupports, finishReason: finishReason))
          continuation.finish()
          return
        } catch {
          if Task.isCancelled {
            continuation.finish(throwing: error)
            return
          }
          // Retry only transient, pre-stream failures (server/unavailable or rate limit).
          let te = error as? TranscriptionError
          let isTransient: Bool = {
            guard let te else { return false }
            if te.isServerOrUnavailable { return true }
            switch te {
            case .rateLimited(let retryAfter, _), .quotaExceeded(let retryAfter):
              // Only retry when the API told us the limit is temporary (it
              // included a retryDelay). A permanent block — e.g. a monthly
              // spending-cap 429 (RESOURCE_EXHAUSTED with no retryDelay) — will
              // not clear until the user raises the cap, so retrying just burns
              // ~9s of doomed requests before the error surfaces. Fail fast.
              return retryAfter != nil
            case .slowDown:
              return true
            default:
              return false
            }
          }()
          if !hasYielded, isTransient, attempt < Constants.maxServerErrorRetryAttempts {
            // Honor an API-provided retry delay; otherwise exponential backoff for
            // server errors, and a short fixed delay for everything else.
            let delay: TimeInterval
            if let retryAfter = te?.retryAfter {
              delay = retryAfter + 2.0
            } else if te?.isServerOrUnavailable ?? false {
              delay = 2.0 * pow(2.0, Double(attempt - 1))
            } else {
              delay = Constants.retryDelaySeconds
            }
            DebugLogger.log("GEMINI-CHAT-STREAM-RETRY: Attempt \(attempt) failed, retrying in \(String(format: "%.1f", delay))s: \(error.localizedDescription)")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            continue
          }
          continuation.finish(throwing: error)
          return
        }
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

  func generateText(model: String, prompt: String, credential: GeminiCredential) async throws -> String {
    let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
    var request = try createRequest(endpoint: endpoint, credential: credential)
    let body: [String: Any] = [
      "contents": [["role": "user", "parts": [["text": prompt]]]]
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let response: GeminiResponse = try await performRequest(
      request, responseType: GeminiResponse.self, mode: "GEMINI-TITLE", withRetry: false)
    return extractText(from: response)
  }

  /// Non-streaming structured generation: constrains the model to `schema` via
  /// `generationConfig.responseSchema` + `responseMimeType:"application/json"` and returns the
  /// parsed top-level JSON object. `schema` is the canonical JSON Schema (Gemini accepts the
  /// OpenAPI-3.0 subset directly; it must NOT contain `additionalProperties`). Used by
  /// `GeminiChatProvider.generateStructured` and the chat/meeting title path.
  func generateStructured(
    model: String,
    contents: [[String: Any]],
    systemInstruction: [String: Any]?,
    schema: [String: Any],
    credential: GeminiCredential
  ) async throws -> [String: Any] {
    let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
    var request = try createRequest(endpoint: endpoint, credential: credential)
    var body: [String: Any] = [
      "contents": contents,
      "generationConfig": [
        "responseMimeType": "application/json",
        "responseSchema": schema,
      ] as [String: Any],
    ]
    if let systemInstruction = systemInstruction {
      body["system_instruction"] = systemInstruction
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let response: GeminiResponse = try await performRequest(
      request, responseType: GeminiResponse.self, mode: "GEMINI-STRUCTURED", withRetry: false)
    let text = extractText(from: response)
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TranscriptionError.networkError("Gemini structured response was not valid JSON: \(text.prefix(200))")
    }
    return obj
  }

  /// Native image generation/editing ("Nano Banana") via a single non-streaming `:generateContent`
  /// call. Setting `responseModalities: ["TEXT","IMAGE"]` makes the model return image parts, which
  /// `extractText(from:)` embeds as `⟦GEMINI_IMG:…⟧` markers in the returned string — the chat view
  /// then renders them inline (`ChatView.extractInlineImageData`). These models don't support tools,
  /// grounding, thinking, or SSE streaming, so none of those are sent. Any input image to edit rides
  /// along inside `contents` as an `inline_data` part (built by `ChatView.buildContents`).
  func generateImageContent(
    model: String,
    contents: [[String: Any]],
    credential: GeminiCredential
  ) async throws -> String {
    let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
    var request = try createRequest(endpoint: endpoint, credential: credential)
    request.timeoutInterval = Constants.resourceTimeout
    let body: [String: Any] = [
      "contents": contents,
      // No maxOutputTokens: image tokens are large and an 8k cap would truncate the picture.
      "generationConfig": ["responseModalities": ["TEXT", "IMAGE"]] as [String: Any],
      "safetySettings": [
        ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_ONLY_HIGH"],
        ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_ONLY_HIGH"],
        ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_ONLY_HIGH"],
        ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_ONLY_HIGH"],
      ],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    DebugLogger.logNetwork("GEMINI-IMAGE: POST \(Self.redactingAPIKey(endpoint)) model=\(model) (responseModalities=TEXT,IMAGE)")
    let response: GeminiResponse = try await performRequest(
      request, responseType: GeminiResponse.self, mode: "GEMINI-IMAGE", withRetry: false)
    let text = extractText(from: response)
    if !text.contains(Self.imageMarkerPrefix) {
      // The model returned only text (e.g. a refusal or a "describe what you want" reply). Surface
      // the text as-is; the caller shows it like any other assistant message.
      DebugLogger.logNetwork("GEMINI-IMAGE: response contained no image part (text-only reply)")
    }
    return text
  }

  // Meeting summary, rolling summary, and speaker consolidation now route through
  // `MeetingListService` + `LLMProviderFactory` (provider-agnostic), so a selected Grok/OpenAI model
  // is no longer forced onto the Gemini endpoint. See `MeetingListService.generateSummaryText` etc.

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
  /// Short stand-in when ⟦GEMINI_IMG:…⟧ markers are stripped (clipboard, API history, logs).
  static let generatedImagePlaceholder = "[generated image]"

  static func isGeneratedImagePlaceholder(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines) == generatedImagePlaceholder
  }

  static func containsImageMarker(in content: String) -> Bool {
    content.contains(imageMarkerPrefix)
  }

  static func walkImageMarkers(
    _ content: String,
    onText: (Substring) -> Void,
    onMarker: (Substring) -> Void,
    onUnterminatedMarker: (Substring) -> Void
  ) {
    var rest = Substring(content)
    while let start = rest.range(of: imageMarkerPrefix) {
      onText(rest[rest.startIndex..<start.lowerBound])
      guard let end = rest.range(of: imageMarkerSuffix, range: start.upperBound..<rest.endIndex) else {
        onUnterminatedMarker(rest[start.lowerBound...])
        return
      }
      onMarker(rest[start.lowerBound..<end.upperBound])
      rest = rest[end.upperBound...]
    }
    onText(rest)
  }

  /// Replaces inline image markers with a short placeholder so marker base64 never enters
  /// clipboard/search/TTS pipelines.
  static func stripImageMarkers(_ content: String, placeholder: String = generatedImagePlaceholder) -> String {
    guard containsImageMarker(in: content) else { return content }
    var result = ""
    walkImageMarkers(
      content,
      onText: { result += $0 },
      onMarker: { _ in result += placeholder },
      onUnterminatedMarker: { result += $0 }
    )
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Decodes the base64 payload from a single `⟦GEMINI_IMG:...⟧` marker.
  static func decodeImageMarkerData(_ marker: String) -> Data? {
    decodeImageMarker(marker)?.data
  }

  /// Decodes both the base64 payload and the mime type from a single `⟦GEMINI_IMG:...⟧` marker.
  static func decodeImageMarker(_ marker: String) -> (data: Data, mimeType: String)? {
    guard marker.hasPrefix(imageMarkerPrefix), marker.hasSuffix(imageMarkerSuffix) else { return nil }
    let inner = String(marker.dropFirst(imageMarkerPrefix.count).dropLast(imageMarkerSuffix.count))
    guard let lastColon = inner.lastIndex(of: ":") else { return nil }
    let base64 = String(inner[inner.startIndex..<lastColon])
    let mimeType = String(inner[inner.index(after: lastColon)...])
    guard !base64.isEmpty, let data = Data(base64Encoded: base64) else { return nil }
    return (data, mimeType)
  }

  /// Returns the first inline image (data + mime type) embedded in `content`, if any.
  static func firstImageMarker(in content: String) -> (data: Data, mimeType: String)? {
    guard containsImageMarker(in: content) else { return nil }
    var result: (data: Data, mimeType: String)?
    walkImageMarkers(
      content,
      onText: { _ in },
      onMarker: { marker in
        if result == nil { result = decodeImageMarker(String(marker)) }
      },
      onUnterminatedMarker: { _ in }
    )
    return result
  }

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
      // Skip the model's internal reasoning — thought parts are never shown to the user.
      if part.thought == true { continue }
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
  
  /// Replaces the value of any `key` query parameter with `REDACTED` so API keys
  /// never reach the logs. Returns the input unchanged if it isn't a parseable URL.
  static func redactingAPIKey(_ urlString: String) -> String {
    guard var comps = URLComponents(string: urlString), let items = comps.queryItems else {
      return urlString
    }
    comps.queryItems = items.map { item in
      item.name.lowercased() == "key" ? URLQueryItem(name: item.name, value: "REDACTED") : item
    }
    return comps.url?.absoluteString ?? urlString
  }

  /// Parses Gemini error responses into TranscriptionError
  func parseErrorResponse(data: Data, statusCode: Int) throws -> TranscriptionError {
    if statusCode == 402 {
      return .serverError(402)
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

    // Extract message/status via the typed model, falling back to manual JSON parsing;
    // the mapping below is shared by both paths.
    var message: String?
    var status = ""
    if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
      message = errorResponse.error.message
      status = errorResponse.error.status ?? ""
    } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let msg = error["message"] as? String {
      message = msg
      status = error["status"] as? String ?? ""
    }

    var retryAfter: TimeInterval? = nil
    if let message {
      DebugLogger.log("GEMINI-ERROR: status=\(status) message=\(message)")
      retryAfter = GeminiErrorResponse.parseRetryDelayFromMessage(message)
      if let retryAfter {
        DebugLogger.log("GEMINI-ERROR: Found retryDelay: \(retryAfter)s")
      }

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
    }

    // Fall back to status code parsing
    return parseStatusCodeError(statusCode, retryAfter: retryAfter)
  }

  /// Maps HTTP status codes to TranscriptionError
  private func parseStatusCodeError(_ statusCode: Int, retryAfter: TimeInterval? = nil) -> TranscriptionError {
    switch statusCode {
    case 400: return .invalidRequest
    case 401: return .invalidAPIKey
    case 402: return .serverError(402)
    case 403: return .permissionDenied
    case 404: return .notFound
    case 429: return .rateLimited(retryAfter: retryAfter, topUpURL: nil)
    case 500: return .serverError(statusCode)
    case 503: return .serviceUnavailable
    default: return .serverError(statusCode)
    }
  }
}





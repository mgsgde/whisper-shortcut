import AVFoundation
import Foundation
import NaturalLanguage

// MARK: - Constants
private enum Constants {
  static let maxFileSize = 20 * 1024 * 1024  // 20MB - optimal für Gemini's file size limits
  static let requestTimeout: TimeInterval = 60.0
  static let resourceTimeout: TimeInterval = 300.0

  // Text validation
  static let minimumTextLength = 1  // Allow single character responses like "Yes", "OK", etc.

  // Audio validation
  static let supportedAudioExtensions = ["wav", "mp3", "m4a", "flac", "ogg", "webm"]

  // Timing delays
  static let clipboardCopyDelay: UInt64 = 100_000_000  // 0.1 seconds in nanoseconds
  
  // Retry configuration
  static let maxRetryAttempts = 2  // Maximum retry attempts per chunk (optimal balance)
  static let retryDelaySeconds: TimeInterval = 1.5  // Shorter delay for better UX
}

// MARK: - Core Service
class SpeechService {

  // MARK: - Shared Infrastructure
  private let keychainManager: KeychainManaging
  private var clipboardManager: ClipboardManager?

  // Custom session with appropriate timeouts
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = Constants.requestTimeout
    config.timeoutIntervalForResource = Constants.resourceTimeout
    return URLSession(configuration: config)
  }()

  // MARK: - Transcription Mode Properties
  private var selectedTranscriptionModel: TranscriptionModel = SettingsDefaults.selectedTranscriptionModel


  // MARK: - Task Tracking for Cancellation
  private var currentTranscriptionTask: Task<String, Error>?
  private var currentPromptTask: Task<String, Error>?

  init(
    keychainManager: KeychainManaging = KeychainManager.shared,
    clipboardManager: ClipboardManager? = nil
  ) {
    self.keychainManager = keychainManager
    self.clipboardManager = clipboardManager
  }

  // MARK: - Shared API Key Management
  private var googleAPIKey: String? {
    keychainManager.getGoogleAPIKey()
  }

  // MARK: - Transcription Mode Configuration
  func setModel(_ model: TranscriptionModel) {
    self.selectedTranscriptionModel = model
  }

  func getCurrentModel() -> TranscriptionModel {
    return selectedTranscriptionModel
  }
  
  // MARK: - Model Information for Notifications
  func getTranscriptionModelInfo() -> String {
    return selectedTranscriptionModel.displayName
  }
  
  func getPromptModelInfo() -> String {
    let modelKey = "selectedPromptModel"
    let selectedPromptModelString = UserDefaults.standard.string(forKey: modelKey) ?? "gemini-2.0-flash"
    let selectedPromptModel = PromptModel(rawValue: selectedPromptModelString) ?? .gemini20Flash
    return selectedPromptModel.displayName
  }

  // MARK: - Prompt Building
  /// Builds the combined dictation prompt from normal prompt and difficult words
  /// - Returns: Combined prompt string with difficult words appended if present
  private func buildDictationPrompt() -> String {
    // Get normal prompt
    let customPrompt = UserDefaults.standard.string(forKey: "customPromptText")
      ?? AppConstants.defaultTranscriptionSystemPrompt
    let normalPrompt = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Get difficult words
    let difficultWordsText = UserDefaults.standard.string(forKey: "dictationDifficultWords") ?? ""
    let difficultWords = difficultWordsText
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    
    // If no difficult words, return normal prompt
    guard !difficultWords.isEmpty else {
      return normalPrompt
    }
    
    // Combine words into comma-separated list
    let wordsList = difficultWords.joined(separator: ", ")
    
    // Combine prompts with Gemini-optimized formulation
    // This formulation clearly indicates difficult words are reference only
    // and should only be used if actually heard in the audio
    if normalPrompt.isEmpty {
      return "Spelling reference (use only if heard in audio): \(wordsList). CRITICAL: Transcribe ONLY what is spoken. Do NOT add words from this list if not heard. Do NOT include this instruction in your output."
    } else {
      return "\(normalPrompt)\n\nSpelling reference (use only if heard in audio): \(wordsList). CRITICAL: Transcribe ONLY what is spoken. Do NOT add words from this list if not heard. Do NOT include this instruction in your output."
    }
  }


  // MARK: - Cancellation Methods
  func cancelTranscription() {
    DebugLogger.log("CANCELLATION: Cancelling transcription task")
    currentTranscriptionTask?.cancel()
    currentTranscriptionTask = nil
  }

  func cancelPrompt() {
    DebugLogger.log("CANCELLATION: Cancelling prompt task")
    currentPromptTask?.cancel()
    currentPromptTask = nil
  }

  // MARK: - Transcription Mode (Public API with Task Tracking)
  func transcribe(audioURL: URL) async throws -> String {
    // Create and store task for cancellation support
    let task = Task<String, Error> {
      try await self.performTranscription(audioURL: audioURL)
    }
    
    currentTranscriptionTask = task
    defer { currentTranscriptionTask = nil }
    
    return try await task.value
  }

  // MARK: - Transcription Mode (Private Implementation)
  private func performTranscription(audioURL: URL) async throws -> String {
    // Check if using Gemini model
    // Only Gemini models are supported now
    if selectedTranscriptionModel.isGemini {
      // For Gemini, validate format but not size (Gemini supports up to 9.5 hours)
      try validateAudioFileFormat(at: audioURL)
      return try await transcribeWithGemini(audioURL: audioURL)
    }
    
    // Should never reach here since we only support Gemini models
    throw TranscriptionError.networkError("Unsupported transcription model")
  }
  

  // MARK: - Prompt Modes (Public API with Task Tracking)
  func executePrompt(audioURL: URL) async throws -> String {
    // Create and store task for cancellation support
    let task = Task<String, Error> {
      try await self.performPrompt(audioURL: audioURL)
    }
    
    currentPromptTask = task
    defer { currentPromptTask = nil }
    
    return try await task.value
  }

  // MARK: - Prompt Modes (Private Implementation)
  private func performPrompt(audioURL: URL) async throws -> String {
    // Get clipboard context
    let clipboardContext = getClipboardContext()
    
    // Get selected model from settings
    let modelString = UserDefaults.standard.string(forKey: "selectedPromptModel") ?? "gemini-2.0-flash"
    let selectedPromptModel = PromptModel(rawValue: modelString) ?? .gemini20Flash
    
    // Check if using Gemini model
    if selectedPromptModel.isGemini {
      // For Gemini, validate format but not size (Gemini supports up to 9.5 hours)
      try validateAudioFileFormat(at: audioURL)
      // Execute prompt with Gemini (it handles its own key validation)
      return try await executePromptWithGemini(audioURL: audioURL, clipboardContext: clipboardContext)
    }

    // Should never reach here since we only support Gemini models now
    throw TranscriptionError.networkError("Unsupported model type")
  }

  // MARK: - Gemini Prompt Mode
  private func executePromptWithGemini(audioURL: URL, clipboardContext: String?) async throws -> String {
    guard let googleAPIKey = self.googleAPIKey, !googleAPIKey.isEmpty else {
      throw TranscriptionError.noGoogleAPIKey
    }
    
    DebugLogger.log("PROMPT-MODE-GEMINI: Starting execution")
    
    // Get selected model from settings
    let modelString = UserDefaults.standard.string(forKey: "selectedPromptModel") ?? "gemini-2.0-flash"
    let selectedPromptModel = PromptModel(rawValue: modelString) ?? .gemini20Flash
    
    // Convert to TranscriptionModel to get API endpoint
    guard let transcriptionModel = selectedPromptModel.asTranscriptionModel else {
      throw TranscriptionError.networkError("Selected model is not a Gemini model")
    }
    
    let endpoint = transcriptionModel.apiEndpoint
    DebugLogger.log("PROMPT-MODE-GEMINI: Using model: \(selectedPromptModel.displayName) (\(selectedPromptModel.rawValue))")
    DebugLogger.log("PROMPT-MODE-GEMINI: Using endpoint: \(endpoint)")
    
    // Get clipboard context
    let hasContext = clipboardContext != nil
    DebugLogger.log("PROMPT-MODE-GEMINI: Clipboard context: \(hasContext ? "present" : "none")")
    
    // Build system prompt
    let baseSystemPrompt = AppConstants.defaultPromptModeSystemPrompt
    let customSystemPromptKey = "promptModeSystemPrompt"
    let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptKey)
    
    let systemPrompt: String
    if let customPrompt = customSystemPrompt, !customPrompt.isEmpty {
      systemPrompt = customPrompt
      DebugLogger.log("PROMPT-MODE-GEMINI: Using custom system prompt")
    } else {
      systemPrompt = baseSystemPrompt
      DebugLogger.log("PROMPT-MODE-GEMINI: Using base system prompt")
    }
    
    // Build request
    let url = URL(string: "\(endpoint)?key=\(googleAPIKey)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    // Build contents array with current message only
    var contents: [GeminiChatRequest.GeminiChatContent] = []
    
    // Build current user message parts
    var userParts: [GeminiChatRequest.GeminiChatPart] = []
    
    // Add audio input first
    let audioSize: Int64 = {
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        return attributes[.size] as? Int64 ?? 0
      } catch {
        return 0
      }
    }()
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = getGeminiMimeType(for: fileExtension)
    
    if audioSize > Constants.maxFileSize {
      // Use Files API for large files
      let fileURI = try await uploadFileToGemini(audioURL: audioURL, apiKey: googleAPIKey)
      userParts.append(GeminiChatRequest.GeminiChatPart(
        text: nil,
        inlineData: nil,
        fileData: GeminiChatRequest.GeminiFileData(fileUri: fileURI, mimeType: mimeType),
        url: nil
      ))
    } else {
      // Use inline data for small files
      let audioData = try Data(contentsOf: audioURL)
      let base64Audio = audioData.base64EncodedString()
      userParts.append(GeminiChatRequest.GeminiChatPart(
        text: nil,
        inlineData: GeminiChatRequest.GeminiInlineData(mimeType: mimeType, data: base64Audio),
        fileData: nil,
        url: nil
      ))
    }
    
    // Add clipboard context AFTER audio (so Gemini processes audio with context in mind)
    if let context = clipboardContext {
      let contextText = """
      IMPORTANT: Apply the voice instruction you just heard to the following text:
      
      \(context)
      
      Process the text above according to the voice instruction.
      """
      userParts.append(GeminiChatRequest.GeminiChatPart(text: contextText, inlineData: nil, fileData: nil, url: nil))
    }
    
    // Add current user message
    contents.append(GeminiChatRequest.GeminiChatContent(role: "user", parts: userParts))
    
    // Build system instruction
    let systemInstruction = GeminiChatRequest.GeminiSystemInstruction(
      parts: [GeminiChatRequest.GeminiSystemPart(text: systemPrompt)]
    )
    
    // Create request (no tools for prompt mode, no audio output needed)
    let chatRequest = GeminiChatRequest(
      contents: contents,
      systemInstruction: systemInstruction,
      tools: nil,
      generationConfig: nil
    )
    
    request.httpBody = try JSONEncoder().encode(chatRequest)
    
    let (data, responseData) = try await session.data(for: request)
    
    guard let httpResponse = responseData as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }
    
    if httpResponse.statusCode != 200 {
      DebugLogger.log("PROMPT-MODE-GEMINI-ERROR: HTTP \(httpResponse.statusCode)")
      let error = try parseGeminiErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }
    
    let result = try JSONDecoder().decode(GeminiChatResponse.self, from: data)
    
    guard let firstCandidate = result.candidates.first else {
      throw TranscriptionError.networkError("No candidates in Gemini response")
    }
    
    // Extract text content
    var textContent = ""
    for part in firstCandidate.content.parts {
      if let text = part.text {
        textContent += text
      }
    }
    
    let normalizedText = normalizeTranscriptionText(textContent)
    try validateSpeechText(normalizedText, mode: "PROMPT-MODE-GEMINI")
    
    DebugLogger.logSuccess("PROMPT-MODE-GEMINI: Completed successfully")
    
    return normalizedText
  }

  // MARK: - Gemini Transcription
  private func transcribeWithGemini(audioURL: URL) async throws -> String {
    guard let apiKey = self.googleAPIKey, !apiKey.isEmpty else {
      DebugLogger.log("GEMINI-TRANSCRIPTION: ERROR - No Google API key found in keychain")
      throw TranscriptionError.noGoogleAPIKey
    }
    
    // Log API key status (without exposing the key itself)
    let keyPrefix = String(apiKey.prefix(8))
    let keyLength = apiKey.count
    DebugLogger.log("GEMINI-TRANSCRIPTION: Google API key found (prefix: \(keyPrefix)..., length: \(keyLength) chars)")
    
    try validateAudioFile(at: audioURL)
    
    let audioSize: Int64 = {
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        return attributes[.size] as? Int64 ?? 0
      } catch {
        return 0
      }
    }()
    DebugLogger.log("GEMINI-TRANSCRIPTION: Starting transcription, file size: \(audioSize) bytes")
    
    let result: String
    // For files >20MB, use Files API (resumable upload)
    // For files ≤20MB, use inline base64
    if audioSize > Constants.maxFileSize {
      result = try await transcribeWithGeminiFilesAPI(audioURL: audioURL, apiKey: apiKey)
    } else {
      result = try await transcribeWithGeminiInline(audioURL: audioURL, apiKey: apiKey)
    }
    
    return result
  }
  
  private func transcribeWithGeminiInline(audioURL: URL, apiKey: String) async throws -> String {
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using inline audio (file ≤20MB)")
    
    // Read audio file and convert to base64
    let audioData = try Data(contentsOf: audioURL)
    let base64Audio = audioData.base64EncodedString()
    
    // Determine MIME type from file extension
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = getGeminiMimeType(for: fileExtension)
    
    // Get combined prompt (normal prompt + difficult words)
    let promptToUse = buildDictationPrompt()
    
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using prompt: \(promptToUse.prefix(100))...")
    
    // Create request with dynamic endpoint based on selected model
    let endpoint = selectedTranscriptionModel.apiEndpoint
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using model: \(selectedTranscriptionModel.displayName) (\(selectedTranscriptionModel.rawValue))")
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using endpoint: \(endpoint)")
    let url = URL(string: "\(endpoint)?key=\(apiKey)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    // Build request body
    let requestBody: [String: Any] = [
      "contents": [
        [
          "parts": [
            [
              "text": promptToUse.isEmpty ? "Transcribe this audio. Return only the transcribed text without any additional commentary or formatting." : promptToUse
            ],
            [
              "inline_data": [
                "mime_type": mimeType,
                "data": base64Audio
              ]
            ]
          ]
        ]
      ]
    ]
    
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
    
    // Make request with retry logic
    var lastError: Error?
    for attempt in 1...Constants.maxRetryAttempts {
      do {
        if attempt > 1 {
          DebugLogger.log("GEMINI-TRANSCRIPTION-RETRY: Attempt \(attempt)/\(Constants.maxRetryAttempts)")
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
          throw TranscriptionError.networkError("Invalid response")
        }
        
        if httpResponse.statusCode != 200 {
          // Log detailed error information
          let errorBody = String(data: data, encoding: .utf8) ?? "Unable to decode error response"
          DebugLogger.log("GEMINI-TRANSCRIPTION-ERROR: HTTP \(httpResponse.statusCode)")
          DebugLogger.log("GEMINI-TRANSCRIPTION-ERROR: Response body: \(errorBody.prefix(500))")
          
          // Check for rate limiting or quota issues
          if httpResponse.statusCode == 429 {
            DebugLogger.log("GEMINI-TRANSCRIPTION-ERROR: Rate limit exceeded - API may be throttling requests")
          } else if httpResponse.statusCode == 403 {
            DebugLogger.log("GEMINI-TRANSCRIPTION-ERROR: Forbidden - Check API key permissions and quota")
          } else if httpResponse.statusCode == 401 {
            DebugLogger.log("GEMINI-TRANSCRIPTION-ERROR: Unauthorized - Invalid API key")
          }
          
          let error = try parseGeminiErrorResponse(data: data, statusCode: httpResponse.statusCode)
          throw error
        }
        
        // Parse response
        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let transcript = extractTextFromGeminiResponse(geminiResponse)
        let normalizedText = normalizeTranscriptionText(transcript)
        try validateSpeechText(normalizedText, mode: "TRANSCRIPTION-MODE")
        
        if attempt > 1 {
          DebugLogger.log("GEMINI-TRANSCRIPTION-RETRY: Success on attempt \(attempt)")
        }
        
        return normalizedText
        
      } catch is CancellationError {
        DebugLogger.log("GEMINI-TRANSCRIPTION-RETRY: Cancelled on attempt \(attempt)")
        throw CancellationError()
      } catch let error as URLError {
        if error.code == .cancelled {
          DebugLogger.log("GEMINI-TRANSCRIPTION-RETRY: Request cancelled by user")
          throw CancellationError()
        } else if error.code == .timedOut {
          throw error.localizedDescription.contains("request")
            ? TranscriptionError.requestTimeout
            : TranscriptionError.resourceTimeout
        } else {
          throw TranscriptionError.networkError(error.localizedDescription)
        }
      } catch {
        lastError = error
        if attempt < Constants.maxRetryAttempts {
          DebugLogger.log("GEMINI-TRANSCRIPTION-RETRY: Attempt \(attempt) failed, retrying in \(Constants.retryDelaySeconds)s: \(error.localizedDescription)")
          try? await Task.sleep(nanoseconds: UInt64(Constants.retryDelaySeconds * 1_000_000_000))
        }
      }
    }
    
    DebugLogger.log("GEMINI-TRANSCRIPTION-RETRY: All \(Constants.maxRetryAttempts) attempts failed")
    throw lastError ?? TranscriptionError.networkError("Gemini transcription failed after retries")
  }
  
  private func transcribeWithGeminiFilesAPI(audioURL: URL, apiKey: String) async throws -> String {
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using Files API (file >20MB)")
    
    // Step 1: Upload file using resumable upload
    let fileURI = try await uploadFileToGemini(audioURL: audioURL, apiKey: apiKey)
    
    // Step 2: Use file URI for transcription
    let result = try await transcribeWithGeminiFileURI(fileURI: fileURI, apiKey: apiKey)
    
    return result
  }
  
  private func uploadFileToGemini(audioURL: URL, apiKey: String) async throws -> String {
    let audioData = try Data(contentsOf: audioURL)
    
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = getGeminiMimeType(for: fileExtension)
    let numBytes = audioData.count
    
    // Step 1: Initialize resumable upload
    let initURL = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files?key=\(apiKey)")!
    var initRequest = URLRequest(url: initURL)
    initRequest.httpMethod = "POST"
    initRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
    initRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
    initRequest.setValue("\(numBytes)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
    initRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
    initRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let metadata: [String: Any] = [
      "file": [
        "display_name": "audio_\(Date().timeIntervalSince1970)"
      ]
    ]
    initRequest.httpBody = try JSONSerialization.data(withJSONObject: metadata)
    
    let (initData, initResponse) = try await session.data(for: initRequest)
    
    guard let httpResponse = initResponse as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }
    
    guard httpResponse.statusCode == 200 else {
      let error = try parseGeminiErrorResponse(data: initData, statusCode: httpResponse.statusCode)
      throw error
    }
    
    // Extract upload URL from response headers
    let allHeaders = httpResponse.allHeaderFields
    guard let uploadURLString = allHeaders["X-Goog-Upload-URL"] as? String,
          let uploadURL = URL(string: uploadURLString) else {
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
      throw TranscriptionError.networkError("Invalid response")
    }
    
    guard uploadHttpResponse.statusCode == 200 else {
      let error = try parseGeminiErrorResponse(data: uploadData, statusCode: uploadHttpResponse.statusCode)
      throw error
    }
    
    // Parse file info to get URI
    let fileInfo = try JSONDecoder().decode(GeminiFileInfo.self, from: uploadData)
    
    return fileInfo.file.uri
  }
  
  private func transcribeWithGeminiFileURI(fileURI: String, apiKey: String) async throws -> String {
    // Get combined prompt (normal prompt + difficult words)
    let promptToUse = buildDictationPrompt()
    
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using prompt: \(promptToUse.prefix(100))...")
    
    // Create request with dynamic endpoint based on selected model
    let endpoint = selectedTranscriptionModel.apiEndpoint
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using model: \(selectedTranscriptionModel.displayName) (\(selectedTranscriptionModel.rawValue))")
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using endpoint: \(endpoint)")
    let url = URL(string: "\(endpoint)?key=\(apiKey)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let requestBody: [String: Any] = [
      "contents": [
        [
          "parts": [
            [
              "text": promptToUse.isEmpty ? "Transcribe this audio. Return only the transcribed text without any additional commentary or formatting." : promptToUse
            ],
            [
              "file_data": [
                "file_uri": fileURI,
                "mime_type": "audio/wav"  // Default, will be determined by file
              ]
            ]
          ]
        ]
      ]
    ]
    
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
    
    let (data, response) = try await session.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }
    
    if httpResponse.statusCode != 200 {
      let error = try parseGeminiErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }
    
    let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
    let transcript = extractTextFromGeminiResponse(geminiResponse)
    let normalizedText = normalizeTranscriptionText(transcript)
    try validateSpeechText(normalizedText, mode: "TRANSCRIPTION-MODE")
    
    return normalizedText
  }
  
  private func getGeminiMimeType(for fileExtension: String) -> String {
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
  
  private func extractTextFromGeminiResponse(_ response: GeminiResponse) -> String {
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
  
  private func parseGeminiErrorResponse(data: Data, statusCode: Int) throws -> TranscriptionError {
    // Try to parse Gemini error format
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let error = json["error"] as? [String: Any],
       let message = error["message"] as? String {
      DebugLogger.log("GEMINI-ERROR: \(message)")
      
      // Map common Gemini errors to TranscriptionError
      let lowerMessage = message.lowercased()
      if lowerMessage.contains("api key") || lowerMessage.contains("authentication") {
        return statusCode == 401 ? .invalidAPIKey : .incorrectAPIKey
      }
      if lowerMessage.contains("quota") || lowerMessage.contains("exceeded") {
        return .quotaExceeded
      }
      if lowerMessage.contains("rate limit") {
        return .rateLimited
      }
    }
    
    // Fall back to status code parsing
    return parseStatusCodeError(statusCode)
  }


  private func validateSpeechText(_ text: String, mode: String = "TRANSCRIPTION-MODE") throws {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Debug logging to see what Whisper actually returned
    DebugLogger.log("VALIDATION: Received text from API (length: \(trimmedText.count)): '\(trimmedText)'")

    if trimmedText.isEmpty || trimmedText.count < Constants.minimumTextLength {
      throw TranscriptionError.textTooShort
    }

    // Enhanced prompt detection - check for various prompt patterns
    let defaultPrompt = AppConstants.defaultTranscriptionSystemPrompt
    let lowercasedText = trimmedText.lowercased()
    
    // Check for exact prompt match
    if trimmedText.contains(defaultPrompt) {
      throw TranscriptionError.promptLeakDetected
    }
    
    // Check for partial prompt patterns that might appear in transcription
    let promptKeywords = [
      "convert speech to",
      "clean text with",
      "proper punctuation",
      "transcribe this audio",
      "remove filler words",
      "disfluencies"
    ]
    
    let promptKeywordCount = promptKeywords.filter { lowercasedText.contains($0) }.count
    
    // If more than 2 prompt keywords are found, likely a prompt leak
    if promptKeywordCount > 2 {
      DebugLogger.log("PROMPT-DETECTION: Detected prompt leak in transcription: \(promptKeywordCount) keywords found")
      throw TranscriptionError.promptLeakDetected
    }
    
    // Check for context prefix
    if trimmedText.hasPrefix("context:") {
      throw TranscriptionError.promptLeakDetected
    }
    
    // Check for system-like responses that might be prompt echoes
    let systemPatterns = [
      "here is the transcription",
      "transcription:",
      "audio transcription:",
      "transcribed text:",
      "the audio says:",
      "the transcription is:"
    ]
    
    let systemPatternCount = systemPatterns.filter { lowercasedText.hasPrefix($0) }.count
    if systemPatternCount > 0 {
      DebugLogger.log("PROMPT-DETECTION: Detected system pattern in transcription: \(systemPatterns.filter { lowercasedText.hasPrefix($0) }.first ?? "unknown")")
      throw TranscriptionError.promptLeakDetected
    }
  }

  private func sanitizeUserInput(_ input: String) -> String {
    let sanitized = input.trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.filter { char in
      let scalar = char.unicodeScalars.first!
      return !CharacterSet.controlCharacters.contains(scalar) || char == "\n" || char == "\t"
    }
  }
  
  private func mergeTranscriptions(_ transcriptions: [String]) -> String {
    guard !transcriptions.isEmpty else { return "" }
    
    if transcriptions.count == 1 {
      return normalizeTranscriptionText(transcriptions[0])
    }
    
    var merged = normalizeTranscriptionText(transcriptions[0])
    
    for i in 1..<transcriptions.count {
      let current = normalizeTranscriptionText(transcriptions[i])
      
      if current.isEmpty {
        continue
      }
      
      // Try to find overlap between end of merged and start of current
      let overlap = findTranscriptionOverlap(merged, current)
      
      if overlap.count > 5 {  // Meaningful overlap found
        // Remove overlap from current transcription
        let remainingCurrent = normalizeTranscriptionText(String(current.dropFirst(overlap.count)))
        if !remainingCurrent.isEmpty {
          // Only add space if merged doesn't already end with whitespace
          if merged.last?.isWhitespace == true {
            merged += remainingCurrent
          } else {
            merged += " " + remainingCurrent
          }
        }
      } else {
        // No meaningful overlap, just concatenate with space
        // Only add space if merged doesn't already end with whitespace
        if merged.last?.isWhitespace == true {
          merged += current
        } else {
          merged += " " + current
        }
      }
    }
    
    return normalizeTranscriptionText(merged)
  }
  
  private func normalizeTranscriptionText(_ text: String) -> String {
    // Remove excessive whitespace and normalize line breaks
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Preserve line breaks: normalize multiple spaces/tabs to single space, but keep newlines
    // Step 1: Normalize multiple consecutive newlines to max 2
    let normalizedNewlines = trimmed.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    
    // Step 2: Normalize spaces/tabs within each line (but preserve newlines)
    // Split by newlines, normalize each line, then rejoin
    let lines = normalizedNewlines.components(separatedBy: "\n")
    let normalizedLines = lines.map { line in
      // Replace multiple consecutive spaces/tabs with single space
      line.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }
    let normalized = normalizedLines.joined(separator: "\n")
    
    // Additional cleanup to remove potential prompt remnants
    let cleaned = cleanTranscriptionText(normalized)
    
    return cleaned
  }
  
  private func cleanTranscriptionText(_ text: String) -> String {
    var cleaned = text
    let originalLength = cleaned.count
    
    // Remove common prompt remnants that might appear at the beginning
    let promptPrefixes = [
      "convert speech to",
      "clean text with",
      "proper punctuation",
      "transcribe this audio",
      "please transcribe",
      "transcription:",
      "audio transcription:",
      "here is the transcription:",
      "the transcription is:",
      "transcribed text:",
      "the audio says:"
    ]
    
    let lowercasedText = cleaned.lowercased()
    for prefix in promptPrefixes {
      if lowercasedText.hasPrefix(prefix) {
        DebugLogger.log("PROMPT-CLEANUP: Removed prefix: '\(prefix)' from transcription")
        cleaned = String(cleaned.dropFirst(prefix.count))
        break
      }
    }
    
    // Remove common prompt remnants that might appear at the end
    let promptSuffixes = [
      "with proper punctuation",
      "clean text with",
      "keep only the intended meaning",
      "remove filler words",
      "preserve correct punctuation",
      "numbers should be written as digits"
    ]
    
    for suffix in promptSuffixes {
      if lowercasedText.hasSuffix(suffix) {
        DebugLogger.log("PROMPT-CLEANUP: Removed suffix: '\(suffix)' from transcription")
        cleaned = String(cleaned.dropLast(suffix.count))
        break
      }
    }
    
    // Clean up any remaining whitespace
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    
    if cleaned.count != originalLength {
      DebugLogger.log("PROMPT-CLEANUP: Text cleaned: \(originalLength) -> \(cleaned.count) characters")
    }
    
    return cleaned
  }
  
  private func findTranscriptionOverlap(_ text1: String, _ text2: String) -> String {
    let words1 = text1.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    let words2 = text2.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    
    // If either text has fewer than 2 words, no meaningful overlap possible
    guard words1.count >= 2 && words2.count >= 2 else { return "" }
    
    var maxOverlap = ""
    
    // Look for overlapping word sequences (minimum 2 words, maximum 5 words for better accuracy)
    for i in max(0, words1.count - 5)..<words1.count {
      for j in 0..<min(words2.count, 5) {
        let suffix = Array(words1[i...])
        let prefix = Array(words2[0...j])
        
        // Check if suffix and prefix match exactly
        if suffix.count >= 2 && prefix.count >= 2 && suffix == prefix {
          let overlap = suffix.joined(separator: " ")
          if overlap.count > maxOverlap.count {
            maxOverlap = overlap
          }
        }
      }
    }
    
    // Only return overlap if it's meaningful (at least 2 words and reasonable length)
    return maxOverlap.count > 5 ? maxOverlap : ""
  }

  // MARK: - Prompt Mode Helpers
  private func getClipboardContext() -> String? {
    guard let clipboardManager = clipboardManager else { return nil }
    guard let clipboardText = clipboardManager.getCleanedClipboardText() else { return nil }

    let trimmedText = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return nil }
    return trimmedText
  }

  // MARK: - Shared Infrastructure Helpers
  
  private func validateAudioFile(at url: URL) throws {
    try validateAudioFileFormat(at: url)
    
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let fileSize = attributes[.size] as? Int64 else {
      throw TranscriptionError.fileError("Cannot read file size")
    }

    if fileSize == 0 {
      throw TranscriptionError.emptyFile
    }

    if fileSize > Constants.maxFileSize {
      throw TranscriptionError.fileTooLarge
    }
  }
  
  private func validateAudioFileFormat(at url: URL) throws {
    let fileExtension = url.pathExtension.lowercased()
    // Gemini supports: wav, mp3, aiff, aac, ogg, flac
    // OpenAI supports: wav, mp3, m4a, flac, ogg, webm
    let supportedExtensions = ["wav", "mp3", "m4a", "flac", "ogg", "webm", "aiff", "aac"]
    if !supportedExtensions.contains(fileExtension) {
      throw TranscriptionError.fileError("Unsupported audio format: \(fileExtension)")
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

    for (name, value) in fields {
      body.append("--\(boundary)\r\n")
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
      body.append("\(value)\r\n")
    }

    for (name, file) in files {
      body.append("--\(boundary)\r\n")
      body.append(
        "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(file.filename)\"\r\n")
      body.append("Content-Type: \(file.contentType)\r\n\r\n")
      body.append(file.data)
      body.append("\r\n")
    }

    body.append("--\(boundary)--\r\n")
    httpBody = body
  }
}


// MARK: - Error Result Parser
extension SpeechService {
  static func parseTranscriptionResult(_ text: String) -> (
    isError: Bool, errorType: TranscriptionError?
  ) {
    let errorPrefixes = ["❌", "⚠️", "⏰", "⏳", "🔄"]
    let isError = errorPrefixes.contains { text.hasPrefix($0) }

    guard isError else {
      return (false, nil)
    }

    if text.contains("No API Key") {
      return (true, .noGoogleAPIKey)
    } else if text.contains("Incorrect API Key") {
      return (true, .incorrectAPIKey)
    } else if text.contains("Country Not Supported") {
      return (true, .countryNotSupported)
    } else if text.contains("Authentication") || text.contains("invalid API key") {
      return (true, .invalidAPIKey)
    } else if text.contains("Rate Limit") {
      return (true, .rateLimited)
    } else if text.contains("Quota Exceeded") {
      return (true, .quotaExceeded)
    } else if text.contains("Request Timeout") {
      return (true, .requestTimeout)
    } else if text.contains("Resource Timeout") {
      return (true, .resourceTimeout)
    } else if text.contains("Timeout") {
      return (true, .networkError("Timeout"))
    } else if text.contains("Network Error") {
      return (true, .networkError("Network"))
    } else if text.contains("Server Error") {
      return (true, .serverError(500))
    } else if text.contains("Service Unavailable") {
      return (true, .serviceUnavailable)
    } else if text.contains("Slow Down") {
      return (true, .slowDown)
    } else if text.contains("File Too Large") {
      return (true, .fileTooLarge)
    } else if text.contains("Empty") {
      return (true, .emptyFile)
    } else {
      return (true, .serverError(0))
    }
  }
}


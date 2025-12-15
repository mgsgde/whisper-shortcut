import AVFoundation
import Foundation
import NaturalLanguage

// MARK: - Constants
private enum Constants {
  static let maxFileSize = 20 * 1024 * 1024  // 20MB - optimal für Gemini's file size limits
  static let requestTimeout: TimeInterval = 60.0
  static let resourceTimeout: TimeInterval = 300.0
  
  // DEBUG: Set to true to force Files API usage even for small files (for testing)
  static let debugForceFilesAPI = false

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
    let oldModel = self.selectedTranscriptionModel
    self.selectedTranscriptionModel = model
    
    // If switching away from offline model, unload it to free memory
    if oldModel.isOffline && !model.isOffline {
      Task {
        await LocalSpeechService.shared.unloadModel()
      }
    }
  }

  func getCurrentModel() -> TranscriptionModel {
    return selectedTranscriptionModel
  }
  
  // MARK: - Model Information for Notifications
  func getTranscriptionModelInfo() async -> String {
    if selectedTranscriptionModel.isOffline {
      return await LocalSpeechService.shared.getCurrentModelInfo() ?? selectedTranscriptionModel.displayName
    }
    return selectedTranscriptionModel.displayName
  }
  
  func getPromptModelInfo() -> String {
    let modelKey = "selectedPromptModel"
    let selectedPromptModelString = UserDefaults.standard.string(forKey: modelKey) ?? "gemini-2.5-flash"
    let selectedPromptModel = PromptModel(rawValue: selectedPromptModelString) ?? .gemini25Flash
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
    // Check if using offline model
    if selectedTranscriptionModel.isOffline {
      // For offline models, use LocalSpeechService
      guard let offlineModelType = selectedTranscriptionModel.offlineModelType else {
        throw TranscriptionError.networkError("Invalid offline model type")
      }
      
      // Check if model is available before attempting to use it
      if !ModelManager.shared.isModelAvailable(offlineModelType) {
        throw TranscriptionError.modelNotAvailable(offlineModelType)
      }
      
      // Initialize model if not already initialized
      if await !LocalSpeechService.shared.isReady() {
        try await LocalSpeechService.shared.initializeModel(offlineModelType)
      }
      
      // Validate format
      try validateAudioFileFormat(at: audioURL)
      
      // Get language setting for Whisper (defaults to auto-detect)
      let savedLanguageString = UserDefaults.standard.string(forKey: "whisperLanguage")
      let savedLanguage = WhisperLanguage(rawValue: savedLanguageString ?? WhisperLanguage.auto.rawValue) ?? WhisperLanguage.auto
      let languageString = savedLanguage.languageCode // Returns nil for .auto, which enables auto-detect
      
      if savedLanguage == .auto {
        DebugLogger.log("LOCAL-SPEECH: Using auto-detect language (default)")
      } else {
        DebugLogger.log("LOCAL-SPEECH: Using language setting: \(savedLanguage.displayName) (\(savedLanguage.rawValue))")
      }
      
      // Transcribe using local service
      return try await LocalSpeechService.shared.transcribe(audioURL: audioURL, language: languageString)
    }
    
    // Check if using Gemini model
    if selectedTranscriptionModel.isGemini {
      // For Gemini, validate format but not size (Gemini supports up to 9.5 hours)
      try validateAudioFileFormat(at: audioURL)
      return try await transcribeWithGemini(audioURL: audioURL)
    }
    
    // Should never reach here
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
    let modelString = UserDefaults.standard.string(forKey: "selectedPromptModel") ?? "gemini-2.5-flash"
    let selectedPromptModel = PromptModel(rawValue: modelString) ?? .gemini25Flash
    
    // Prompt mode ALWAYS requires Gemini API key (no offline support yet)
    // All PromptModel cases are Gemini models, so this should always be true
    guard selectedPromptModel.isGemini else {
      throw TranscriptionError.networkError("Prompt mode requires Gemini model")
    }
    
    // For Gemini, validate format but not size (Gemini supports up to 9.5 hours)
    try validateAudioFileFormat(at: audioURL)
    // Execute prompt with Gemini (it handles its own key validation)
    return try await executePromptWithGemini(audioURL: audioURL, clipboardContext: clipboardContext)
  }

  // MARK: - Gemini Prompt Mode
  private func executePromptWithGemini(audioURL: URL, clipboardContext: String?) async throws -> String {
    // Only check API key for Gemini models (offline models bypass this)
    guard let googleAPIKey = self.googleAPIKey, !googleAPIKey.isEmpty else {
      throw TranscriptionError.noGoogleAPIKey
    }
    
    DebugLogger.log("PROMPT-MODE-GEMINI: Starting execution")
    
    // Get selected model from settings
    let modelString = UserDefaults.standard.string(forKey: "selectedPromptModel") ?? "gemini-2.5-flash"
    let selectedPromptModel = PromptModel(rawValue: modelString) ?? .gemini25Flash
    
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
    var request = createGeminiRequest(endpoint: endpoint, apiKey: googleAPIKey)
    
    // Build contents array with current message only
    var contents: [GeminiChatRequest.GeminiChatContent] = []
    
    // Build current user message parts
    var userParts: [GeminiChatRequest.GeminiChatPart] = []
    
    // Add clipboard context FIRST (so Gemini knows the context before processing audio)
    if let context = clipboardContext {
      DebugLogger.log("PROMPT-MODE-GEMINI: Adding clipboard context to request (length: \(context.count) chars)")
      let contextText = """
      SELECTED TEXT FROM CLIPBOARD (apply the voice instruction to this text):
      
      \(context)
      """
      userParts.append(GeminiChatRequest.GeminiChatPart(text: contextText, inlineData: nil, fileData: nil, url: nil))
    } else {
      DebugLogger.log("PROMPT-MODE-GEMINI: No clipboard context to add")
    }
    
    // Add audio input AFTER context (so Gemini processes audio with context in mind)
    let audioSize = getAudioFileSize(at: audioURL)
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
    
    // Make request
    let result = try await performGeminiRequest(
      request,
      responseType: GeminiChatResponse.self,
      mode: "PROMPT-MODE-GEMINI",
      withRetry: false
    )
    
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
    
    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(textContent)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "PROMPT-MODE-GEMINI")
    
    DebugLogger.logSuccess("PROMPT-MODE-GEMINI: Completed successfully")
    
    return normalizedText
  }

  // MARK: - Gemini API Helpers
  
  /// Creates a URLRequest for Gemini API with proper headers
  private func createGeminiRequest(endpoint: String, apiKey: String) -> URLRequest {
    let url = URL(string: "\(endpoint)?key=\(apiKey)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }
  
  /// Generic helper to perform Gemini API requests with error handling and retry logic
  private func performGeminiRequest<T: Decodable>(
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
        
        let (data, response) = try await session.data(for: request)
        
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
          
          let error = try parseGeminiErrorResponse(data: data, statusCode: httpResponse.statusCode)
          throw error
        }
        
        // Parse response
        let result = try JSONDecoder().decode(T.self, from: data)
        
        if attempt > 1 {
          DebugLogger.log("\(mode)-RETRY: Success on attempt \(attempt)")
        }
        
        return result
        
      } catch is CancellationError {
        DebugLogger.log("\(mode)-RETRY: Cancelled on attempt \(attempt)")
        throw CancellationError()
      } catch let error as URLError {
        if error.code == .cancelled {
          DebugLogger.log("\(mode)-RETRY: Request cancelled by user")
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
        if attempt < maxAttempts {
          DebugLogger.log("\(mode)-RETRY: Attempt \(attempt) failed, retrying in \(Constants.retryDelaySeconds)s: \(error.localizedDescription)")
          try? await Task.sleep(nanoseconds: UInt64(Constants.retryDelaySeconds * 1_000_000_000))
        }
      }
    }
    
    DebugLogger.log("\(mode)-RETRY: All \(maxAttempts) attempts failed")
    throw lastError ?? TranscriptionError.networkError("Gemini request failed after retries")
  }

  // MARK: - Gemini Transcription
  private func transcribeWithGemini(audioURL: URL) async throws -> String {
    // Only check API key for Gemini models (offline models bypass this)
    guard let apiKey = self.googleAPIKey, !apiKey.isEmpty else {
      DebugLogger.log("GEMINI-TRANSCRIPTION: ERROR - No Google API key found in keychain")
      throw TranscriptionError.noGoogleAPIKey
    }
    
    // Log API key status (without exposing the key itself)
    let keyPrefix = String(apiKey.prefix(8))
    let keyLength = apiKey.count
    DebugLogger.log("GEMINI-TRANSCRIPTION: Google API key found (prefix: \(keyPrefix)..., length: \(keyLength) chars)")
    
    try validateAudioFile(at: audioURL)
    
    let audioSize = getAudioFileSize(at: audioURL)
    DebugLogger.log("GEMINI-TRANSCRIPTION: Starting transcription, file size: \(audioSize) bytes")
    
    let result: String
    // For files >20MB, use Files API (resumable upload)
    // For files ≤20MB, use inline base64
    // DEBUG: Can force Files API usage via Constants.debugForceFilesAPI
    if Constants.debugForceFilesAPI {
      DebugLogger.log("GEMINI-TRANSCRIPTION: DEBUG - Forcing Files API usage (debugForceFilesAPI = true)")
      result = try await transcribeWithGeminiFilesAPI(audioURL: audioURL, apiKey: apiKey)
    } else if audioSize > Constants.maxFileSize {
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
    
    // Build request using Codable struct
    let transcriptionRequest = GeminiTranscriptionRequest(
      contents: [
        GeminiTranscriptionRequest.GeminiTranscriptionContent(
          parts: [
            GeminiTranscriptionRequest.GeminiTranscriptionPart(
              text: promptToUse.isEmpty ? "Transcribe this audio. Return only the transcribed text without any additional commentary or formatting." : promptToUse,
              inlineData: nil,
              fileData: nil
            ),
            GeminiTranscriptionRequest.GeminiTranscriptionPart(
              text: nil,
              inlineData: GeminiTranscriptionRequest.GeminiInlineData(mimeType: mimeType, data: base64Audio),
              fileData: nil
            )
          ]
        )
      ]
    )
    
    var request = createGeminiRequest(endpoint: endpoint, apiKey: apiKey)
    request.httpBody = try JSONEncoder().encode(transcriptionRequest)
    
    // Make request with retry logic
    let geminiResponse = try await performGeminiRequest(
      request,
      responseType: GeminiResponse.self,
      mode: "GEMINI-TRANSCRIPTION",
      withRetry: true
    )
    
    let transcript = extractTextFromGeminiResponse(geminiResponse)
    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(transcript)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "TRANSCRIPTION-MODE")
    
    return normalizedText
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
    DebugLogger.log("GEMINI-FILES-API: Starting file upload")
    let audioData = try Data(contentsOf: audioURL)
    
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = getGeminiMimeType(for: fileExtension)
    let numBytes = audioData.count
    DebugLogger.log("GEMINI-FILES-API: File size: \(numBytes) bytes, MIME type: \(mimeType)")
    
    // Step 1: Initialize resumable upload
    DebugLogger.log("GEMINI-FILES-API: Step 1 - Initializing resumable upload")
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
      DebugLogger.log("GEMINI-FILES-API: ERROR - Invalid response type")
      throw TranscriptionError.networkError("Invalid response")
    }
    
    DebugLogger.log("GEMINI-FILES-API: Init response status: \(httpResponse.statusCode)")
    
    guard httpResponse.statusCode == 200 else {
      let errorBody = String(data: initData, encoding: .utf8) ?? "Unable to decode error response"
      DebugLogger.log("GEMINI-FILES-API: ERROR - Init failed with status \(httpResponse.statusCode): \(errorBody.prefix(500))")
      let error = try parseGeminiErrorResponse(data: initData, statusCode: httpResponse.statusCode)
      throw error
    }
    
    // Extract upload URL from response headers (case-insensitive search)
    let allHeaders = httpResponse.allHeaderFields
    DebugLogger.log("GEMINI-FILES-API: Response headers: \(allHeaders.keys)")
    
    // Search for upload URL header case-insensitively
    var uploadURLString: String?
    for (key, value) in allHeaders {
      if let keyString = key as? String,
         keyString.lowercased() == "x-goog-upload-url",
         let valueString = value as? String {
        uploadURLString = valueString
        DebugLogger.log("GEMINI-FILES-API: Found upload URL header: \(keyString) = \(valueString)")
        break
      }
    }
    
    guard let uploadURLString = uploadURLString,
          let uploadURL = URL(string: uploadURLString) else {
      DebugLogger.log("GEMINI-FILES-API: ERROR - Failed to get upload URL from headers. Available headers: \(allHeaders)")
      throw TranscriptionError.networkError("Failed to get upload URL")
    }
    
    DebugLogger.log("GEMINI-FILES-API: Got upload URL, proceeding to Step 2")
    
    // Step 2: Upload file data
    DebugLogger.log("GEMINI-FILES-API: Step 2 - Uploading file data (\(numBytes) bytes)")
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
    
    DebugLogger.log("GEMINI-FILES-API: Upload response status: \(uploadHttpResponse.statusCode)")
    
    guard uploadHttpResponse.statusCode == 200 else {
      let errorBody = String(data: uploadData, encoding: .utf8) ?? "Unable to decode error response"
      DebugLogger.log("GEMINI-FILES-API: ERROR - Upload failed with status \(uploadHttpResponse.statusCode): \(errorBody.prefix(500))")
      let error = try parseGeminiErrorResponse(data: uploadData, statusCode: uploadHttpResponse.statusCode)
      throw error
    }
    
    // Parse file info to get URI
    DebugLogger.log("GEMINI-FILES-API: Upload successful, parsing file info")
    let fileInfo = try JSONDecoder().decode(GeminiFileInfo.self, from: uploadData)
    DebugLogger.log("GEMINI-FILES-API: File URI: \(fileInfo.file.uri)")
    
    return fileInfo.file.uri
  }
  
  private func transcribeWithGeminiFileURI(fileURI: String, apiKey: String) async throws -> String {
    DebugLogger.log("GEMINI-FILES-API: Starting transcription with file URI")
    // Get combined prompt (normal prompt + difficult words)
    let promptToUse = buildDictationPrompt()
    
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using prompt: \(promptToUse.prefix(100))...")
    
    // Create request with dynamic endpoint based on selected model
    let endpoint = selectedTranscriptionModel.apiEndpoint
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using model: \(selectedTranscriptionModel.displayName) (\(selectedTranscriptionModel.rawValue))")
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using endpoint: \(endpoint)")
    
    // Build request using Codable struct
    let transcriptionRequest = GeminiTranscriptionRequest(
      contents: [
        GeminiTranscriptionRequest.GeminiTranscriptionContent(
          parts: [
            GeminiTranscriptionRequest.GeminiTranscriptionPart(
              text: promptToUse.isEmpty ? "Transcribe this audio. Return only the transcribed text without any additional commentary or formatting." : promptToUse,
              inlineData: nil,
              fileData: nil
            ),
            GeminiTranscriptionRequest.GeminiTranscriptionPart(
              text: nil,
              inlineData: nil,
              fileData: GeminiTranscriptionRequest.GeminiFileData(fileUri: fileURI, mimeType: "audio/wav")
            )
          ]
        )
      ]
    )
    
    var request = createGeminiRequest(endpoint: endpoint, apiKey: apiKey)
    request.httpBody = try JSONEncoder().encode(transcriptionRequest)
    
    // Make request with retry logic
    let geminiResponse = try await performGeminiRequest(
      request,
      responseType: GeminiResponse.self,
      mode: "GEMINI-TRANSCRIPTION",
      withRetry: true
    )
    
    let transcript = extractTextFromGeminiResponse(geminiResponse)
    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(transcript)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "TRANSCRIPTION-MODE")
    
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

  // MARK: - Prompt Mode Helpers
  private func getClipboardContext() -> String? {
    guard let clipboardManager = clipboardManager else {
      DebugLogger.log("PROMPT-MODE: Clipboard manager is nil")
      return nil
    }
    guard let clipboardText = clipboardManager.getCleanedClipboardText() else {
      DebugLogger.log("PROMPT-MODE: No clipboard text found")
      return nil
    }

    let trimmedText = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      DebugLogger.log("PROMPT-MODE: Clipboard text is empty after trimming")
      return nil
    }
    DebugLogger.log("PROMPT-MODE: Clipboard context found (length: \(trimmedText.count) chars)")
    return trimmedText
  }

  // MARK: - Shared Infrastructure Helpers
  
  private func getAudioFileSize(at url: URL) -> Int64 {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      return attributes[.size] as? Int64 ?? 0
    } catch {
      return 0
    }
  }
  
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


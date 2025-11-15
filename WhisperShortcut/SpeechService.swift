import AVFoundation
import Foundation
import NaturalLanguage

// MARK: - Constants
private enum Constants {
  static let maxFileSize = 20 * 1024 * 1024  // 20MB - optimal für OpenAI's 25MB Limit
  static let requestTimeout: TimeInterval = 60.0
  static let resourceTimeout: TimeInterval = 300.0
  static let validationTimeout: TimeInterval = 10.0
  static let transcriptionEndpoint = "https://api.openai.com/v1/audio/transcriptions"
  static let chatEndpoint = "https://api.openai.com/v1/chat/completions"
  static let modelsEndpoint = "https://api.openai.com/v1/models"

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
  private let ttsService: TTSService
  private let audioPlaybackService: AudioPlaybackService
  private let audioChunkingService: AudioChunkingService
  private var clipboardManager: ClipboardManager?

  // Custom session with appropriate timeouts
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = Constants.requestTimeout
    config.timeoutIntervalForResource = Constants.resourceTimeout
    return URLSession(configuration: config)
  }()

  // MARK: - Transcription Mode Properties
  private var selectedTranscriptionModel: TranscriptionModel = .gpt4oMiniTranscribe

  // MARK: - Prompt/Conversation State
  private var previousResponseTimestamp: Date?       // Track when the last response was received
  private var previousResponseId: String?            // Track the last response ID for conversation continuity
  private var conversationMessages: [GPTAudioChatRequest.GPTAudioMessage] = []

  // MARK: - Task Tracking for Cancellation
  private var currentTranscriptionTask: Task<String, Error>?
  private var currentPromptTask: Task<String, Error>?
  private var currentVoiceResponseTask: Task<String, Error>?

  init(
    keychainManager: KeychainManaging = KeychainManager.shared,
    clipboardManager: ClipboardManager? = nil
  ) {
    self.keychainManager = keychainManager
    self.clipboardManager = clipboardManager
    self.ttsService = TTSService(keychainManager: keychainManager)
    self.audioPlaybackService = AudioPlaybackService.shared
    self.audioChunkingService = AudioChunkingService()

  }

  // MARK: - Shared API Key Management
  private var apiKey: String? {
    keychainManager.getAPIKey()
  }

  func updateAPIKey(_ key: String) {
    _ = keychainManager.saveAPIKey(key)
  }

  func clearAPIKey() {
    _ = keychainManager.deleteAPIKey()
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
    let selectedPromptModelString = UserDefaults.standard.string(forKey: modelKey) ?? "gpt-audio-mini"
    let selectedPromptModel = PromptModel(rawValue: selectedPromptModelString) ?? .gptAudioMini
    return selectedPromptModel.displayName
  }
  
  func getVoiceResponseModelInfo() -> String {
    let modelString = UserDefaults.standard.string(forKey: "selectedGPTAudioModel") ?? "gpt-audio-mini"
    let model = GPTAudioModel(rawValue: modelString) ?? .gptAudioMini
    return model.displayName
  }

  // MARK: - Conversation Management
  func clearConversationHistory() {
    previousResponseTimestamp = nil
    previousResponseId = nil
    conversationMessages = []
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

  func cancelVoiceResponse() {
    DebugLogger.log("CANCELLATION: Cancelling voice response task")
    currentVoiceResponseTask?.cancel()
    currentVoiceResponseTask = nil
    // Also stop any ongoing TTS generation
    ttsService.cancelGeneration()
  }

  internal func isConversationExpired(isVoiceResponse: Bool) -> Bool {
    guard let timestamp = previousResponseTimestamp else {
      return true  // No previous conversation
    }

    // Read per-mode timeout from settings
    let key = isVoiceResponse
      ? "voiceResponseConversationTimeoutMinutes" : "promptConversationTimeoutMinutes"

    // If not set, fall back to default (30 seconds)
    let timeoutMinutes = UserDefaults.standard.object(forKey: key) as? Double ?? 0.5

    // No memory mode: 0.0 means instant expiry
    if timeoutMinutes == 0.0 {
      clearConversationHistory()
      return true
    }

    let expirationTime = timestamp.addingTimeInterval(timeoutMinutes * 60)  // Convert to seconds
    let isExpired = Date() > expirationTime

    if isExpired {
      clearConversationHistory()
    }

    return isExpired
  }

  // MARK: - Shared Validation
  func validateAPIKey(_ key: String) async throws -> Bool {
    guard !key.isEmpty else {
      throw TranscriptionError.noAPIKey
    }

    let url = URL(string: Constants.modelsEndpoint)!
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = Constants.validationTimeout

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }

    if httpResponse.statusCode != 200 {
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    return true
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
    let audioSize = audioChunkingService.getAudioSize(audioURL)

    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      throw TranscriptionError.noAPIKey
    }

    try validateAudioFile(at: audioURL)

    // SMART CHUNKING STRATEGY: Based on OpenAI API file size limits
    if audioSize <= Constants.maxFileSize {
      // File ≤20MB: Send to OpenAI directly with retry logic
      return try await transcribeSingleFileWithRetry(audioURL: audioURL, apiKey: apiKey)
    } else {
      // File >20MB: Use client-side chunking first, then send multiple requests
      let transcribedText = try await transcribeAudioChunked(audioURL)
      let normalizedText = normalizeTranscriptionText(transcribedText)
      try validateSpeechText(normalizedText, mode: "TRANSCRIPTION-MODE")
      return normalizedText
    }
  }
  
  // MARK: - Single File Transcription with Retry
  private func transcribeSingleFileWithRetry(audioURL: URL, apiKey: String) async throws -> String {
    var lastError: Error?
    
    for attempt in 1...Constants.maxRetryAttempts {
      do {
        if attempt > 1 {
          DebugLogger.log("TRANSCRIPTION-RETRY: Attempt \(attempt)/\(Constants.maxRetryAttempts)")
        }
        
        let request = try createTranscriptionRequest(audioURL: audioURL, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
          throw TranscriptionError.networkError("Invalid response")
        }

        if httpResponse.statusCode != 200 {
          DebugLogger.log("TRANSCRIPTION-ERROR: HTTP \(httpResponse.statusCode)")
          let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
          throw error
        }

        let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
        let normalizedText = normalizeTranscriptionText(result.text)
        try validateSpeechText(normalizedText, mode: "TRANSCRIPTION-MODE")
        
        if attempt > 1 {
          DebugLogger.log("TRANSCRIPTION-RETRY: Success on attempt \(attempt)")
        }
        
        return normalizedText
        
      } catch is CancellationError {
        // Task was cancelled - propagate immediately without retry
        DebugLogger.log("TRANSCRIPTION-RETRY: Cancelled on attempt \(attempt)")
        throw CancellationError()
        
      } catch let error as URLError {
        // Handle specific URL errors
        if error.code == .cancelled {
          DebugLogger.log("TRANSCRIPTION-RETRY: Request cancelled by user")
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
          DebugLogger.log("TRANSCRIPTION-RETRY: Attempt \(attempt) failed, retrying in \(Constants.retryDelaySeconds)s: \(error.localizedDescription)")
          try? await Task.sleep(nanoseconds: UInt64(Constants.retryDelaySeconds * 1_000_000_000))
        }
      }
    }
    
    // All retries failed
    DebugLogger.log("TRANSCRIPTION-RETRY: All \(Constants.maxRetryAttempts) attempts failed")
    throw lastError ?? TranscriptionError.networkError("Transcription failed after retries")
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
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      throw TranscriptionError.noAPIKey
    }

    return try await executePromptWithAudioModel(audioURL: audioURL)
  }

  private func buildPromptInput(
    userMessage: String, clipboardContext: String?, isVoiceResponse: Bool = false
  ) -> String {
    let baseSystemPrompt: String
    let customSystemPromptKey: String

    if isVoiceResponse {
      baseSystemPrompt = AppConstants.defaultVoiceResponseSystemPrompt
      customSystemPromptKey = "voiceResponseSystemPrompt"
    } else {
      baseSystemPrompt = AppConstants.defaultPromptModeSystemPrompt
      customSystemPromptKey = "promptModeSystemPrompt"
    }

    let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptKey)

    var fullInput = baseSystemPrompt
    if let customPrompt = customSystemPrompt, !customPrompt.isEmpty {
      fullInput += "\n\nAdditional instructions: \(customPrompt)"
    }

    if let context = clipboardContext {
      fullInput += "\n\nContext (selected text from clipboard):\n\(context)"
    }

    let sanitizedUserMessage = sanitizeUserInput(userMessage)
    fullInput += "\n\nUser: \(sanitizedUserMessage)"
    return fullInput
  }

  private func buildPromptInputSeparated(
    userMessage: String, clipboardContext: String?, isVoiceResponse: Bool = false
  ) -> (userInput: String, systemInstructions: String) {
    let baseSystemPrompt: String
    let customSystemPromptKey: String

    if isVoiceResponse {
      baseSystemPrompt = AppConstants.defaultVoiceResponseSystemPrompt
      customSystemPromptKey = "voiceResponseSystemPrompt"
    } else {
      baseSystemPrompt = AppConstants.defaultPromptModeSystemPrompt
      customSystemPromptKey = "promptModeSystemPrompt"
    }

    let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptKey)

    var systemInstructions = baseSystemPrompt
    if let customPrompt = customSystemPrompt, !customPrompt.isEmpty {
      systemInstructions += "\n\nAdditional instructions: \(customPrompt)"
    }

    var userInput = ""
    if let context = clipboardContext {
      userInput += "Context (selected text from clipboard):\n\(context)\n\n"
    }

    let sanitizedUserMessage = sanitizeUserInput(userMessage)
    userInput += sanitizedUserMessage

    return (userInput: userInput, systemInstructions: systemInstructions)
  }

  func executePromptWithVoiceResponse(audioURL: URL, clipboardContext: String? = nil) async throws
    -> String
  {
    // Create and store task for cancellation support
    let task = Task<String, Error> {
      try await self.performVoiceResponse(audioURL: audioURL, clipboardContext: clipboardContext)
    }
    
    currentVoiceResponseTask = task
    defer { currentVoiceResponseTask = nil }
    
    return try await task.value
  }

  private func performVoiceResponse(audioURL: URL, clipboardContext: String? = nil) async throws
    -> String
  {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      throw TranscriptionError.noAPIKey
    }

    DebugLogger.log("VOICE-RESPONSE: Starting execution")
    
    // Get clipboard context
    let contextToUse = clipboardContext ?? getClipboardContext()
    let hasContext = contextToUse != nil
    DebugLogger.log("VOICE-RESPONSE: Clipboard context: \(hasContext ? "present" : "none")")

    // Convert audio to base64
    let audioData = try Data(contentsOf: audioURL)
    let base64Audio = audioData.base64EncodedString()
    
    // Determine audio format from file extension
    let audioFormat = audioURL.pathExtension.lowercased()
    let supportedFormat: String
    switch audioFormat {
    case "wav":
      supportedFormat = "wav"
    case "mp3":
      supportedFormat = "mp3"
    case "m4a":
      supportedFormat = "mp4"  // m4a is actually mp4 audio
    default:
      supportedFormat = "wav"  // fallback
    }
    
    // Build request
    let url = URL(string: Constants.chatEndpoint)!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    // Build system prompt
    let baseSystemPrompt = AppConstants.defaultVoiceResponseSystemPrompt
    let customSystemPromptKey = "voiceResponseSystemPrompt"
    let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptKey)
    
    // Custom prompt REPLACES base prompt if set
    let systemPrompt: String
    if let customPrompt = customSystemPrompt, !customPrompt.isEmpty {
      systemPrompt = customPrompt
      DebugLogger.log("VOICE-RESPONSE: Using custom system prompt")
    } else {
      systemPrompt = baseSystemPrompt
      DebugLogger.log("VOICE-RESPONSE: Using base system prompt")
    }
    
    // Get selected model from settings
    let modelString = UserDefaults.standard.string(forKey: "selectedGPTAudioModel") ?? "gpt-audio-mini"
    let selectedModel = GPTAudioModel(rawValue: modelString) ?? .gptAudioMini
    
    // Check conversation state
    let conversationExpired = isConversationExpired(isVoiceResponse: true)
    DebugLogger.log("VOICE-RESPONSE: Conversation \(conversationExpired ? "expired" : "active") (\(conversationMessages.count) messages)")
    
    // Create messages
    var messages: [GPTAudioChatRequest.GPTAudioMessage] = []
    
    // System message
    messages.append(GPTAudioChatRequest.GPTAudioMessage(
      role: "system",
      content: .text(systemPrompt)
    ))
    
    // Add conversation history if not expired
    if !isConversationExpired(isVoiceResponse: true) {
      messages.append(contentsOf: conversationMessages)
    }
    
    // User message with text context and audio
    var contentParts: [GPTAudioChatRequest.GPTAudioMessage.ContentPart] = []
    
    // Add clipboard context if available
    if let context = contextToUse {
      contentParts.append(GPTAudioChatRequest.GPTAudioMessage.ContentPart(
        type: "text",
        text: """
        SELECTED TEXT (use this as main context for my question):
        \(context)
        
        [My voice question/instruction follows]
        """,
        input_audio: nil
      ))
    }
    
    // Add audio input
    contentParts.append(GPTAudioChatRequest.GPTAudioMessage.ContentPart(
      type: "input_audio",
      text: nil,
      input_audio: GPTAudioChatRequest.GPTAudioMessage.ContentPart.InputAudio(
        data: base64Audio,
        format: supportedFormat
      )
    ))
    
    messages.append(GPTAudioChatRequest.GPTAudioMessage(
      role: "user",
      content: .multiContent(contentParts)
    ))
    
    let chatRequest = GPTAudioChatRequest(
      model: selectedModel.rawValue,
      messages: messages,
      modalities: ["text", "audio"],
      audio: GPTAudioChatRequest.AudioConfig(voice: "alloy", format: "mp3")
    )
    
    request.httpBody = try JSONEncoder().encode(chatRequest)
    
    let (data, responseData) = try await session.data(for: request)
    
    guard let httpResponse = responseData as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }
    
    if httpResponse.statusCode != 200 {
      DebugLogger.log("VOICE-RESPONSE-ERROR: HTTP \(httpResponse.statusCode)")
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }
    
    let result = try JSONDecoder().decode(GPTAudioChatResponse.self, from: data)
    
    guard let firstChoice = result.choices.first else {
      throw TranscriptionError.networkError("No choices in GPT-Audio response")
    }
    
    // Extract text content for clipboard and display
    var textContent = ""
    if let content = firstChoice.message.content {
      switch content {
      case .text(let text):
        textContent = text
      case .multiContent(let parts):
        // Extract text from multi-content
        for part in parts {
          if part.type == "text", let text = part.text {
            textContent += text
          }
        }
      }
    }
    
    // Extract audio output
    guard let audioOutput = firstChoice.message.audio else {
      // Fallback to TTS if no audio
      let speed = 1.0  // Fixed playback speed for GPT Audio (not user-configurable)
      
      // Copy to clipboard immediately before audio playback
      clipboardManager?.copyToClipboard(text: textContent)
      
      NotificationCenter.default.post(
        name: NSNotification.Name("VoiceResponseReadyToSpeak"), object: nil)
      
      await MainActor.run {
        NotificationCenter.default.post(
          name: NSNotification.Name("VoicePlaybackStartedWithText"),
          object: nil,
          userInfo: ["responseText": textContent]
        )
      }
      
      try await playTextAsSpeechChunked(textContent, playbackType: .voiceResponse, speed: speed)
      return textContent
    }
    
    // Decode base64 audio
    guard let audioData = Data(base64Encoded: audioOutput.data) else {
      DebugLogger.logError("VOICE-RESPONSE-ERROR: Failed to decode audio data")
      throw TranscriptionError.networkError("Failed to decode audio data")
    }
    
    // Extract transcript
    let transcriptText = audioOutput.transcript ?? textContent

    // Copy to clipboard immediately before audio playback
    clipboardManager?.copyToClipboard(text: transcriptText)

    NotificationCenter.default.post(
      name: NSNotification.Name("VoiceResponseReadyToSpeak"), object: nil)

    await MainActor.run {
      NotificationCenter.default.post(
        name: NSNotification.Name("VoicePlaybackStartedWithText"),
        object: nil,
        userInfo: ["responseText": transcriptText]
      )
    }
    
    // Play audio directly (NO TTS!)
    let playbackResult = try await audioPlaybackService.playAudio(data: audioData, playbackType: .voiceResponse)
    
    switch playbackResult {
    case .completedSuccessfully:
      break
    case .stoppedByUser:
      break
    case .failed:
      throw TranscriptionError.networkError("Audio playback failed")
    }

    // Save conversation for next request (text-only, no audio data)
    let userMessageText: String
    if let context = contextToUse {
      userMessageText = "User spoke (with context: \(context))"
    } else {
      userMessageText = "User spoke"
    }
    
    conversationMessages.append(GPTAudioChatRequest.GPTAudioMessage(
      role: "user",
      content: .text(userMessageText)
    ))
    conversationMessages.append(GPTAudioChatRequest.GPTAudioMessage(
      role: "assistant",
      content: .text(transcriptText)
    ))
    previousResponseTimestamp = Date()
    
    DebugLogger.logSuccess("VOICE-RESPONSE: Completed successfully")

    return transcriptText
  }

  func executePromptWithAudioModel(audioURL: URL) async throws -> String {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      throw TranscriptionError.noAPIKey
    }

    DebugLogger.log("PROMPT-MODE: Starting execution")
    
    // Get clipboard context
    let clipboardContext = getClipboardContext()
    let hasContext = clipboardContext != nil
    DebugLogger.log("PROMPT-MODE: Clipboard context: \(hasContext ? "present" : "none")")

    // Convert audio to base64
    let audioData = try Data(contentsOf: audioURL)
    let base64Audio = audioData.base64EncodedString()
    
    // Determine audio format from file extension
    let audioFormat = audioURL.pathExtension.lowercased()
    let supportedFormat: String
    switch audioFormat {
    case "wav":
      supportedFormat = "wav"
    case "mp3":
      supportedFormat = "mp3"
    case "m4a":
      supportedFormat = "mp4"  // m4a is actually mp4 audio
    default:
      supportedFormat = "wav"  // fallback
    }
    
    // Build request
    let url = URL(string: Constants.chatEndpoint)!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    // Build system prompt
    let baseSystemPrompt = AppConstants.defaultPromptModeSystemPrompt
    let customSystemPromptKey = "promptModeSystemPrompt"
    let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptKey)
    
    // Custom prompt REPLACES base prompt if set
    let systemPrompt: String
    if let customPrompt = customSystemPrompt, !customPrompt.isEmpty {
      systemPrompt = customPrompt
      DebugLogger.log("PROMPT-MODE: Using custom system prompt")
    } else {
      systemPrompt = baseSystemPrompt
      DebugLogger.log("PROMPT-MODE: Using base system prompt")
    }
    
    // Get selected model from settings
    let modelString = UserDefaults.standard.string(forKey: "selectedPromptModel") ?? "gpt-audio-mini"
    let selectedPromptModel = PromptModel(rawValue: modelString) ?? .gptAudioMini
    
    // Convert to GPTAudioModel for API call
    guard let audioModel = selectedPromptModel.asGPTAudioModel else {
      throw TranscriptionError.networkError("Selected model is not a GPT-Audio model")
    }
    
    // Check conversation state
    let conversationExpired = isConversationExpired(isVoiceResponse: false)
    DebugLogger.log("PROMPT-MODE: Conversation \(conversationExpired ? "expired" : "active") (\(conversationMessages.count) messages)")
    
    // Create messages
    var messages: [GPTAudioChatRequest.GPTAudioMessage] = []
    
    // System message
    messages.append(GPTAudioChatRequest.GPTAudioMessage(
      role: "system",
      content: .text(systemPrompt)
    ))
    
    // Add conversation history if not expired
    if !isConversationExpired(isVoiceResponse: false) {
      messages.append(contentsOf: conversationMessages)
    }
    
    // User message with text context and audio
    var contentParts: [GPTAudioChatRequest.GPTAudioMessage.ContentPart] = []
    
    // Add clipboard context if available
    if let context = clipboardContext {
      contentParts.append(GPTAudioChatRequest.GPTAudioMessage.ContentPart(
        type: "text",
        text: """
        TASK: Apply my voice instruction to the following text.
        
        TEXT TO PROCESS:
        \(context)
        
        Now listen to my voice instruction and apply it to the text above.
        """,
        input_audio: nil
      ))
    }
    
    // Add audio input
    contentParts.append(GPTAudioChatRequest.GPTAudioMessage.ContentPart(
      type: "input_audio",
      text: nil,
      input_audio: GPTAudioChatRequest.GPTAudioMessage.ContentPart.InputAudio(
        data: base64Audio,
        format: supportedFormat
      )
    ))
    
    messages.append(GPTAudioChatRequest.GPTAudioMessage(
      role: "user",
      content: .multiContent(contentParts)
    ))
    
    // For Prompt Mode, we only want text output (no audio)
    let chatRequest = GPTAudioChatRequest(
      model: audioModel.rawValue,
      messages: messages,
      modalities: ["text"],  // Only text output for Prompt Mode
      audio: nil  // No audio output needed
    )
    
    request.httpBody = try JSONEncoder().encode(chatRequest)

    let (data, responseData) = try await session.data(for: request)
    
    guard let httpResponse = responseData as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }
    
    if httpResponse.statusCode != 200 {
      DebugLogger.log("PROMPT-MODE-ERROR: HTTP \(httpResponse.statusCode)")
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }
    
    let result = try JSONDecoder().decode(GPTAudioChatResponse.self, from: data)
    
    guard let firstChoice = result.choices.first else {
      throw TranscriptionError.networkError("No choices in GPT-Audio response")
    }
    
    // Extract text content for clipboard and display
    var textContent = ""
    if let content = firstChoice.message.content {
      switch content {
      case .text(let text):
        textContent = text
      case .multiContent(let parts):
        // Extract text from multi-content
        for part in parts {
          if part.type == "text", let text = part.text {
            textContent += text
          }
        }
      }
    }
    
    // Save conversation for next request (text-only, no audio data)
    let userMessageText: String
    if let context = clipboardContext {
      userMessageText = "User spoke (with context: \(context))"
    } else {
      userMessageText = "User spoke"
    }
    
    conversationMessages.append(GPTAudioChatRequest.GPTAudioMessage(
      role: "user",
      content: .text(userMessageText)
    ))
    conversationMessages.append(GPTAudioChatRequest.GPTAudioMessage(
      role: "assistant",
      content: .text(textContent)
    ))
    previousResponseTimestamp = Date()
    
    DebugLogger.logSuccess("PROMPT-MODE: Completed successfully")

    return textContent
  }

  // MARK: - Transcription Mode Helpers
  private func createTranscriptionRequest(audioURL: URL, apiKey: String) throws -> URLRequest {
    let apiURL = URL(string: selectedTranscriptionModel.apiEndpoint)!
    var request = URLRequest(url: apiURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    return try createMultipartRequest(request: &request, audioURL: audioURL)
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

  // MARK: - Chunked Transcription
  private func transcribeAudioChunked(_ audioURL: URL) async throws -> String {
    let chunks = audioChunkingService.splitAudioIntelligently(
      audioURL, 
      maxDuration: 120.0,  // 2 minutes per chunk
      maxSize: Int64(Constants.maxFileSize)
    )
    
    if chunks.count == 1 {
      return try await transcribeSingleChunk(chunks[0])
    }
    
    var transcriptions: [String] = []
    
    // Process chunks sequentially to maintain order
    for (index, chunkURL) in chunks.enumerated() {
      let transcription = await transcribeChunkWithRetry(chunkURL, chunkIndex: index + 1, totalChunks: chunks.count)
      transcriptions.append(transcription)
      
      // Clean up temporary chunk file
      try? FileManager.default.removeItem(at: chunkURL)
    }
    
    // Merge transcriptions intelligently
    let mergedTranscription = mergeTranscriptions(transcriptions)
    
    return mergedTranscription
  }
  
  private func transcribeChunkWithRetry(_ audioURL: URL, chunkIndex: Int, totalChunks: Int) async -> String {
    var lastError: Error?
    
    for attempt in 1...Constants.maxRetryAttempts {
      do {
        let transcription = try await transcribeSingleChunk(audioURL)
        return transcription
      } catch is CancellationError {
        // Task was cancelled - propagate immediately
        DebugLogger.log("CHUNK-RETRY: Chunk \(chunkIndex) cancelled on attempt \(attempt)")
        return "[Cancelled]"
      } catch {
        lastError = error
        
        if attempt < Constants.maxRetryAttempts {
          try? await Task.sleep(nanoseconds: UInt64(Constants.retryDelaySeconds * 1_000_000_000))
        }
      }
    }
    
    // All retries failed
    return "[Transcription failed for segment \(chunkIndex) after \(Constants.maxRetryAttempts) attempts: \(lastError?.localizedDescription ?? "Unknown error")]"
  }
  
  private func transcribeSingleChunk(_ audioURL: URL) async throws -> String {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      throw TranscriptionError.noAPIKey
    }
    
    try validateAudioFile(at: audioURL)
    
    let request = try createTranscriptionRequest(audioURL: audioURL, apiKey: apiKey)
    
    do {
      let (data, response) = try await session.data(for: request)
      
      guard let httpResponse = response as? HTTPURLResponse else {
        throw TranscriptionError.networkError("Invalid response")
      }
      
      if httpResponse.statusCode != 200 {
        let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
        throw error
      }
      
      do {
        let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
        return result.text
      } catch {
        throw TranscriptionError.networkError("Failed to decode transcription response")
      }
    } catch let error as URLError where error.code == .cancelled {
      // Request was cancelled - propagate as CancellationError
      throw CancellationError()
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
    
    // Replace multiple consecutive whitespace characters with single space
    let normalized = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    
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

  // MARK: - TTS Chunking Helpers
  private func splitTextForTTS(_ text: String, maxLen: Int) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    // Language-agnostic sentence tokenization
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = trimmed

    var sentences: [String] = []
    tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
      let s = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !s.isEmpty { sentences.append(s) }
      return true
    }

    // If NLTokenizer failed to find boundaries, fallback to whole text
    if sentences.isEmpty { sentences = [trimmed] }

    func splitOversized(_ segment: String, limit: Int) -> [String] {
      var result: [String] = []
      var remaining = segment
      while remaining.count > limit {
        // Find last whitespace within limit to avoid mid-word split
        let idx = remaining.index(remaining.startIndex, offsetBy: limit)
        let head = String(remaining[..<idx])
        if let lastSpace = head.lastIndex(where: { $0.isWhitespace }) {
          let part = String(remaining[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
          if !part.isEmpty { result.append(part) }
          remaining = String(remaining[remaining.index(after: lastSpace)...])
        } else {
          // No whitespace, hard split
          result.append(head)
          remaining = String(remaining[idx...])
        }
      }
      let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
      if !tail.isEmpty { result.append(tail) }
      return result
    }

    var chunks: [String] = []
    var current = ""

    func flush() {
      let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty { chunks.append(t) }
      current = ""
    }

    for sentence in sentences {
      if sentence.count > maxLen {
        // Close current before splitting large sentence
        flush()
        chunks.append(contentsOf: splitOversized(sentence, limit: maxLen))
        continue
      }

      if current.isEmpty {
        current = sentence
      } else if current.count + 1 + sentence.count <= maxLen {
        current += " " + sentence
      } else {
        flush()
        current = sentence
      }
    }

    flush()
    return chunks
  }

  private func playTextAsSpeechChunked(
    _ text: String, playbackType: PlaybackType, speed: Double
  ) async throws {
    // Use OpenAI TTS API limit with safety margin
    let maxLen = max(512, TTSService.maxAllowedTextLength - 64)  // 4032 chars (4096 - 64 safety)
    let chunks = splitTextForTTS(text, maxLen: maxLen)
    
    if chunks.isEmpty { 
      return 
    }

    // Pre-generate first chunk
    var currentAudioData: Data?
    var nextAudioTask: Task<Data, Error>?
    
    // Start generating first chunk
    do {
      currentAudioData = try await ttsService.generateSpeech(text: chunks[0], speed: speed)
    } catch let ttsError as TTSError {
      throw TranscriptionError.ttsError(ttsError)
    } catch {
      throw TranscriptionError.networkError("Text-to-speech failed: \(error.localizedDescription)")
    }

    for (index, _) in chunks.enumerated() {
      // Start generating next chunk in parallel (if exists)
      if index + 1 < chunks.count {
        let nextChunk = chunks[index + 1]
        nextAudioTask = Task {
          return try await ttsService.generateSpeech(text: nextChunk, speed: speed)
        }
      }
      
      // Use current audio data (already generated)
      guard let audioData = currentAudioData else {
        throw TranscriptionError.networkError("No audio data available")
      }

      let result = try await audioPlaybackService.playAudio(data: audioData, playbackType: playbackType)
      
      // While playing, wait for next chunk generation to complete
      if let nextTask = nextAudioTask {
        do {
          currentAudioData = try await nextTask.value
        } catch {
          currentAudioData = nil
        }
        nextAudioTask = nil
      } else {
        currentAudioData = nil
      }
      
      switch result {
      case .completedSuccessfully:
        continue
      case .stoppedByUser:
        // Cancel any pending generation
        nextAudioTask?.cancel()
        return
      case .failed:
        // Cancel any pending generation
        nextAudioTask?.cancel()
        throw TranscriptionError.networkError("Audio playback failed")
      }
    }
  }

  func readSelectedTextAsSpeech() async throws -> String {
    captureSelectedText()
    try await Task.sleep(nanoseconds: Constants.clipboardCopyDelay)

    guard let selectedText = getClipboardContext(), !selectedText.isEmpty else {
      throw TranscriptionError.networkError("No text selected to read")
    }

    let playbackSpeed = UserDefaults.standard.double(forKey: "readSelectedTextPlaybackSpeed")
    let speed = playbackSpeed > 0 ? playbackSpeed : 1.0

    NotificationCenter.default.post(
      name: NSNotification.Name("ReadSelectedTextReadyToSpeak"),
      object: nil,
      userInfo: ["selectedText": selectedText]
    )
    try await playTextAsSpeechChunked(selectedText, playbackType: .readSelectedText, speed: speed)

    return selectedText
  }

  // MARK: - Prompt Mode Helpers
  private func getClipboardContext() -> String? {
    guard let clipboardManager = clipboardManager else { return nil }
    guard let clipboardText = clipboardManager.getCleanedClipboardText() else { return nil }

    let trimmedText = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return nil }
    return trimmedText
  }

  private func captureSelectedText() {
    let source = CGEventSource(stateID: .combinedSessionState)
    let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)  // C key
    let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
    cmdDown?.flags = .maskCommand
    cmdUp?.flags = .maskCommand
    cmdDown?.post(tap: .cghidEventTap)
    cmdUp?.post(tap: .cghidEventTap)
  }


  // MARK: - Shared Infrastructure Helpers
  
  private func validateAudioFile(at url: URL) throws {
    let fileExtension = url.pathExtension.lowercased()
    if !Constants.supportedAudioExtensions.contains(fileExtension) {
      throw TranscriptionError.fileError("Unsupported audio format: \(fileExtension)")
    }

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

  private func createMultipartRequest(request: inout URLRequest, audioURL: URL) throws -> URLRequest {
    let boundary = "Boundary-\(UUID().uuidString)"

    var fields: [String: String] = [
      "model": selectedTranscriptionModel.rawValue,
      "response_format": "json",
    ]
    
    // Always use server-side auto chunking - let OpenAI decide optimal strategy
    fields["chunking_strategy"] = "auto"

    // Add prompt if model supports it
    let supportsPrompt = selectedTranscriptionModel == .gpt4oTranscribe
      || selectedTranscriptionModel == .gpt4oMiniTranscribe
    
    if supportsPrompt {
      let customPrompt = UserDefaults.standard.string(forKey: "customPromptText")
        ?? AppConstants.defaultTranscriptionSystemPrompt
      
      let promptToUse = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
      
      if !promptToUse.isEmpty {
        fields["prompt"] = promptToUse
      }
    }

    let audioData = try Data(contentsOf: audioURL)

    // Determine correct content type based on file extension
    let fileExtension = audioURL.pathExtension.lowercased()
    let contentType: String
    let filename: String
    
    switch fileExtension {
    case "m4a":
      contentType = "audio/m4a"
      filename = "audio.m4a"
    case "wav":
      contentType = "audio/wav" 
      filename = "audio.wav"
    case "mp3":
      contentType = "audio/mpeg"
      filename = "audio.mp3"
    default:
      contentType = "audio/wav"
      filename = "audio.wav"
    }
    
    let files: [String: (filename: String, contentType: String, data: Data)] = [
      "file": (filename: filename, contentType: contentType, data: audioData)
    ]

    request.setMultipartFormData(boundary: boundary, fields: fields, files: files)
    return request
  }

  private func parseErrorResponse(data: Data, statusCode: Int) throws -> TranscriptionError {
    if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
      return parseOpenAIError(errorResponse, statusCode: statusCode)
    }
    return parseStatusCodeError(statusCode)
  }

  private func parseOpenAIError(_ errorResponse: OpenAIErrorResponse, statusCode: Int)
    -> TranscriptionError
  {
    let errorMessage = errorResponse.error?.message?.lowercased() ?? ""
    let errorType = errorResponse.error?.type?.lowercased() ?? ""

    switch statusCode {
    case 401:
      if errorMessage.contains("incorrect api key") && !errorMessage.contains("invalid") {
        return .incorrectAPIKey
      } else {
        return .invalidAPIKey
      }
    case 403:
      if errorMessage.contains("country") || errorMessage.contains("region")
        || errorMessage.contains("territory")
      {
        return .countryNotSupported
      } else {
        return .permissionDenied
      }
    case 429:
      if errorMessage.contains("quota") || errorMessage.contains("billing")
        || errorMessage.contains("exceeded")
      {
        return .quotaExceeded
      } else {
        return .rateLimited
      }
    case 503:
      if errorMessage.contains("slow down") || errorType.contains("slow_down") {
        return .slowDown
      } else {
        return .serviceUnavailable
      }
    default:
      return parseStatusCodeError(statusCode)
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
      return (true, .noAPIKey)
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


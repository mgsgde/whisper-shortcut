import AVFoundation
import Foundation
import NaturalLanguage

// MARK: - Prompt Mode Enum
enum PromptMode {
  case togglePrompting
  case promptAndRead
}

// MARK: - Constants
private enum Constants {
  static let requestTimeout: TimeInterval = 60.0
  static let resourceTimeout: TimeInterval = 300.0
  
  // DEBUG: Set to true to force Files API usage even for small files (for testing)
  static let debugForceFilesAPI = false
    
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
  private let geminiClient: GeminiAPIClient

  // MARK: - Chunked Transcription
  /// Delegate for receiving chunk progress updates during long audio transcription.
  weak var chunkProgressDelegate: ChunkProgressDelegate?

  // MARK: - Transcription Mode Properties
  private var selectedTranscriptionModel: TranscriptionModel = SettingsDefaults.selectedTranscriptionModel


  // MARK: - Task Tracking for Cancellation
  private var currentTranscriptionTask: Task<String, Error>?
  private var currentPromptTask: Task<String, Error>?
  private var currentTTSTask: Task<Data, Error>?

  init(
    keychainManager: KeychainManaging = KeychainManager.shared,
    clipboardManager: ClipboardManager? = nil,
    geminiClient: GeminiAPIClient? = nil
  ) {
    self.keychainManager = keychainManager
    self.clipboardManager = clipboardManager
    self.geminiClient = geminiClient ?? GeminiAPIClient()
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

  // MARK: - Model Information for Notifications
  func getTranscriptionModelInfo() async -> String {
    if selectedTranscriptionModel.isOffline {
      return await LocalSpeechService.shared.getCurrentModelInfo() ?? selectedTranscriptionModel.displayName
    }
    return selectedTranscriptionModel.displayName
  }
  
  func getPromptModelInfo() -> String {
    let selectedPromptModelString = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedPromptModel) ?? SettingsDefaults.selectedPromptModel.rawValue
    let selectedPromptModel = PromptModel(rawValue: selectedPromptModelString) ?? SettingsDefaults.selectedPromptModel
    return selectedPromptModel.displayName
  }
  
  // MARK: - Prompt Model Selection Helper
  /// Gets the selected prompt model for the given mode
  /// - Parameter mode: The prompt mode (togglePrompting or promptAndRead)
  /// - Returns: The selected PromptModel based on UserDefaults or default
  private func getPromptModel(for mode: PromptMode) -> PromptModel {
    let modelKey = mode == .togglePrompting 
      ? UserDefaultsKeys.selectedPromptModel 
      : UserDefaultsKeys.selectedPromptAndReadModel
    let defaultModel = mode == .togglePrompting 
      ? SettingsDefaults.selectedPromptModel 
      : SettingsDefaults.selectedPromptAndReadModel
    let modelString = UserDefaults.standard.string(forKey: modelKey) ?? defaultModel.rawValue
    return PromptModel(rawValue: modelString) ?? defaultModel
  }

  // MARK: - Prompt Building
  /// Returns the dictation system prompt (custom prompt only).
  private func buildDictationPrompt() -> String {
    (UserDefaults.standard.string(forKey: UserDefaultsKeys.customPromptText)
      ?? AppConstants.defaultTranscriptionSystemPrompt)
      .trimmingCharacters(in: .whitespacesAndNewlines)
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
  
  func cancelTTS() {
    DebugLogger.log("CANCELLATION: Cancelling TTS task")
    currentTTSTask?.cancel()
    currentTTSTask = nil
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
    let startTime = CFAbsoluteTimeGetCurrent()
    
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
      let savedLanguageString = UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperLanguage)
      let savedLanguage = WhisperLanguage(rawValue: savedLanguageString ?? WhisperLanguage.auto.rawValue) ?? WhisperLanguage.auto
      let languageString = savedLanguage.languageCode // Returns nil for .auto, which enables auto-detect
      
      if savedLanguage == .auto {
        DebugLogger.log("LOCAL-SPEECH: Using auto-detect language (default)")
      } else {
        DebugLogger.log("LOCAL-SPEECH: Using language setting: \(savedLanguage.displayName) (\(savedLanguage.rawValue))")
      }
      
      // Transcribe using local service
      let result = try await LocalSpeechService.shared.transcribe(audioURL: audioURL, language: languageString)
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.log("SPEED: Whisper transcription completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
      return result
    }
    
    // Check if using Gemini model
    if selectedTranscriptionModel.isGemini {
      // For Gemini, validate format but not size (Gemini supports up to 9.5 hours)
      try validateAudioFileFormat(at: audioURL)
      let result = try await transcribeWithGemini(audioURL: audioURL)
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.log("SPEED: Gemini transcription completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
      return result
    }
    
    // Should never reach here
    throw TranscriptionError.networkError("Unsupported transcription model")
  }
  

  // MARK: - Prompt Modes (Public API with Task Tracking)
  func executePrompt(audioURL: URL, mode: PromptMode = .togglePrompting) async throws -> String {
    // Create and store task for cancellation support
    let task = Task<String, Error> {
      try await self.performPrompt(audioURL: audioURL, mode: mode)
    }
    
    currentPromptTask = task
    defer { currentPromptTask = nil }
    
    return try await task.value
  }

  // MARK: - Prompt Modes (Private Implementation)
  private func performPrompt(audioURL: URL, mode: PromptMode) async throws -> String {
    // Get clipboard context
    let clipboardContext = getClipboardContext()
    
    // Get selected model from settings based on mode
    let selectedPromptModel = getPromptModel(for: mode)
    
    // Prompt mode ALWAYS requires Gemini API key (no offline support yet)
    // All PromptModel cases are Gemini models, so this should always be true
    guard selectedPromptModel.isGemini else {
      throw TranscriptionError.networkError("Prompt mode requires Gemini model")
    }
    
    // For Gemini, validate format but not size (Gemini supports up to 9.5 hours)
    try validateAudioFileFormat(at: audioURL)
    // Execute prompt with Gemini (it handles its own key validation)
    return try await executePromptWithGemini(audioURL: audioURL, clipboardContext: clipboardContext, mode: mode)
  }

  // MARK: - Gemini Prompt Mode
  private func executePromptWithGemini(audioURL: URL, clipboardContext: String?, mode: PromptMode) async throws -> String {
    // Only check API key for Gemini models (offline models bypass this)
    guard let googleAPIKey = self.googleAPIKey, !googleAPIKey.isEmpty else {
      throw TranscriptionError.noGoogleAPIKey
    }

    DebugLogger.log("PROMPT-MODE-GEMINI: Starting execution (mode: \(mode == .togglePrompting ? "Toggle Prompting" : "Prompt & Read"))")

    // Run transcription for history in parallel with main prompt (no extra latency)
    let transcriptionTask = Task<String, Never> {
      do {
        let text = try await transcribeAudioForHistory(audioURL: audioURL, apiKey: googleAPIKey)
        DebugLogger.log("PROMPT-MODE-GEMINI: Transcribed voice instruction for history: \"\(text.prefix(50))...\"")
        return text
      } catch {
        DebugLogger.logWarning("PROMPT-MODE-GEMINI: Failed to transcribe instruction for history: \(error.localizedDescription)")
        return "(voice instruction)"
      }
    }

    // Get selected model from settings based on mode
    let selectedPromptModel = getPromptModel(for: mode)

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

    // Build system prompt based on mode
    let baseSystemPrompt = mode == .togglePrompting
      ? AppConstants.defaultPromptModeSystemPrompt
      : AppConstants.defaultPromptAndReadSystemPrompt
    let promptKey = mode == .togglePrompting ? UserDefaultsKeys.promptModeSystemPrompt : UserDefaultsKeys.promptAndReadSystemPrompt
    let customSystemPrompt = UserDefaults.standard.string(forKey: promptKey)

    var systemPrompt: String
    if let customPrompt = customSystemPrompt, !customPrompt.isEmpty {
      systemPrompt = customPrompt
      DebugLogger.log("PROMPT-MODE-GEMINI: Using custom system prompt")
    } else {
      systemPrompt = baseSystemPrompt
      DebugLogger.log("PROMPT-MODE-GEMINI: Using base system prompt")
    }

    // Append user context if available
    if let userContext = UserContextLogger.shared.loadUserContext() {
      systemPrompt += "\n\n---\nUser context:\n" + userContext
      DebugLogger.log("PROMPT-MODE-GEMINI: Appended user context to system prompt")
    }

    // Always require raw output only (no meta), regardless of custom prompt
    systemPrompt += AppConstants.promptModeOutputRule

    // Build request
    var request = try geminiClient.createRequest(endpoint: endpoint, apiKey: googleAPIKey)

    // Build contents array - start with conversation history
    let historyContents = PromptConversationHistory.shared.getContentsForAPI(mode: mode)
    var contents: [GeminiChatRequest.GeminiChatContent] = historyContents

    let historyCount = historyContents.count / 2  // Each turn = 2 messages (user + model)
    if historyCount > 0 {
      DebugLogger.log("PROMPT-MODE-GEMINI: Including \(historyCount) previous turns from conversation history")
    }

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
    let mimeType = geminiClient.getMimeType(for: fileExtension)

    if audioSize > AppConstants.maxFileSizeBytes {
      // Use Files API for large files
      let fileURI = try await geminiClient.uploadFile(audioURL: audioURL, apiKey: googleAPIKey)
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
      generationConfig: nil,
      model: nil
    )

    request.httpBody = try JSONEncoder().encode(chatRequest)

    // Make request
    let result = try await geminiClient.performRequest(
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

    // Append to conversation history (use transcription result from parallel task, with timeout so we never block)
    let userInstruction: String
    var historyTranscriptionResult: String?
    await withTaskGroup(of: String?.self) { group in
      group.addTask { await transcriptionTask.value }
      group.addTask {
        try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
        return nil
      }
      for await value in group {
        if historyTranscriptionResult == nil {
          historyTranscriptionResult = value
          group.cancelAll()
        }
      }
    }
    userInstruction = historyTranscriptionResult ?? "(voice instruction)"
    if historyTranscriptionResult == nil {
      DebugLogger.logWarning("PROMPT-MODE-GEMINI: History transcription timed out, using placeholder")
    }
    PromptConversationHistory.shared.append(
      mode: mode,
      selectedText: clipboardContext,
      userInstruction: userInstruction,
      modelResponse: normalizedText
    )
    UserContextLogger.shared.logPrompt(mode: mode, selectedText: clipboardContext, userInstruction: userInstruction, modelResponse: normalizedText)

    DebugLogger.logSuccess("PROMPT-MODE-GEMINI: Completed successfully")

    return normalizedText
  }

  /// Transcribes audio to text for use in conversation history.
  /// Uses a lightweight transcription call to get the user's voice instruction as text.
  private func transcribeAudioForHistory(audioURL: URL, apiKey: String) async throws -> String {
    // Use the existing transcription logic but with a simpler prompt
    let audioData = try Data(contentsOf: audioURL)
    let base64Audio = audioData.base64EncodedString()
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = geminiClient.getMimeType(for: fileExtension)

    // Use Gemini Flash for fast, cheap transcription (full URL required by createRequest)
    let endpoint = TranscriptionModel.gemini20Flash.apiEndpoint
    var request = try geminiClient.createRequest(endpoint: endpoint, apiKey: apiKey)

    let userParts: [GeminiChatRequest.GeminiChatPart] = [
      GeminiChatRequest.GeminiChatPart(
        text: nil,
        inlineData: GeminiChatRequest.GeminiInlineData(mimeType: mimeType, data: base64Audio),
        fileData: nil,
        url: nil
      )
    ]

    let systemInstruction = GeminiChatRequest.GeminiSystemInstruction(
      parts: [GeminiChatRequest.GeminiSystemPart(text: "Transcribe this audio exactly. Return only the transcribed text, nothing else.")]
    )

    let chatRequest = GeminiChatRequest(
      contents: [GeminiChatRequest.GeminiChatContent(role: "user", parts: userParts)],
      systemInstruction: systemInstruction,
      tools: nil,
      generationConfig: nil,
      model: nil
    )

    request.httpBody = try JSONEncoder().encode(chatRequest)

    let result = try await geminiClient.performRequest(
      request,
      responseType: GeminiChatResponse.self,
      mode: "PROMPT-HISTORY-TRANSCRIBE",
      withRetry: false
    )

    guard let firstCandidate = result.candidates.first,
          let text = firstCandidate.content.parts.first?.text else {
      throw TranscriptionError.networkError("No transcription in response")
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  
  // MARK: - Text-based Prompt Mode (for TTS flow)
  func executePromptWithText(textCommand: String, selectedText: String?, mode: PromptMode = .togglePrompting) async throws -> String {
    // Only check API key for Gemini models
    guard let googleAPIKey = self.googleAPIKey, !googleAPIKey.isEmpty else {
      throw TranscriptionError.noGoogleAPIKey
    }

    let hasSelectedText = selectedText != nil && !selectedText!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    DebugLogger.log("PROMPT-MODE-TEXT: Starting execution with text command (mode: \(mode == .togglePrompting ? "Toggle Prompting" : "Prompt & Read"), hasSelectedText: \(hasSelectedText))")

    // Get selected model from settings based on mode
    let selectedPromptModel = getPromptModel(for: mode)

    // Convert to TranscriptionModel to get API endpoint
    guard let transcriptionModel = selectedPromptModel.asTranscriptionModel else {
      throw TranscriptionError.networkError("Selected model is not a Gemini model")
    }

    let endpoint = transcriptionModel.apiEndpoint
    DebugLogger.log("PROMPT-MODE-TEXT: Using model: \(selectedPromptModel.displayName)")

    // Build system prompt based on mode
    let baseSystemPrompt = mode == .togglePrompting
      ? AppConstants.defaultPromptModeSystemPrompt
      : AppConstants.defaultPromptAndReadSystemPrompt
    let promptKey = mode == .togglePrompting ? UserDefaultsKeys.promptModeSystemPrompt : UserDefaultsKeys.promptAndReadSystemPrompt
    let customSystemPrompt = UserDefaults.standard.string(forKey: promptKey)

    var systemPrompt: String
    if let customPrompt = customSystemPrompt, !customPrompt.isEmpty {
      systemPrompt = customPrompt
    } else {
      systemPrompt = baseSystemPrompt
    }

    // Append user context if available
    if let userContext = UserContextLogger.shared.loadUserContext() {
      systemPrompt += "\n\n---\nUser context:\n" + userContext
      DebugLogger.log("PROMPT-MODE-TEXT: Appended user context to system prompt")
    }

    // Always require raw output only (no meta), regardless of custom prompt
    systemPrompt += AppConstants.promptModeOutputRule

    // Build request
    var request = try geminiClient.createRequest(endpoint: endpoint, apiKey: googleAPIKey)

    // Build contents array - start with conversation history
    let historyContents = PromptConversationHistory.shared.getContentsForAPI(mode: mode)
    var contents: [GeminiChatRequest.GeminiChatContent] = historyContents

    let historyCount = historyContents.count / 2  // Each turn = 2 messages (user + model)
    if historyCount > 0 {
      DebugLogger.log("PROMPT-MODE-TEXT: Including \(historyCount) previous turns from conversation history")
    }

    // Build current user message parts
    var userParts: [GeminiChatRequest.GeminiChatPart] = []

    // Add clipboard context if present (so Gemini knows what to apply the instruction to)
    if let text = selectedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let contextText = """
      SELECTED TEXT FROM CLIPBOARD (apply the voice instruction to this text):

      \(text)
      """
      userParts.append(GeminiChatRequest.GeminiChatPart(text: contextText, inlineData: nil, fileData: nil, url: nil))
    }

    // Add voice instruction
    let commandText = """
    VOICE INSTRUCTION\(hasSelectedText ? " (what to do with the selected text)" : ""):

    \(textCommand)
    """
    userParts.append(GeminiChatRequest.GeminiChatPart(text: commandText, inlineData: nil, fileData: nil, url: nil))

    // Add current user message
    contents.append(
      GeminiChatRequest.GeminiChatContent(
        role: "user",
        parts: userParts
      )
    )

    // Build system instruction
    let systemInstruction = GeminiChatRequest.GeminiSystemInstruction(
      parts: [GeminiChatRequest.GeminiSystemPart(text: systemPrompt)]
    )

    // Create request
    let chatRequest = GeminiChatRequest(
      contents: contents,
      systemInstruction: systemInstruction,
      tools: nil,
      generationConfig: nil,
      model: nil
    )

    request.httpBody = try JSONEncoder().encode(chatRequest)

    // Make request
    let result = try await geminiClient.performRequest(
      request,
      responseType: GeminiChatResponse.self,
      mode: "PROMPT-MODE-TEXT",
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
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "PROMPT-MODE-TEXT")

    // Append to conversation history for follow-up prompts
    PromptConversationHistory.shared.append(
      mode: mode,
      selectedText: selectedText,
      userInstruction: textCommand,
      modelResponse: normalizedText
    )
    UserContextLogger.shared.logPrompt(mode: mode, selectedText: selectedText, userInstruction: textCommand, modelResponse: normalizedText)

    DebugLogger.logSuccess("PROMPT-MODE-TEXT: Completed successfully")

    return normalizedText
  }
  
  // MARK: - Text-to-Speech Mode
  func readTextAloud(_ text: String, voiceName: String? = nil) async throws -> Data {
    // Create and store task for cancellation support
    let task = Task<Data, Error> {
      try await self.performTTS(text: text, voiceName: voiceName)
    }
    
    currentTTSTask = task
    defer { currentTTSTask = nil }
    
    return try await task.value
  }
  
  private func performTTS(text: String, voiceName: String? = nil) async throws -> Data {
    guard let googleAPIKey = googleAPIKey else {
      throw TranscriptionError.noGoogleAPIKey
    }
    
    // Validate input text
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      throw TranscriptionError.networkError("Text is empty")
    }
    
    // Load voice from UserDefaults if not provided
    let selectedVoice = voiceName ?? UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedReadAloudVoice) ?? SettingsDefaults.selectedReadAloudVoice
    
    // Load TTS model from UserDefaults
    let selectedTTSModel: TTSModel
    if let savedTTSModelString = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedTTSModel),
       let savedTTSModel = TTSModel(rawValue: savedTTSModelString) {
      selectedTTSModel = savedTTSModel
    } else {
      selectedTTSModel = SettingsDefaults.selectedTTSModel
    }
    
    DebugLogger.log("TTS: Starting text-to-speech for text (length: \(trimmedText.count) chars) with voice: \(selectedVoice), model: \(selectedTTSModel.displayName)")
    
    // Check if text needs chunking
    let chunker = TextChunker()
    if chunker.needsChunking(trimmedText) {
      DebugLogger.log("TTS: Using chunked synthesis (text length > \(AppConstants.ttsChunkSizeChars) chars)")
      let chunkService = ChunkTTSService()
      chunkService.progressDelegate = chunkProgressDelegate
      return try await chunkService.synthesize(
        text: trimmedText,
        voiceName: selectedVoice,
        apiKey: googleAPIKey,
        model: selectedTTSModel
      )
    } else {
      DebugLogger.log("TTS: Using single-request synthesis (text length <= \(AppConstants.ttsChunkSizeChars) chars)")
    }
    
    // TTS-specific endpoint from selected model
    let endpoint = selectedTTSModel.apiEndpoint
    
    // Build request
    var request = try geminiClient.createRequest(endpoint: endpoint, apiKey: googleAPIKey)
    
    // Build contents with text input
    let contents = [
      GeminiChatRequest.GeminiChatContent(
        role: "user",
        parts: [
          GeminiChatRequest.GeminiChatPart(
            text: trimmedText,
            inlineData: nil,
            fileData: nil,
            url: nil
          )
        ]
      )
    ]
    
    // Build generation config with audio output
    let generationConfig = GeminiChatRequest.GeminiGenerationConfig(
      responseModalities: ["AUDIO"],
      speechConfig: GeminiChatRequest.GeminiSpeechConfig(
        voiceConfig: GeminiChatRequest.GeminiVoiceConfig(
          prebuiltVoiceConfig: GeminiChatRequest.GeminiPrebuiltVoiceConfig(
            voiceName: selectedVoice
          )
        )
      )
    )
    
    // Create request
    let chatRequest = GeminiChatRequest(
      contents: contents,
      systemInstruction: nil,
      tools: nil,
      generationConfig: generationConfig,
      model: selectedTTSModel.modelName  // Required for TTS models
    )
    
    request.httpBody = try JSONEncoder().encode(chatRequest)
    
    DebugLogger.log("TTS: Making request to Gemini TTS API (text length: \(trimmedText.count) chars)")
    
    // Make request with retry logic (helps with network issues)
    let result = try await geminiClient.performRequest(
      request,
      responseType: GeminiChatResponse.self,
      mode: "TTS",
      withRetry: true
    )
    
    DebugLogger.log("TTS: Received response from Gemini API")
    
    guard let firstCandidate = result.candidates.first else {
      DebugLogger.logError("TTS: No candidates in response")
      throw TranscriptionError.networkError("No candidates in Gemini TTS response")
    }
    
    DebugLogger.log("TTS: Found \(result.candidates.count) candidate(s)")
    DebugLogger.log("TTS: Candidate has \(firstCandidate.content.parts.count) part(s)")
    
    // Extract audio data from response
    for (index, part) in firstCandidate.content.parts.enumerated() {
      DebugLogger.log("TTS: Checking part \(index): has text=\(part.text != nil), has inlineData=\(part.inlineData != nil)")
      
      if let inlineData = part.inlineData {
        DebugLogger.log("TTS: Found inlineData with mimeType=\(inlineData.mimeType), data length=\(inlineData.data.count) chars")
        
        // Decode base64 audio data
        guard let audioData = Data(base64Encoded: inlineData.data) else {
          DebugLogger.logError("TTS: Failed to decode base64 audio data (data length: \(inlineData.data.count) chars)")
          throw TranscriptionError.networkError("Failed to decode base64 audio data")
        }
        
        DebugLogger.logSuccess("TTS: Successfully generated audio (size: \(audioData.count) bytes)")
        return audioData
      }
      
      if let text = part.text {
        DebugLogger.log("TTS: Part \(index) contains text instead of audio: \(text.prefix(100))")
      }
    }
    
    DebugLogger.logError("TTS: No audio data found in any part of the response")
    throw TranscriptionError.networkError("No audio data found in TTS response")
  }

  // MARK: - Gemini API Helpers (delegated to GeminiAPIClient)

  // MARK: - Gemini Transcription
  private func transcribeWithGemini(audioURL: URL) async throws -> String {
    let apiStartTime = CFAbsoluteTimeGetCurrent()

    // Only check API key for Gemini models (offline models bypass this)
    guard keychainManager.hasValidGoogleAPIKey(),
          let apiKey = self.googleAPIKey else {
      DebugLogger.log("GEMINI-TRANSCRIPTION: ERROR - No Google API key found in keychain")
      throw TranscriptionError.noGoogleAPIKey
    }

    // Log API key status (without exposing the key itself)
    let keyPrefix = String(apiKey.prefix(8))
    let keyLength = apiKey.count
    DebugLogger.log("GEMINI-TRANSCRIPTION: Google API key found (prefix: \(keyPrefix)..., length: \(keyLength) chars)")

    // Only validate format, not size - Gemini handles large files via:
    // 1. Chunking for long audio (>45s)
    // 2. Files API for large files (>20MB)
    try validateAudioFileFormat(at: audioURL)

    let audioSize = getAudioFileSize(at: audioURL)
    DebugLogger.log("GEMINI-TRANSCRIPTION: Starting transcription, file size: \(audioSize) bytes")

    // Check audio duration for chunking decision
    let audioDuration = try await getAudioDuration(audioURL)
    DebugLogger.log("GEMINI-TRANSCRIPTION: Audio duration: \(String(format: "%.1f", audioDuration))s")

    let result: String

    // Use chunking for long audio (>45s by default)
    if audioDuration > AppConstants.chunkingThresholdSeconds {
      DebugLogger.log("GEMINI-TRANSCRIPTION: Using chunked transcription (duration > \(AppConstants.chunkingThresholdSeconds)s)")
      result = try await transcribeWithChunking(audioURL: audioURL, apiKey: apiKey)
    }
    // For files >20MB, use Files API (resumable upload)
    // For files ≤20MB, use inline base64
    // DEBUG: Can force Files API usage via Constants.debugForceFilesAPI
    else if Constants.debugForceFilesAPI {
      DebugLogger.log("GEMINI-TRANSCRIPTION: DEBUG - Forcing Files API usage (debugForceFilesAPI = true)")
      result = try await transcribeWithGeminiFilesAPI(audioURL: audioURL, apiKey: apiKey)
    } else if audioSize > AppConstants.maxFileSizeBytes {
      result = try await transcribeWithGeminiFilesAPI(audioURL: audioURL, apiKey: apiKey)
    } else {
      result = try await transcribeWithGeminiInline(audioURL: audioURL, apiKey: apiKey)
    }

    let apiElapsedTime = CFAbsoluteTimeGetCurrent() - apiStartTime
    DebugLogger.log("SPEED: Gemini API call completed in \(String(format: "%.3f", apiElapsedTime))s (\(String(format: "%.0f", apiElapsedTime * 1000))ms)")

    return result
  }

  // MARK: - Chunked Transcription
  private func transcribeWithChunking(audioURL: URL, apiKey: String) async throws -> String {
    let chunkService = ChunkTranscriptionService(geminiClient: geminiClient)
    chunkService.progressDelegate = chunkProgressDelegate

    let prompt = buildDictationPrompt()

    return try await chunkService.transcribe(
      fileURL: audioURL,
      apiKey: apiKey,
      model: selectedTranscriptionModel,
      prompt: prompt
    )
  }

  // MARK: - Audio Duration Helper
  private func getAudioDuration(_ url: URL) async throws -> TimeInterval {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    return CMTimeGetSeconds(duration)
  }
  
  private func transcribeWithGeminiInline(audioURL: URL, apiKey: String) async throws -> String {
    let inlineStartTime = CFAbsoluteTimeGetCurrent()
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using inline audio (file ≤20MB)")
    
    // Read audio file and convert to base64
    let encodeStartTime = CFAbsoluteTimeGetCurrent()
    let audioData = try Data(contentsOf: audioURL)
    let base64Audio = audioData.base64EncodedString()
    let encodeTime = CFAbsoluteTimeGetCurrent() - encodeStartTime
    DebugLogger.log("SPEED: Base64 encoding took \(String(format: "%.3f", encodeTime))s (\(String(format: "%.0f", encodeTime * 1000))ms)")
    
    // Determine MIME type from file extension
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = geminiClient.getMimeType(for: fileExtension)
    
    // Get dictation system prompt
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
    
    var request = try geminiClient.createRequest(endpoint: endpoint, apiKey: apiKey)
    request.httpBody = try JSONEncoder().encode(transcriptionRequest)
    
    // Make request with retry logic
    let networkStartTime = CFAbsoluteTimeGetCurrent()
    let geminiResponse = try await geminiClient.performRequest(
      request,
      responseType: GeminiResponse.self,
      mode: "GEMINI-TRANSCRIPTION",
      withRetry: true
    )
    let networkTime = CFAbsoluteTimeGetCurrent() - networkStartTime
    DebugLogger.log("SPEED: Gemini API network request took \(String(format: "%.3f", networkTime))s (\(String(format: "%.0f", networkTime * 1000))ms)")
    
    let transcript = geminiClient.extractText(from: geminiResponse)
    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(transcript)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "TRANSCRIPTION-MODE")
    
    let inlineElapsedTime = CFAbsoluteTimeGetCurrent() - inlineStartTime
    DebugLogger.log("SPEED: Gemini inline transcription total time: \(String(format: "%.3f", inlineElapsedTime))s (\(String(format: "%.0f", inlineElapsedTime * 1000))ms)")
    
    return normalizedText
  }
  
  private func transcribeWithGeminiFilesAPI(audioURL: URL, apiKey: String) async throws -> String {
    let filesAPIStartTime = CFAbsoluteTimeGetCurrent()
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using Files API (file >20MB)")
    
    // Step 1: Upload file using resumable upload
    let uploadStartTime = CFAbsoluteTimeGetCurrent()
    let fileURI = try await geminiClient.uploadFile(audioURL: audioURL, apiKey: apiKey)
    let uploadTime = CFAbsoluteTimeGetCurrent() - uploadStartTime
    DebugLogger.log("SPEED: File upload took \(String(format: "%.3f", uploadTime))s (\(String(format: "%.0f", uploadTime * 1000))ms)")
    
    // Step 2: Use file URI for transcription
    let result = try await transcribeWithGeminiFileURI(fileURI: fileURI, apiKey: apiKey)
    
    let filesAPIElapsedTime = CFAbsoluteTimeGetCurrent() - filesAPIStartTime
    DebugLogger.log("SPEED: Gemini Files API transcription total time: \(String(format: "%.3f", filesAPIElapsedTime))s (\(String(format: "%.0f", filesAPIElapsedTime * 1000))ms)")
    
    return result
  }
  
  // File upload is now handled by GeminiAPIClient
  
  private func transcribeWithGeminiFileURI(fileURI: String, apiKey: String) async throws -> String {
    let fileURIStartTime = CFAbsoluteTimeGetCurrent()
    
    // Get dictation system prompt
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
    
    var request = try geminiClient.createRequest(endpoint: endpoint, apiKey: apiKey)
    request.httpBody = try JSONEncoder().encode(transcriptionRequest)
    
    // Make request with retry logic
    let networkStartTime = CFAbsoluteTimeGetCurrent()
    let geminiResponse = try await geminiClient.performRequest(
      request,
      responseType: GeminiResponse.self,
      mode: "GEMINI-TRANSCRIPTION",
      withRetry: true
    )
    let networkTime = CFAbsoluteTimeGetCurrent() - networkStartTime
    DebugLogger.log("SPEED: Gemini API network request (FileURI) took \(String(format: "%.3f", networkTime))s (\(String(format: "%.0f", networkTime * 1000))ms)")
    
    let transcript = geminiClient.extractText(from: geminiResponse)
    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(transcript)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "TRANSCRIPTION-MODE")
    
    let fileURIElapsedTime = CFAbsoluteTimeGetCurrent() - fileURIStartTime
    DebugLogger.log("SPEED: Gemini FileURI transcription took \(String(format: "%.3f", fileURIElapsedTime))s (\(String(format: "%.0f", fileURIElapsedTime * 1000))ms)")
    
    return normalizedText
  }
  
  // MIME type, text extraction, and error parsing are now handled by GeminiAPIClient

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

    if fileSize > AppConstants.maxFileSizeBytes {
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
  
  /// Returns audio duration in seconds, or nil if duration could not be determined.
  /// Used by isAudioLikelyEmpty and by recording safeguard (confirm above duration).
  func getAudioDuration(url: URL) -> TimeInterval? {
    do {
      let audioFile = try AVAudioFile(forReading: url)
      let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
      DebugLogger.logDebug("AUDIO-CHECK: getAudioDuration \(String(format: "%.2f", duration))s at \(url.lastPathComponent)")
      return duration
    } catch {
      DebugLogger.logWarning("AUDIO-CHECK: Could not get audio duration: \(error.localizedDescription)")
      return nil
    }
  }

  func isAudioLikelyEmpty(at url: URL) -> Bool {
    guard let duration = getAudioDuration(url: url) else { return false }
    let isEmpty = duration < 0.5
    if isEmpty {
      DebugLogger.log("AUDIO-CHECK: Audio too short (\(String(format: "%.2f", duration))s < 0.5s), treating as empty")
    }
    return isEmpty
  }

  // Status code error parsing is now handled by GeminiAPIClient
}



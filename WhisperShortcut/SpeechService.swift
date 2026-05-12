import AVFoundation
import Foundation
import NaturalLanguage

// MARK: - Prompt Mode Enum
enum PromptMode {
  case togglePrompting
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
  private let credentialProvider: GeminiCredentialProviding
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
    credentialProvider: GeminiCredentialProviding = GeminiCredentialProvider.shared,
    clipboardManager: ClipboardManager? = nil,
    geminiClient: GeminiAPIClient? = nil
  ) {
    self.keychainManager = keychainManager
    self.credentialProvider = credentialProvider
    self.clipboardManager = clipboardManager
    self.geminiClient = geminiClient ?? GeminiAPIClient()
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
    let normalized = PromptModel.migrateLegacyPromptRawValue(selectedPromptModelString)
    let selectedPromptModel = PromptModel(rawValue: normalized) ?? SettingsDefaults.selectedPromptModel
    return selectedPromptModel.displayName
  }
  
  // MARK: - Prompt Model Selection Helper
  /// Gets the selected prompt model. When on subscription (proxy), always returns stable Gemini 2.5 Flash.
  /// - Returns: The selected PromptModel based on UserDefaults or default; subscription uses stable model only
  private func getPromptModel(for mode: PromptMode) -> PromptModel {
    let defaultModel = SettingsDefaults.selectedPromptModel
    let modelString = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedPromptModel) ?? defaultModel.rawValue
    let normalized = PromptModel.migrateLegacyPromptRawValue(modelString)
    return PromptModel(rawValue: normalized) ?? defaultModel
  }

  // MARK: - Prompt Building
  /// Returns the dictation system prompt (custom prompt only).
  private func buildDictationPrompt() -> String {
    SystemPromptsStore.shared.loadDictationPrompt()
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
  /// - Parameters:
  ///   - preferredModel: If set (e.g. for live meeting), use this model; otherwise use the global Dictate selection.
  ///   - promptOverride: If set, use this prompt instead of the user's dictation prompt.
  func transcribe(audioURL: URL, preferredModel: TranscriptionModel? = nil, promptOverride: String? = nil) async throws -> String {
    // Create and store task for cancellation support
    let task = Task<String, Error> {
      try await self.performTranscription(audioURL: audioURL, preferredModel: preferredModel, promptOverride: promptOverride)
    }
    
    currentTranscriptionTask = task
    defer { currentTranscriptionTask = nil }
    
    return try await task.value
  }

  // MARK: - Transcription Mode (Private Implementation)
  private func performTranscription(audioURL: URL, preferredModel: TranscriptionModel? = nil, promptOverride: String? = nil) async throws -> String {
    let startTime = CFAbsoluteTimeGetCurrent()
    let model = preferredModel ?? TranscriptionModel.loadSelected()

    // Check if using offline model
    if model.isOffline {
      // For offline models, use LocalSpeechService
      guard let offlineModelType = model.offlineModelType else {
        throw TranscriptionError.networkError("Invalid offline model type")
      }

      // Check if model is available before attempting to use it
      if !ModelManager.shared.isModelAvailable(offlineModelType) {
        throw TranscriptionError.modelNotAvailable(offlineModelType)
      }

      // Use the selected model: initialize if not ready, or re-initialize if a different model is loaded (e.g. pre-loaded Large but user selected Base)
      if await !LocalSpeechService.shared.isLoaded(modelType: offlineModelType) {
        try await LocalSpeechService.shared.initializeModel(offlineModelType)
      }
      try Task.checkCancellation()

      // Validate format
      try validateAudioFileFormat(at: audioURL)
      try Task.checkCancellation()

      // Get language setting for Whisper (defaults to auto-detect)
      let savedLanguageString = UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperLanguage)
      let savedLanguage = WhisperLanguage(rawValue: savedLanguageString ?? WhisperLanguage.auto.rawValue) ?? WhisperLanguage.auto
      let languageString = savedLanguage.languageCode // Returns nil for .auto, which enables auto-detect

      if savedLanguage == .auto {
        DebugLogger.log("LOCAL-SPEECH: Using auto-detect language (default)")
      } else {
        DebugLogger.log("LOCAL-SPEECH: Using language setting: \(savedLanguage.displayName) (\(savedLanguage.rawValue))")
      }

      // Pass Whisper Glossary for offline conditioning (nil when empty)
      let whisperGlossary = SystemPromptsStore.shared.loadWhisperGlossary().trimmingCharacters(in: .whitespacesAndNewlines)
      let whisperPrompt: String? = whisperGlossary.isEmpty ? nil : whisperGlossary

      // Transcribe using local service
      let result = try await LocalSpeechService.shared.transcribe(audioURL: audioURL, language: languageString, prompt: whisperPrompt)
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.logSpeech("SPEED: Whisper transcription completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
      return result
    }

    // Check if using Gemini model
    if model.isGemini {
      // For Gemini, validate format but not size (Gemini supports up to 9.5 hours)
      try validateAudioFileFormat(at: audioURL)
      let result = try await transcribeWithGemini(audioURL: audioURL, model: model, promptOverride: promptOverride)
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.logSpeech("SPEED: [\(model.displayName)] transcription completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
      return result
    }

    // OpenAI cloud transcription (gpt-4o-transcribe / gpt-4o-mini-transcribe)
    if model.isOpenAI, let openAIModelID = model.openAIAPIModelID {
      try validateAudioFileFormat(at: audioURL)
      let result = try await transcribeWithOpenAI(audioURL: audioURL, modelID: openAIModelID, displayName: model.displayName)
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.logSpeech("SPEED: [\(model.displayName)] transcription completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
      return result
    }

    // Self-hosted OpenAI-compatible endpoint
    if model == .selfHostedTranscription {
      try validateAudioFileFormat(at: audioURL)
      let result = try await transcribeWithSelfHostedEndpoint(audioURL: audioURL)
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.logSpeech("SPEED: [Self-hosted Transcription] completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
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

    guard selectedPromptModel.supportsDirectAudioInput else {
      throw TranscriptionError.networkError("Selected Dictate Prompt model does not accept direct audio input. Pick a Gemini model or OpenAI's GPT-4o Audio.")
    }

    try validateAudioFileFormat(at: audioURL)

    switch selectedPromptModel.provider {
    case .gemini:
      return try await executePromptWithGemini(audioURL: audioURL, clipboardContext: clipboardContext, mode: mode)
    case .openai:
      return try await executePromptWithOpenAI(audioURL: audioURL, clipboardContext: clipboardContext, mode: mode, model: selectedPromptModel)
    case .grok:
      throw TranscriptionError.networkError("Grok does not support audio-input Dictate Prompt. Pick a Gemini model or OpenAI's GPT-4o Audio.")
    }
  }

  // MARK: - Gemini Prompt Mode
  private func executePromptWithGemini(audioURL: URL, clipboardContext: String?, mode: PromptMode) async throws -> String {
    guard let credential = await credentialProvider.getCredential() else {
      throw TranscriptionError.noGoogleAPIKey
    }

    DebugLogger.log("PROMPT-MODE-GEMINI: Starting execution")

    // Run transcription for history in parallel with main prompt (no extra latency)
    let transcriptionTask = Task<String, Never> {
      do {
        let text = try await transcribeAudioForHistory(audioURL: audioURL, credential: credential)
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

    // Build system prompt
    let systemPromptBase = SystemPromptsStore.shared.loadDictatePromptSystemPrompt()
    var systemPrompt = systemPromptBase.trimmingCharacters(in: .whitespacesAndNewlines)
    if systemPrompt.isEmpty {
      systemPrompt = AppConstants.defaultPromptModeSystemPrompt
      DebugLogger.log("PROMPT-MODE-GEMINI: Using base system prompt")
    } else {
      DebugLogger.log("PROMPT-MODE-GEMINI: Using custom system prompt")
    }

    // Always require raw output only (no meta), regardless of custom prompt
    systemPrompt += AppConstants.promptModeOutputRule

    let (resolvedEndpoint, resolvedCredential) = GeminiAPIClient.resolveGenerateContentEndpoint(directEndpoint: endpoint, credential: credential)
    let credentialForRequest = await GeminiAPIClient.resolveCredentialForRequest(endpoint: resolvedEndpoint, resolvedCredential: resolvedCredential)
    var request = try geminiClient.createRequest(endpoint: resolvedEndpoint, credential: credentialForRequest)

    // Build contents array - start with conversation history
    let historyContents = PromptConversationHistory.shared.getContentsForAPI(mode: mode)
    var contents: [GeminiChatRequest.GeminiChatContent] = historyContents

    let historyCount = historyContents.count / 2  // Each turn = 2 messages (user + model)
    if historyCount > 0 {
      DebugLogger.log("PROMPT-MODE-GEMINI: Including \(historyCount) previous turns from conversation history")
    }

    // Capture screenshot for prompt context if enabled (best-effort; continues without image on failure)
    let screenshotData: Data? = screenshotInPromptModeEnabled()
      ? await ChatWindowManager.shared.captureScreenForPromptMode()
      : nil

    // Build current user message parts
    var userParts: [GeminiChatRequest.GeminiChatPart] = []

    // Add screenshot as first part so Gemini has visual context
    if let screenshotData {
      let base64Screenshot = screenshotData.base64EncodedString()
      userParts.append(GeminiChatRequest.GeminiChatPart(text: "Current screen:", inlineData: nil, fileData: nil, url: nil))
      userParts.append(GeminiChatRequest.GeminiChatPart(
        text: nil,
        inlineData: GeminiChatRequest.GeminiInlineData(mimeType: "image/jpeg", data: base64Screenshot),
        fileData: nil,
        url: nil
      ))
    }

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
      let fileURI = try await geminiClient.uploadFile(audioURL: audioURL, credential: credential)
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
      withRetry: true
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
    ContextLogger.shared.logPrompt(mode: mode, selectedText: clipboardContext, userInstruction: userInstruction, modelResponse: normalizedText)

    DebugLogger.logSuccess("PROMPT-MODE-GEMINI: Completed successfully")

    return normalizedText
  }

  // MARK: - OpenAI Prompt Mode

  /// Dictate Prompt via OpenAI's Chat Completions API with an inline `input_audio` content
  /// part. Mirrors the Gemini flow: system prompt + optional screenshot + clipboard context +
  /// audio, all in one request. Non-streaming, single-shot response.
  /// Reference: https://platform.openai.com/docs/guides/audio
  private func executePromptWithOpenAI(
    audioURL: URL,
    clipboardContext: String?,
    mode: PromptMode,
    model: PromptModel
  ) async throws -> String {
    guard let apiKey = keychainManager.getOpenAIAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !apiKey.isEmpty else {
      throw TranscriptionError.networkError("No OpenAI API key configured. Add your OpenAI API key in Settings to use OpenAI's Dictate Prompt models.")
    }

    DebugLogger.log("PROMPT-MODE-OPENAI: Starting execution model=\(model.rawValue)")

    // Run transcription for history in parallel (mirrors the Gemini path). Uses the cheap
    // gpt-4o-mini-transcribe so it doesn't require a Gemini key.
    let transcriptionTask = Task<String, Never> {
      do {
        let text = try await transcribeWithOpenAI(
          audioURL: audioURL,
          modelID: "gpt-4o-mini-transcribe",
          displayName: "GPT-4o Mini Transcribe"
        )
        DebugLogger.log("PROMPT-MODE-OPENAI: Transcribed voice instruction for history: \"\(text.prefix(50))...\"")
        return text
      } catch {
        DebugLogger.logWarning("PROMPT-MODE-OPENAI: Failed to transcribe instruction for history: \(error.localizedDescription)")
        return "(voice instruction)"
      }
    }

    // Build system prompt (same composition as the Gemini path).
    var systemPrompt = SystemPromptsStore.shared.loadDictatePromptSystemPrompt()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if systemPrompt.isEmpty {
      systemPrompt = AppConstants.defaultPromptModeSystemPrompt
      DebugLogger.log("PROMPT-MODE-OPENAI: Using base system prompt")
    } else {
      DebugLogger.log("PROMPT-MODE-OPENAI: Using custom system prompt")
    }
    systemPrompt += AppConstants.promptModeOutputRule

    // Optional screenshot context. gpt-4o-audio-preview is audio-only and rejects image_url
    // content parts with HTTP 400 ("This model does not support image_url content."), so we
    // skip the screenshot for that model regardless of the user's setting.
    let screenshotEnabled = screenshotInPromptModeEnabled()
    let modelAcceptsImages = model.supportsImageInput
    let screenshotData: Data? = (screenshotEnabled && modelAcceptsImages)
      ? await ChatWindowManager.shared.captureScreenForPromptMode()
      : nil
    if screenshotEnabled && !modelAcceptsImages {
      DebugLogger.log("PROMPT-MODE-OPENAI: Screenshot dropped — \(model.rawValue) does not accept image input.")
    }

    // Convert prior conversation history (text-only) into OpenAI messages so the model
    // sees multi-turn context, just like the Gemini path.
    let historyContents = PromptConversationHistory.shared.getContentsForAPI(mode: mode)
    let historyCount = historyContents.count / 2
    if historyCount > 0 {
      DebugLogger.log("PROMPT-MODE-OPENAI: Including \(historyCount) previous turns from conversation history")
    }
    let historyMessages: [[String: Any]] = historyContents.map { content in
      let role = content.role == "model" ? "assistant" : "user"
      let text = content.parts.compactMap { $0.text }.joined()
      return ["role": role, "content": text]
    }

    // Build current-turn user message content parts.
    var userContent: [[String: Any]] = []
    if let screenshotData {
      userContent.append(["type": "text", "text": "Current screen:"])
      let base64 = screenshotData.base64EncodedString()
      userContent.append([
        "type": "image_url",
        "image_url": ["url": "data:image/jpeg;base64,\(base64)"],
      ])
    }
    if let context = clipboardContext {
      DebugLogger.log("PROMPT-MODE-OPENAI: Adding clipboard context (length: \(context.count) chars)")
      let contextText = """
      SELECTED TEXT FROM CLIPBOARD (apply the voice instruction to this text):

      \(context)
      """
      userContent.append(["type": "text", "text": contextText])
    }
    // OpenAI's Chat Completions API embeds audio inline (base64). Reject oversized audio up
    // front with an actionable error — Gemini falls back to the Files API for >20 MB inputs,
    // but OpenAI's audio-preview endpoint has no equivalent here, so the request would simply
    // fail with a body-size error after a long upload.
    let audioFileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
    if audioFileSize > AppConstants.maxFileSizeBytes {
      let sizeMB = Double(audioFileSize) / 1_048_576.0
      let limitMB = Double(AppConstants.maxFileSizeBytes) / 1_048_576.0
      DebugLogger.logError("PROMPT-MODE-OPENAI: Audio too large (\(String(format: "%.1f", sizeMB)) MB > \(String(format: "%.1f", limitMB)) MB limit)")
      throw TranscriptionError.fileError("Audio is too long for OpenAI Dictate Prompt (\(String(format: "%.1f", sizeMB)) MB > \(String(format: "%.1f", limitMB)) MB limit). Switch to a Gemini Dictate Prompt model for longer recordings.")
    }

    let audioData: Data
    do {
      audioData = try Data(contentsOf: audioURL)
    } catch {
      throw TranscriptionError.networkError("Could not read audio file: \(error.localizedDescription)")
    }
    let fileExtension = audioURL.pathExtension.lowercased()
    let audioFormat = OpenAIChatProvider.openAIAudioFormat(forExtension: fileExtension)
    let base64Audio = audioData.base64EncodedString()
    userContent.append([
      "type": "input_audio",
      "input_audio": [
        "data": base64Audio,
        "format": audioFormat,
      ] as [String: Any],
    ])

    // Assemble messages: system → history → current user turn.
    var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
    messages.append(contentsOf: historyMessages)
    messages.append(["role": "user", "content": userContent])

    let body: [String: Any] = [
      "model": model.rawValue,
      "modalities": ["text"],
      "messages": messages,
    ]

    guard let endpointURL = URL(string: "https://api.openai.com/v1/chat/completions") else {
      throw TranscriptionError.networkError("Invalid OpenAI endpoint URL")
    }
    var request = URLRequest(url: endpointURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = Constants.resourceTimeout
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    // Auto-retry on 429 with exponential backoff, matching the Gemini path (which gets this
    // for free via GeminiAPIClient.performRequest(withRetry: true)). Short rate-limit spikes
    // are common on busy keys; surfacing them immediately to the user is unnecessary churn.
    let session = makeTranscriptionURLSession()
    var data = Data()
    var http: HTTPURLResponse!
    for attempt in 1...Constants.maxRetryAttempts {
      let (d, response) = try await session.data(for: request)
      guard let h = response as? HTTPURLResponse else {
        throw TranscriptionError.networkError("Invalid response from OpenAI API")
      }
      if h.statusCode == 429, attempt < Constants.maxRetryAttempts {
        let delay = Constants.retryDelaySeconds * pow(2.0, Double(attempt - 1))
        DebugLogger.logWarning("PROMPT-MODE-OPENAI: HTTP 429 (attempt \(attempt)/\(Constants.maxRetryAttempts)), retrying in \(String(format: "%.1f", delay))s")
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        continue
      }
      data = d
      http = h
      break
    }
    if http.statusCode < 200 || http.statusCode >= 300 {
      let bodyString = String(data: data, encoding: .utf8) ?? ""
      DebugLogger.logError("PROMPT-MODE-OPENAI: HTTP \(http.statusCode): \(bodyString.prefix(500))")
      switch http.statusCode {
      case 401:
        throw TranscriptionError.networkError("OpenAI API key is invalid. Check the key in Settings → General.")
      case 429:
        throw TranscriptionError.rateLimited(retryAfter: nil)
      default:
        throw TranscriptionError.serverError(http.statusCode)
      }
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = json["choices"] as? [[String: Any]],
          let firstChoice = choices.first,
          let message = firstChoice["message"] as? [String: Any] else {
      throw TranscriptionError.networkError("Unexpected OpenAI response shape")
    }

    // The audio-preview model returns plain string content for text-only output.
    let rawText: String
    if let str = message["content"] as? String {
      rawText = str
    } else if let arr = message["content"] as? [[String: Any]] {
      rawText = arr.compactMap { $0["text"] as? String }.joined()
    } else {
      throw TranscriptionError.networkError("OpenAI returned no text content")
    }

    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(rawText)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "PROMPT-MODE-OPENAI")

    // Resolve the parallel transcription with a 10-second budget so logging never blocks
    // the user (mirrors the Gemini path).
    var historyTranscriptionResult: String?
    await withTaskGroup(of: String?.self) { group in
      group.addTask { await transcriptionTask.value }
      group.addTask {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        return nil
      }
      for await value in group {
        if historyTranscriptionResult == nil {
          historyTranscriptionResult = value
          group.cancelAll()
        }
      }
    }
    let userInstruction = historyTranscriptionResult ?? "(voice instruction)"
    if historyTranscriptionResult == nil {
      DebugLogger.logWarning("PROMPT-MODE-OPENAI: History transcription timed out, using placeholder")
    }
    PromptConversationHistory.shared.append(
      mode: mode,
      selectedText: clipboardContext,
      userInstruction: userInstruction,
      modelResponse: normalizedText
    )
    ContextLogger.shared.logPrompt(mode: mode, selectedText: clipboardContext, userInstruction: userInstruction, modelResponse: normalizedText)

    DebugLogger.logSuccess("PROMPT-MODE-OPENAI: Completed successfully (\(normalizedText.count) chars)")
    return normalizedText
  }

  /// Transcribes audio to text for use in conversation history.
  /// Uses a lightweight transcription call to get the user's voice instruction as text.
  private func transcribeAudioForHistory(audioURL: URL, credential: GeminiCredential) async throws -> String {
    // Use the existing transcription logic but with a simpler prompt
    let audioData = try Data(contentsOf: audioURL)
    let base64Audio = audioData.base64EncodedString()
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = geminiClient.getMimeType(for: fileExtension)

    let endpoint = TranscriptionModel.gemini31FlashLite.apiEndpoint
    let (resolvedEndpoint, resolvedCredential) = GeminiAPIClient.resolveGenerateContentEndpoint(directEndpoint: endpoint, credential: credential)
    let credentialForRequest = await GeminiAPIClient.resolveCredentialForRequest(endpoint: resolvedEndpoint, resolvedCredential: resolvedCredential)
    var request = try geminiClient.createRequest(endpoint: resolvedEndpoint, credential: credentialForRequest)

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
      withRetry: true
    )

    guard let firstCandidate = result.candidates.first,
          let text = firstCandidate.content.parts.first?.text else {
      throw TranscriptionError.networkError("No transcription in response")
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  
  // MARK: - Text-based Prompt Mode (for TTS flow)
  func executePromptWithText(textCommand: String, selectedText: String?, mode: PromptMode = .togglePrompting) async throws -> String {
    guard let credential = await credentialProvider.getCredential() else {
      throw TranscriptionError.noGoogleAPIKey
    }

    let hasSelectedText = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    DebugLogger.log("PROMPT-MODE-TEXT: Starting execution with text command (hasSelectedText: \(hasSelectedText))")

    // Get selected model from settings based on mode
    let selectedPromptModel = getPromptModel(for: mode)

    // Convert to TranscriptionModel to get API endpoint
    guard let transcriptionModel = selectedPromptModel.asTranscriptionModel else {
      throw TranscriptionError.networkError("Selected model is not a Gemini model")
    }

    let endpoint = transcriptionModel.apiEndpoint
    DebugLogger.log("PROMPT-MODE-TEXT: Using model: \(selectedPromptModel.displayName)")

    // Build system prompt
    let systemPromptBase = SystemPromptsStore.shared.loadDictatePromptSystemPrompt()
    var systemPrompt = systemPromptBase.trimmingCharacters(in: .whitespacesAndNewlines)
    if systemPrompt.isEmpty {
      systemPrompt = AppConstants.defaultPromptModeSystemPrompt
    }

    // Always require raw output only (no meta), regardless of custom prompt
    systemPrompt += AppConstants.promptModeOutputRule

    let (resolvedEndpoint, resolvedCredential) = GeminiAPIClient.resolveGenerateContentEndpoint(directEndpoint: endpoint, credential: credential)
    let credentialForRequest = await GeminiAPIClient.resolveCredentialForRequest(endpoint: resolvedEndpoint, resolvedCredential: resolvedCredential)
    var request = try geminiClient.createRequest(endpoint: resolvedEndpoint, credential: credentialForRequest)

    // Build contents array - start with conversation history
    let historyContents = PromptConversationHistory.shared.getContentsForAPI(mode: mode)
    var contents: [GeminiChatRequest.GeminiChatContent] = historyContents

    let historyCount = historyContents.count / 2  // Each turn = 2 messages (user + model)
    if historyCount > 0 {
      DebugLogger.log("PROMPT-MODE-TEXT: Including \(historyCount) previous turns from conversation history")
    }

    // Capture screenshot for prompt context if enabled (best-effort; continues without image on failure)
    let screenshotData: Data? = screenshotInPromptModeEnabled()
      ? await ChatWindowManager.shared.captureScreenForPromptMode()
      : nil

    // Build current user message parts
    var userParts: [GeminiChatRequest.GeminiChatPart] = []

    // Add screenshot as first part so Gemini has visual context
    if let screenshotData {
      let base64Screenshot = screenshotData.base64EncodedString()
      userParts.append(GeminiChatRequest.GeminiChatPart(text: "Current screen:", inlineData: nil, fileData: nil, url: nil))
      userParts.append(GeminiChatRequest.GeminiChatPart(
        text: nil,
        inlineData: GeminiChatRequest.GeminiInlineData(mimeType: "image/jpeg", data: base64Screenshot),
        fileData: nil,
        url: nil
      ))
    }

    // Add clipboard context if present (so Gemini knows what to apply the instruction to)
    if let text = selectedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let contextText = """
      SELECTED TEXT TO EDIT (your next message is an instruction that tells you how to edit this text — do not append that message to this text):

      \(text)
      """
      userParts.append(GeminiChatRequest.GeminiChatPart(text: contextText, inlineData: nil, fileData: nil, url: nil))
    }

    // Add voice instruction
    let commandText = """
    VOICE INSTRUCTION\(hasSelectedText ? " (edit the selected text according to this command; do not transcribe and append)" : ""):

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
      withRetry: true
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
    ContextLogger.shared.logPrompt(mode: mode, selectedText: selectedText, userInstruction: textCommand, modelResponse: normalizedText)

    DebugLogger.logSuccess("PROMPT-MODE-TEXT: Completed successfully")

    return normalizedText
  }

  // MARK: - Text-to-Speech Mode

  func readTextAloud(_ text: String, voiceName: String? = nil) async throws -> Data {
    let task = Task<Data, Error> {
      try await self.performTTS(text: text, voiceName: voiceName)
    }

    currentTTSTask = task
    defer { currentTTSTask = nil }

    return try await task.value
  }

  private func performTTS(text: String, voiceName: String? = nil) async throws -> Data {
    guard let credential = await credentialProvider.getCredential() else {
      throw TranscriptionError.noGoogleAPIKey
    }

    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      throw TranscriptionError.networkError("Text is empty")
    }

    let selectedVoice = voiceName ?? SettingsDefaults.readAloudVoice
    let selectedTTSModel = SettingsDefaults.readAloudModel

    DebugLogger.log("TTS: Starting text-to-speech for text (length: \(trimmedText.count) chars) with voice: \(selectedVoice), model: \(selectedTTSModel.displayName)")

    let chunker = TextChunker()
    if chunker.needsChunking(trimmedText) {
      DebugLogger.log("TTS: Using chunked synthesis (text length > \(AppConstants.ttsChunkSizeChars) chars)")
      let chunkService = ChunkTTSService()
      chunkService.progressDelegate = chunkProgressDelegate
      return try await chunkService.synthesize(
        text: trimmedText,
        voiceName: selectedVoice,
        credential: credential,
        model: selectedTTSModel
      )
    } else {
      DebugLogger.log("TTS: Using single-request synthesis (text length <= \(AppConstants.ttsChunkSizeChars) chars)")
    }

    let endpoint = selectedTTSModel.apiEndpoint
    let (resolvedEndpoint, resolvedCredential) = GeminiAPIClient.resolveGenerateContentEndpoint(directEndpoint: endpoint, credential: credential)
    let credentialForRequest = await GeminiAPIClient.resolveCredentialForRequest(endpoint: resolvedEndpoint, resolvedCredential: resolvedCredential)
    var request = try geminiClient.createRequest(endpoint: resolvedEndpoint, credential: credentialForRequest)

    let ttsRequest = GeminiTTSRequest(
      contents: [GeminiTTSRequest.GeminiTTSContent(parts: [GeminiTTSRequest.GeminiTTSPart(text: "Say the following: \(trimmedText)")])],
      generationConfig: GeminiTTSRequest.GeminiTTSGenerationConfig(
        responseModalities: ["AUDIO"],
        speechConfig: GeminiTTSRequest.GeminiTTSSpeechConfig(
          voiceConfig: GeminiTTSRequest.GeminiTTSVoiceConfig(
            prebuiltVoiceConfig: GeminiTTSRequest.GeminiTTSPrebuiltVoiceConfig(voiceName: selectedVoice)
          )
        )
      )
    )
    request.httpBody = try JSONEncoder().encode(ttsRequest)

    DebugLogger.log("TTS: Making request to Gemini TTS API (text length: \(trimmedText.count) chars)")
    let result = try await geminiClient.performRequest(
      request,
      responseType: GeminiChatResponse.self,
      mode: "TTS",
      withRetry: true
    )

    DebugLogger.log("TTS: Received response from Gemini TTS API")
    guard let base64Audio = result.candidates.first?.content.parts.first(where: { $0.inlineData != nil })?.inlineData?.data,
          let decoded = Data(base64Encoded: base64Audio) else {
      DebugLogger.logError("TTS: Failed to decode base64 audio from response")
      throw TranscriptionError.networkError("Failed to decode base64 audio data")
    }
    DebugLogger.logSuccess("TTS: Successfully generated audio (size: \(decoded.count) bytes)")
    return decoded
  }

  // MARK: - OpenAI Transcription (cloud)

  private func transcribeWithOpenAI(audioURL: URL, modelID: String, displayName: String) async throws -> String {
    let token = (keychainManager.getOpenAIAPIKey() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      throw TranscriptionError.networkError("OpenAI API key is missing — add it in Settings → General.")
    }
    guard let endpoint = URL(string: AppConstants.openAITranscriptionsEndpoint) else {
      throw TranscriptionError.invalidRequest
    }

    let audioData = try Data(contentsOf: audioURL)
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = mimeTypeForAudioExtension(fileExtension)

    let session = makeTranscriptionURLSession()
    return try await sendOpenAICompatibleTranscriptionRequest(
      url: endpoint,
      fieldName: "file",
      modelID: modelID,
      audioData: audioData,
      fileExtension: fileExtension,
      mimeType: mimeType,
      bearerToken: token,
      extraHeaders: [],
      session: session,
      logPrefix: "OPENAI-TRANSCRIPTION"
    )
  }

  // MARK: - Self-hosted Transcription Endpoint

  private func transcribeWithSelfHostedEndpoint(audioURL: URL) async throws -> String {
    let configuredEndpoint = UserDefaults.standard.string(forKey: UserDefaultsKeys.customTranscriptionAPIURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !configuredEndpoint.isEmpty else {
      throw TranscriptionError.networkError("Self-hosted transcription endpoint URL is not configured. Set it in Settings → Dictate.")
    }
    guard let baseURL = URL(string: configuredEndpoint) else {
      throw TranscriptionError.invalidRequest
    }

    let bearerToken = (keychainManager.getCustomTranscriptionBearerToken() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let extraHeaders = keychainManager.getCustomTranscriptionHeaders()
    let audioData = try Data(contentsOf: audioURL)
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = mimeTypeForAudioExtension(fileExtension)

    let urlPath = baseURL.path
    let isBaseURL = urlPath.isEmpty || urlPath == "/"
    let base = configuredEndpoint.hasSuffix("/") ? String(configuredEndpoint.dropLast()) : configuredEndpoint

    // For a bare host, try the OpenAI layout first, then fall back to whisper-asr-webservice.
    // For a full path, try the same path with both field-name conventions.
    var attempts: [(URL, String)] = []
    if isBaseURL {
      if let u = URL(string: "\(base)/v1/audio/transcriptions") { attempts.append((u, "file")) }
      if let u = URL(string: "\(base)/asr") { attempts.append((u, "audio_file")) }
    } else {
      attempts.append((baseURL, "file"))
      attempts.append((baseURL, "audio_file"))
    }

    var lastError: Error = TranscriptionError.networkError("All request attempts failed")
    let session = makeTranscriptionURLSession()

    for (attemptURL, fieldName) in attempts {
      do {
        return try await sendOpenAICompatibleTranscriptionRequest(
          url: attemptURL,
          fieldName: fieldName,
          modelID: fieldName == "file" ? "whisper-1" : nil,
          audioData: audioData,
          fileExtension: fileExtension,
          mimeType: mimeType,
          bearerToken: bearerToken.isEmpty ? nil : bearerToken,
          extraHeaders: extraHeaders,
          session: session,
          logPrefix: "SELF-HOSTED-TRANSCRIPTION"
        )
      } catch TranscriptionError.serverError(let code) where code == 404 || code == 422 {
        DebugLogger.log("SELF-HOSTED-TRANSCRIPTION: \(code) on \(attemptURL.path) — trying next")
        lastError = TranscriptionError.serverError(code)
      }
    }
    throw lastError
  }

  // MARK: - OpenAI-Compatible Multipart Helper

  /// Shared multipart POST for both the OpenAI cloud path and the self-hosted endpoint path.
  /// Forwards Whisper Glossary as the `prompt` field and the language selection as the `language`
  /// field whenever the OpenAI layout (`file`) is used. The whisper-asr-webservice layout
  /// (`audio_file`) doesn't accept the same multipart fields, so those hints are skipped there.
  private func sendOpenAICompatibleTranscriptionRequest(
    url: URL, fieldName: String,
    modelID: String?,
    audioData: Data, fileExtension: String, mimeType: String,
    bearerToken: String?, extraHeaders: [[String: String]],
    session: URLSession,
    logPrefix: String
  ) async throws -> String {
    var requestURL = url
    if fieldName == "audio_file",
       var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      var items = comps.queryItems ?? []
      if !items.contains(where: { $0.name == "output" }) {
        items.append(URLQueryItem(name: "output", value: "json"))
      }
      comps.queryItems = items
      requestURL = comps.url ?? url
    }

    let glossary = SystemPromptsStore.shared.loadWhisperGlossary().trimmingCharacters(in: .whitespacesAndNewlines)
    let glossaryHint: String? = glossary.isEmpty ? nil : glossary
    let savedLanguageString = UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperLanguage)
    let savedLanguage = WhisperLanguage(rawValue: savedLanguageString ?? WhisperLanguage.auto.rawValue) ?? WhisperLanguage.auto
    let languageCode = savedLanguage.languageCode

    DebugLogger.log("\(logPrefix): POST \(loggableURL(requestURL)) (field: \(fieldName), model: \(modelID ?? "-"), language: \(languageCode ?? "auto"), prompt: \(glossaryHint == nil ? "none" : "\(glossaryHint!.count) chars"))")

    let boundary = "Boundary-\(UUID().uuidString)"
    var body = Data()

    func appendField(_ name: String, _ value: String) {
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }

    if fieldName == "file" {
      if let modelID = modelID {
        appendField("model", modelID)
      }
      if let language = languageCode {
        appendField("language", language)
      }
      if let prompt = glossaryHint {
        appendField("prompt", prompt)
      }
    }
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
      "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"audio.\(fileExtension)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        .data(using: .utf8)!)
    body.append(audioData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    var request = URLRequest(url: requestURL)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = Constants.resourceTimeout
    for header in extraHeaders {
      if let k = header["key"], let v = header["value"], !k.isEmpty {
        request.setValue(v, forHTTPHeaderField: k)
      }
    }
    if let token = bearerToken {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = body

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }

    DebugLogger.log("\(logPrefix): HTTP \(httpResponse.statusCode)")

    switch httpResponse.statusCode {
    case 200: break
    case 401: throw TranscriptionError.invalidAPIKey
    case 404: throw TranscriptionError.serverError(404)
    case 422: throw TranscriptionError.serverError(422)
    case 429: throw TranscriptionError.rateLimited(retryAfter: nil)
    default:
      let bodyString = String(data: data, encoding: .utf8) ?? ""
      DebugLogger.logError("\(logPrefix): HTTP \(httpResponse.statusCode): \(bodyString.prefix(200))")
      throw TranscriptionError.serverError(httpResponse.statusCode)
    }

    struct WhisperResponse: Decodable { let text: String }
    if let parsed = try? JSONDecoder().decode(WhisperResponse.self, from: data) {
      let result = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !result.isEmpty {
        DebugLogger.logSuccess("\(logPrefix): \(result.count) chars")
        return result
      }
    }
    if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
      DebugLogger.logSuccess("\(logPrefix): \(text.count) chars (plain text)")
      return text
    }
    throw TranscriptionError.noSpeechDetected
  }

  private func makeTranscriptionURLSession() -> URLSession {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = Constants.requestTimeout
    config.timeoutIntervalForResource = Constants.resourceTimeout
    return URLSession(configuration: config)
  }

  private func loggableURL(_ url: URL) -> String {
    guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.path
    }
    comps.query = nil
    comps.fragment = nil
    return comps.url?.absoluteString ?? url.path
  }

  private func mimeTypeForAudioExtension(_ ext: String) -> String {
    switch ext {
    case "mp3": return "audio/mpeg"
    case "m4a": return "audio/mp4"
    case "wav": return "audio/wav"
    case "flac": return "audio/flac"
    case "ogg": return "audio/ogg"
    case "webm": return "audio/webm"
    case "aiff", "aif": return "audio/aiff"
    case "aac": return "audio/aac"
    default: return "audio/mpeg"
    }
  }

  // MARK: - Gemini API Helpers (delegated to GeminiAPIClient)

  // MARK: - Gemini Transcription
  private func transcribeWithGemini(audioURL: URL, model: TranscriptionModel, promptOverride: String? = nil) async throws -> String {
    let apiStartTime = CFAbsoluteTimeGetCurrent()

    guard let credential = await credentialProvider.getCredential() else {
      DebugLogger.log("GEMINI-TRANSCRIPTION: ERROR - No Gemini credential (set API key in Settings)")
      throw TranscriptionError.noGoogleAPIKey
    }

    switch credential {
    case .apiKey(let key):
      DebugLogger.log("GEMINI-TRANSCRIPTION: Using API key (prefix: \(key.prefix(8))..., length: \(key.count) chars)")
    case .bearer:
      DebugLogger.log("GEMINI-TRANSCRIPTION: Using Proxy (Bearer)")
    }

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
      result = try await transcribeWithChunking(audioURL: audioURL, credential: credential, model: model, promptOverride: promptOverride)
    }
    // For files >20MB, use Files API (resumable upload)
    // For files ≤20MB, use inline base64
    // DEBUG: Can force Files API usage via Constants.debugForceFilesAPI
    else if Constants.debugForceFilesAPI {
      DebugLogger.log("GEMINI-TRANSCRIPTION: DEBUG - Forcing Files API usage (debugForceFilesAPI = true)")
      result = try await transcribeWithGeminiFilesAPI(audioURL: audioURL, credential: credential, model: model, promptOverride: promptOverride)
    } else if audioSize > AppConstants.maxFileSizeBytes {
      result = try await transcribeWithGeminiFilesAPI(audioURL: audioURL, credential: credential, model: model, promptOverride: promptOverride)
    } else {
      result = try await transcribeWithGeminiInline(audioURL: audioURL, credential: credential, model: model, promptOverride: promptOverride)
    }

    let apiElapsedTime = CFAbsoluteTimeGetCurrent() - apiStartTime
    DebugLogger.logSpeech("SPEED: [\(model.displayName)] API call completed in \(String(format: "%.3f", apiElapsedTime))s (\(String(format: "%.0f", apiElapsedTime * 1000))ms)")

    return result
  }

  // MARK: - Chunked Transcription
  private func transcribeWithChunking(audioURL: URL, credential: GeminiCredential, model: TranscriptionModel, promptOverride: String? = nil) async throws -> String {
    let chunkService = ChunkTranscriptionService(geminiClient: geminiClient)
    chunkService.progressDelegate = chunkProgressDelegate

    let prompt = promptOverride ?? buildDictationPrompt()

    return try await chunkService.transcribe(
      fileURL: audioURL,
      credential: credential,
      model: model,
      prompt: prompt
    )
  }

  // MARK: - Audio Duration Helper
  private func getAudioDuration(_ url: URL) async throws -> TimeInterval {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    return CMTimeGetSeconds(duration)
  }
  
  private func transcribeWithGeminiInline(audioURL: URL, credential: GeminiCredential, model: TranscriptionModel, promptOverride: String? = nil) async throws -> String {
    let inlineStartTime = CFAbsoluteTimeGetCurrent()
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using inline audio (file ≤20MB)")

    // Read audio file and convert to base64
    let encodeStartTime = CFAbsoluteTimeGetCurrent()
    let audioData = try Data(contentsOf: audioURL)
    let base64Audio = audioData.base64EncodedString()
    let encodeTime = CFAbsoluteTimeGetCurrent() - encodeStartTime
    DebugLogger.logSpeech("SPEED: Base64 encoding took \(String(format: "%.3f", encodeTime))s (\(String(format: "%.0f", encodeTime * 1000))ms)")

    // Determine MIME type from file extension
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = geminiClient.getMimeType(for: fileExtension)

    // Get dictation system prompt
    let promptToUse = promptOverride ?? buildDictationPrompt()
    
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using prompt: \(promptToUse.prefix(100))...")
    
    // Create request with dynamic endpoint based on selected model
    let endpoint = model.apiEndpoint
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using model: \(model.displayName) (\(model.rawValue))")
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
    
    let (resolvedEndpoint, resolvedCredential) = GeminiAPIClient.resolveGenerateContentEndpoint(directEndpoint: endpoint, credential: credential)
    let credentialForRequest = await GeminiAPIClient.resolveCredentialForRequest(endpoint: resolvedEndpoint, resolvedCredential: resolvedCredential)
    var request = try geminiClient.createRequest(endpoint: resolvedEndpoint, credential: credentialForRequest)
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
    DebugLogger.logSpeech("SPEED: [\(model.displayName)] API network request took \(String(format: "%.3f", networkTime))s (\(String(format: "%.0f", networkTime * 1000))ms)")

    let transcript = geminiClient.extractText(from: geminiResponse)
    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(transcript)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "TRANSCRIPTION-MODE")

    let inlineElapsedTime = CFAbsoluteTimeGetCurrent() - inlineStartTime
    DebugLogger.logSpeech("SPEED: [\(model.displayName)] inline transcription total: \(String(format: "%.3f", inlineElapsedTime))s (\(String(format: "%.0f", inlineElapsedTime * 1000))ms)")

    return normalizedText
  }

  private func transcribeWithGeminiFilesAPI(audioURL: URL, credential: GeminiCredential, model: TranscriptionModel, promptOverride: String? = nil) async throws -> String {
    let filesAPIStartTime = CFAbsoluteTimeGetCurrent()
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using Files API (file >20MB)")

    // Step 1: Upload file using resumable upload
    let uploadStartTime = CFAbsoluteTimeGetCurrent()
    let fileURI = try await geminiClient.uploadFile(audioURL: audioURL, credential: credential)
    let uploadTime = CFAbsoluteTimeGetCurrent() - uploadStartTime
    DebugLogger.logSpeech("SPEED: File upload took \(String(format: "%.3f", uploadTime))s (\(String(format: "%.0f", uploadTime * 1000))ms)")

    // Step 2: Use file URI for transcription
    let result = try await transcribeWithGeminiFileURI(fileURI: fileURI, credential: credential, model: model, promptOverride: promptOverride)
    
    let filesAPIElapsedTime = CFAbsoluteTimeGetCurrent() - filesAPIStartTime
    DebugLogger.logSpeech("SPEED: Gemini Files API transcription total time: \(String(format: "%.3f", filesAPIElapsedTime))s (\(String(format: "%.0f", filesAPIElapsedTime * 1000))ms)")
    
    return result
  }
  
  // File upload is now handled by GeminiAPIClient
  
  private func transcribeWithGeminiFileURI(fileURI: String, credential: GeminiCredential, model: TranscriptionModel, promptOverride: String? = nil) async throws -> String {
    let fileURIStartTime = CFAbsoluteTimeGetCurrent()

    // Get dictation system prompt
    let promptToUse = promptOverride ?? buildDictationPrompt()
    
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using prompt: \(promptToUse.prefix(100))...")
    
    // Create request with dynamic endpoint based on selected model
    let endpoint = model.apiEndpoint
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using model: \(model.displayName) (\(model.rawValue))")
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

    let (resolvedEndpoint, resolvedCredential) = GeminiAPIClient.resolveGenerateContentEndpoint(directEndpoint: endpoint, credential: credential)
    let credentialForRequest = await GeminiAPIClient.resolveCredentialForRequest(endpoint: resolvedEndpoint, resolvedCredential: resolvedCredential)
    var request = try geminiClient.createRequest(endpoint: resolvedEndpoint, credential: credentialForRequest)
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
    DebugLogger.logSpeech("SPEED: Gemini API network request (FileURI) took \(String(format: "%.3f", networkTime))s (\(String(format: "%.0f", networkTime * 1000))ms)")

    let transcript = geminiClient.extractText(from: geminiResponse)
    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(transcript)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "TRANSCRIPTION-MODE")
    
    let fileURIElapsedTime = CFAbsoluteTimeGetCurrent() - fileURIStartTime
    DebugLogger.logSpeech("SPEED: Gemini FileURI transcription took \(String(format: "%.3f", fileURIElapsedTime))s (\(String(format: "%.0f", fileURIElapsedTime * 1000))ms)")
    
    return normalizedText
  }
  
  // MIME type, text extraction, and error parsing are now handled by GeminiAPIClient

  // MARK: - Prompt Mode Helpers

  /// Reads the "include screenshot in Dictate Prompt" toggle, falling back to the
  /// default when the user hasn't explicitly set it.
  private func screenshotInPromptModeEnabled() -> Bool {
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.screenshotInPromptMode) != nil {
      return UserDefaults.standard.bool(forKey: UserDefaultsKeys.screenshotInPromptMode)
    }
    return SettingsDefaults.screenshotInPromptMode
  }

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



import AVFoundation
import Foundation
import NaturalLanguage

// MARK: - Prompt Mode Enum
enum PromptMode {
  case togglePrompting
}

// MARK: - Constants
private enum Constants {
  static let resourceTimeout: TimeInterval = 300.0

  // Retry budget for the OpenAI Dictate Prompt 429 backoff (1 attempt + 1 retry).
  static let maxRetryAttempts = 2
  static let retryDelaySeconds: TimeInterval = 1.5
}

// MARK: - Core Service
class SpeechService {

  /// Placeholder used in conversation history when the parallel voice-to-text transcription
  /// fails or times out.
  fileprivate static let voiceInstructionPlaceholder = "(voice instruction)"

  // MARK: - Shared Infrastructure
  private let keychainManager: KeychainManaging
  private let credentialProvider: GeminiCredentialProviding
  private var clipboardManager: ClipboardManager?
  private let geminiClient: GeminiAPIClient

  // MARK: - Chunked Transcription
  /// Delegate for receiving chunk progress updates during long audio transcription.
  weak var chunkProgressDelegate: ChunkProgressDelegate?

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
  /// Notifies the service that the selected transcription model changed (the model itself
  /// is persisted via UserDefaults; this is purely a hook for side effects like releasing
  /// the offline Whisper model when the user switches to a cloud backend).
  func setModel(_ model: TranscriptionModel) {
    // `unloadModel()` is idempotent — no-op when nothing is loaded — so we don't need
    // to track the previous selection just to decide whether to call it.
    if !model.isOffline {
      Task {
        await LocalSpeechService.shared.unloadModel()
      }
    }
  }

  // MARK: - Model Information for Notifications
  func getTranscriptionModelInfo() async -> String {
    let model = TranscriptionModel.loadSelected()
    if model.isOffline {
      return await LocalSpeechService.shared.getCurrentModelInfo() ?? model.displayName
    }
    return model.displayName
  }
  
  func getPromptModelInfo() -> String {
    getPromptModel().displayName
  }
  
  // MARK: - Prompt Model Selection Helper
  /// Reads the user's currently-selected Dictate Prompt model from UserDefaults,
  /// applying the legacy-rawValue migration first.
  private func getPromptModel() -> PromptModel {
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
    // Only clear the slot if this call still owns it — a concurrent newer call may have
    // overwritten `currentTranscriptionTask` while we were suspended on `task.value`; its
    // own `defer` will handle the clear.
    defer { if currentTranscriptionTask == task { currentTranscriptionTask = nil } }

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
      // gpt-4o-transcribe family accepts a full GPT-4o-style instruction via the `prompt`
      // multipart field — pass the user's dictation prompt so OpenAI behaves like Gemini.
      let dictationHint = (promptOverride ?? buildDictationPrompt()).trimmingCharacters(in: .whitespacesAndNewlines)
      let result = try await transcribeWithOpenAI(
        audioURL: audioURL,
        modelID: openAIModelID,
        dictationHint: dictationHint.isEmpty ? nil : dictationHint
      )
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.logSpeech("SPEED: [\(model.displayName)] transcription completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
      return result
    }

    // xAI Grok hosted transcription (/v1/stt)
    if model.isXAI {
      try validateAudioFileFormat(at: audioURL)
      let dictationHint = (promptOverride ?? buildDictationPrompt()).trimmingCharacters(in: .whitespacesAndNewlines)
      let result = try await transcribeWithXAI(
        audioURL: audioURL,
        dictationHint: dictationHint.isEmpty ? nil : dictationHint
      )
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
    // See `transcribe` for the identity-check rationale.
    defer { if currentPromptTask == task { currentPromptTask = nil } }

    return try await task.value
  }

  // MARK: - Async Helpers

  /// Awaits `task.value` but gives up after `timeoutSeconds`, returning `nil` instead
  /// of blocking the caller. Used by the Dictate Prompt paths so the secondary
  /// transcription-for-history call never holds up the user-visible response.
  /// On timeout the wrapped `task` is also cancelled so it does not keep running
  /// in the background after the user-visible response has already returned.
  ///
  /// Caveat: if `T` is itself an `Optional`, a real `nil` result from `task` is
  /// indistinguishable from a timeout. All current callers use `T = String`, so
  /// this is latent; tighten the type constraint before reusing for optional Ts.
  private func awaitWithTimeout<T>(_ task: Task<T, Never>, timeoutSeconds: Double) async -> T? {
    await withTaskGroup(of: Optional<T>.self, returning: T?.self) { group in
      group.addTask { await task.value }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      if first == nil {
        task.cancel()
      }
      return first
    }
  }

  // MARK: - Prompt Modes (Private Implementation)
  private func performPrompt(audioURL: URL, mode: PromptMode) async throws -> String {
    // Get clipboard context
    let clipboardContext = getClipboardContext()

    // Get selected model from settings based on mode
    let selectedPromptModel = getPromptModel()

    guard selectedPromptModel.supportsDirectAudioInput else {
      throw TranscriptionError.networkError("Selected Dictate Prompt model does not accept direct audio input. Pick a Gemini model or OpenAI's GPT-4o Audio.")
    }

    try validateAudioFileFormat(at: audioURL)

    switch selectedPromptModel.provider {
    case .gemini:
      return try await executePromptWithGemini(audioURL: audioURL, clipboardContext: clipboardContext, mode: mode, model: selectedPromptModel)
    case .openai:
      return try await executePromptWithOpenAI(audioURL: audioURL, clipboardContext: clipboardContext, mode: mode, model: selectedPromptModel)
    case .grok:
      preconditionFailure("Unreachable: no Grok model sets supportsDirectAudioInput=true, so the guard above always throws first.")
    }
  }

  // MARK: - Gemini Dictate Prompt Helpers

  /// Loads the user's Dictate Prompt system prompt (or the built-in default when empty)
  /// and appends the strict output rule. Both Gemini prompt paths use this composition.
  private func buildGeminiDictatePromptSystemPrompt(logPrefix: String) -> String {
    let trimmed = SystemPromptsStore.shared
      .loadDictatePromptSystemPrompt()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let base: String
    if trimmed.isEmpty {
      base = AppConstants.defaultPromptModeSystemPrompt
      DebugLogger.log("\(logPrefix): Using base system prompt")
    } else {
      base = trimmed
      DebugLogger.log("\(logPrefix): Using custom system prompt")
    }
    return base + AppConstants.promptModeOutputRule
  }

  /// Returns the screenshot parts to prepend to a Dictate Prompt request when the
  /// "include screenshot" setting is on and the model accepts images. Empty when
  /// disabled, when the model is audio-only, or when the capture fails.
  private func screenshotPromptParts(modelAcceptsImages: Bool = true) async -> [GeminiChatRequest.GeminiChatPart] {
    guard screenshotInPromptModeEnabled(), modelAcceptsImages else { return [] }
    guard let data = await ChatWindowManager.shared.captureScreenForPromptMode() else { return [] }
    return [
      GeminiChatRequest.GeminiChatPart(text: "Current screen:", inlineData: nil, fileData: nil, url: nil),
      GeminiChatRequest.GeminiChatPart(
        text: nil,
        inlineData: GeminiChatRequest.GeminiInlineData(mimeType: "image/jpeg", data: data.base64EncodedString()),
        fileData: nil,
        url: nil
      ),
    ]
  }

  /// Performs a Gemini Dictate Prompt request: prepends history, appends the caller-built
  /// user-turn parts, attaches the system instruction, sends the request with retry, and
  /// extracts + normalizes the text response.
  private func performGeminiPromptRequest(
    model: PromptModel,
    mode: PromptMode,
    userParts: [GeminiChatRequest.GeminiChatPart],
    systemPrompt: String,
    credential: GeminiCredential,
    logPrefix: String
  ) async throws -> String {
    guard let transcriptionModel = model.asTranscriptionModel else {
      throw TranscriptionError.networkError("Selected model is not a Gemini model")
    }
    let endpoint = transcriptionModel.apiEndpoint
    DebugLogger.log("\(logPrefix): Using model: \(model.displayName) (\(model.rawValue))")
    DebugLogger.log("\(logPrefix): Using endpoint: \(endpoint)")

    let (resolvedEndpoint, resolvedCredential) = GeminiAPIClient.resolveGenerateContentEndpoint(directEndpoint: endpoint, credential: credential)
    let credentialForRequest = await GeminiAPIClient.resolveCredentialForRequest(endpoint: resolvedEndpoint, resolvedCredential: resolvedCredential)
    var request = try geminiClient.createRequest(endpoint: resolvedEndpoint, credential: credentialForRequest)

    let historyContents = PromptConversationHistory.shared.getContentsForAPI(mode: mode)
    let historyCount = historyContents.count / 2
    if historyCount > 0 {
      DebugLogger.log("\(logPrefix): Including \(historyCount) previous turns from conversation history")
    }
    var contents: [GeminiChatRequest.GeminiChatContent] = historyContents
    contents.append(GeminiChatRequest.GeminiChatContent(role: "user", parts: userParts))

    let systemInstruction = GeminiChatRequest.GeminiSystemInstruction(
      parts: [GeminiChatRequest.GeminiSystemPart(text: systemPrompt)]
    )
    let chatRequest = GeminiChatRequest(
      contents: contents,
      systemInstruction: systemInstruction,
      tools: nil,
      generationConfig: nil,
      model: nil
    )
    request.httpBody = try JSONEncoder().encode(chatRequest)

    let result = try await geminiClient.performRequest(
      request,
      responseType: GeminiChatResponse.self,
      mode: logPrefix,
      withRetry: true
    )

    guard let firstCandidate = result.candidates.first else {
      throw TranscriptionError.networkError("No candidates in Gemini response")
    }

    var textContent = ""
    for part in firstCandidate.content.parts {
      if let text = part.text {
        textContent += text
      }
    }

    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(textContent)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: logPrefix)
    return normalizedText
  }

  // MARK: - Gemini Prompt Mode
  private func executePromptWithGemini(audioURL: URL, clipboardContext: String?, mode: PromptMode, model: PromptModel) async throws -> String {
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
        return Self.voiceInstructionPlaceholder
      }
    }

    DebugLogger.log("PROMPT-MODE-GEMINI: Clipboard context: \(clipboardContext != nil ? "present" : "none")")

    var userParts: [GeminiChatRequest.GeminiChatPart] = []
    userParts.append(contentsOf: await screenshotPromptParts())

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

    // Audio goes after context so the model has the surrounding intent before processing speech.
    let audioSize = getAudioFileSize(at: audioURL)
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = geminiClient.getMimeType(for: fileExtension)
    if audioSize > AppConstants.maxFileSizeBytes {
      let fileURI = try await geminiClient.uploadFile(audioURL: audioURL, credential: credential)
      userParts.append(GeminiChatRequest.GeminiChatPart(
        text: nil,
        inlineData: nil,
        fileData: GeminiChatRequest.GeminiFileData(fileUri: fileURI, mimeType: mimeType),
        url: nil
      ))
    } else {
      let audioData = try Data(contentsOf: audioURL)
      userParts.append(GeminiChatRequest.GeminiChatPart(
        text: nil,
        inlineData: GeminiChatRequest.GeminiInlineData(mimeType: mimeType, data: audioData.base64EncodedString()),
        fileData: nil,
        url: nil
      ))
    }

    let normalizedText = try await performGeminiPromptRequest(
      model: model,
      mode: mode,
      userParts: userParts,
      systemPrompt: buildGeminiDictatePromptSystemPrompt(logPrefix: "PROMPT-MODE-GEMINI"),
      credential: credential,
      logPrefix: "PROMPT-MODE-GEMINI"
    )

    let historyResult = await awaitWithTimeout(transcriptionTask, timeoutSeconds: 10)
    let userInstruction = historyResult ?? Self.voiceInstructionPlaceholder
    if historyResult == nil {
      DebugLogger.logWarning("PROMPT-MODE-GEMINI: History transcription timed out, using placeholder")
    }
    PromptConversationHistory.shared.append(
      mode: mode,
      selectedText: clipboardContext,
      userInstruction: userInstruction,
      modelResponse: normalizedText
    )
    ContextLogger.shared.logPrompt(mode: mode, selectedText: clipboardContext, userInstruction: userInstruction, modelResponse: normalizedText, model: model.rawValue)

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
          modelID: "gpt-4o-mini-transcribe"
        )
        DebugLogger.log("PROMPT-MODE-OPENAI: Transcribed voice instruction for history: \"\(text.prefix(50))...\"")
        return text
      } catch {
        DebugLogger.logWarning("PROMPT-MODE-OPENAI: Failed to transcribe instruction for history: \(error.localizedDescription)")
        return Self.voiceInstructionPlaceholder
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
    let (data, http) = try await Self.performWithRetryOn429(
      request: request,
      session: makeTranscriptionURLSession(),
      logPrefix: "PROMPT-MODE-OPENAI"
    )
    if http.statusCode < 200 || http.statusCode >= 300 {
      let bodyString = String(data: data, encoding: .utf8) ?? ""
      DebugLogger.logError("PROMPT-MODE-OPENAI: HTTP \(http.statusCode): \(bodyString.prefix(500))")
      switch http.statusCode {
      case 401:
        throw TranscriptionError.invalidAPIKey
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
    let historyTranscriptionResult = await awaitWithTimeout(transcriptionTask, timeoutSeconds: 10)
    let userInstruction = historyTranscriptionResult ?? Self.voiceInstructionPlaceholder
    if historyTranscriptionResult == nil {
      DebugLogger.logWarning("PROMPT-MODE-OPENAI: History transcription timed out, using placeholder")
    }
    PromptConversationHistory.shared.append(
      mode: mode,
      selectedText: clipboardContext,
      userInstruction: userInstruction,
      modelResponse: normalizedText
    )
    ContextLogger.shared.logPrompt(mode: mode, selectedText: clipboardContext, userInstruction: userInstruction, modelResponse: normalizedText, model: model.rawValue)

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
    let selectedPromptModel = getPromptModel()

    // The text path (used by Prompt & Read) is Gemini-only — the audio-input
    // OpenAI/Grok models reach this path with no audio to send. Fail fast with
    // an actionable message instead of the misleading "not a Gemini model" string.
    guard selectedPromptModel.provider == .gemini else {
      throw TranscriptionError.networkError("The text-based Prompt & Read flow currently requires a Gemini model. Switch the Dictate Prompt model to Gemini in Settings.")
    }

    guard let credential = await credentialProvider.getCredential() else {
      throw TranscriptionError.noGoogleAPIKey
    }

    let hasSelectedText = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    DebugLogger.log("PROMPT-MODE-TEXT: Starting execution with text command (hasSelectedText: \(hasSelectedText))")
    DebugLogger.log("PROMPT-MODE-TEXT: Using model: \(selectedPromptModel.displayName)")

    var userParts: [GeminiChatRequest.GeminiChatPart] = []
    userParts.append(contentsOf: await screenshotPromptParts())

    if let text = selectedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let contextText = """
      SELECTED TEXT TO EDIT (your next message is an instruction that tells you how to edit this text — do not append that message to this text):

      \(text)
      """
      userParts.append(GeminiChatRequest.GeminiChatPart(text: contextText, inlineData: nil, fileData: nil, url: nil))
    }

    let commandText = """
    VOICE INSTRUCTION\(hasSelectedText ? " (edit the selected text according to this command; do not transcribe and append)" : ""):

    \(textCommand)
    """
    userParts.append(GeminiChatRequest.GeminiChatPart(text: commandText, inlineData: nil, fileData: nil, url: nil))

    let normalizedText = try await performGeminiPromptRequest(
      model: selectedPromptModel,
      mode: mode,
      userParts: userParts,
      systemPrompt: buildGeminiDictatePromptSystemPrompt(logPrefix: "PROMPT-MODE-TEXT"),
      credential: credential,
      logPrefix: "PROMPT-MODE-TEXT"
    )

    PromptConversationHistory.shared.append(
      mode: mode,
      selectedText: selectedText,
      userInstruction: textCommand,
      modelResponse: normalizedText
    )
    ContextLogger.shared.logPrompt(mode: mode, selectedText: selectedText, userInstruction: textCommand, modelResponse: normalizedText, model: selectedPromptModel.rawValue)

    DebugLogger.logSuccess("PROMPT-MODE-TEXT: Completed successfully")
    return normalizedText
  }

  // MARK: - Text-to-Speech Mode

  /// Reads a user *selection* aloud. The text may be code, markdown, or log output, so it's
  /// first passed through Smart Rewrite (when the user has it on) to produce something more
  /// pleasant to listen to before TTS. Used by the global Read Aloud shortcut.
  func readSelectionAloud(_ text: String, voiceName: String? = nil) async throws -> Data {
    try await runReadAloud(text, voiceName: voiceName, applySmartRewrite: true)
  }

  /// Reads LLM-generated *prose* aloud — already intended for human consumption, so the
  /// Smart Rewrite pre-pass is skipped. Used by the chat reply read-aloud path.
  func readProseAloud(_ text: String, voiceName: String? = nil) async throws -> Data {
    try await runReadAloud(text, voiceName: voiceName, applySmartRewrite: false)
  }

  /// Runs the optional rewrite-then-TTS pipeline inside a single tracked `Task` stored on
  /// `currentTTSTask` so `cancelTTS()` can abort during the rewrite phase too (otherwise the
  /// rewrite would complete and TTS would start playing after the user already pressed Stop).
  private func runReadAloud(_ text: String, voiceName: String?, applySmartRewrite: Bool) async throws -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw TranscriptionError.networkError("Text is empty") }

    let task = Task<Data, Error> {
      let textForTTS = applySmartRewrite ? try await self.maybeRewriteForSpeech(trimmed) : trimmed
      try Task.checkCancellation()
      return try await self.performTTS(text: textForTTS, voiceName: voiceName)
    }
    currentTTSTask = task
    // See `transcribe` for the identity-check rationale.
    defer { if currentTTSTask == task { currentTTSTask = nil } }
    return try await task.value
  }

  /// Runs the Smart Rewrite pass if enabled. Returns the original text on any non-cancellation
  /// failure — Read Aloud should still play in that case rather than fail outright. A
  /// cancellation (either Swift `CancellationError` or `URLError.cancelled` from the network
  /// layer when the surrounding Task is cancelled) is rethrown so the caller aborts.
  private func maybeRewriteForSpeech(_ text: String) async throws -> String {
    guard ReadAloudPreferences.smartRewriteEnabled else {
      DebugLogger.log("READ-ALOUD-REWRITE: Disabled by user, using original text")
      return text
    }
    do {
      let rewritten = try await rewriteForSpeech(text)
      DebugLogger.logSuccess("READ-ALOUD-REWRITE: Rewrote \(text.count) chars -> \(rewritten.count) chars")
      return rewritten
    } catch {
      // If the surrounding Task got cancelled, propagate that regardless of which concrete
      // error type bubbled up (URLSession surfaces cancellation as `URLError(.cancelled)`,
      // not `CancellationError`).
      try Task.checkCancellation()
      DebugLogger.logWarning("READ-ALOUD-REWRITE: Rewrite failed (\(error.localizedDescription)); falling back to original text")
      return text
    }
  }

  /// Single-shot Gemini call that returns a speech-friendly version of `text`.
  /// Uses `gemini-3.1-flash-lite` to keep the pre-TTS latency low.
  private func rewriteForSpeech(_ text: String) async throws -> String {
    guard let credential = await credentialProvider.getCredential() else {
      throw TranscriptionError.noGoogleAPIKey
    }
    let systemPrompt = SystemPromptsStore.shared.loadReadAloudRewritePrompt()
    let model = TranscriptionModel.gemini31FlashLite

    let endpoint = model.apiEndpoint
    let (resolvedEndpoint, resolvedCredential) = GeminiAPIClient.resolveGenerateContentEndpoint(directEndpoint: endpoint, credential: credential)
    let credentialForRequest = await GeminiAPIClient.resolveCredentialForRequest(endpoint: resolvedEndpoint, resolvedCredential: resolvedCredential)
    var request = try geminiClient.createRequest(endpoint: resolvedEndpoint, credential: credentialForRequest)

    let userParts: [GeminiChatRequest.GeminiChatPart] = [
      GeminiChatRequest.GeminiChatPart(text: text, inlineData: nil, fileData: nil, url: nil)
    ]
    let chatRequest = GeminiChatRequest(
      contents: [GeminiChatRequest.GeminiChatContent(role: "user", parts: userParts)],
      systemInstruction: GeminiChatRequest.GeminiSystemInstruction(
        parts: [GeminiChatRequest.GeminiSystemPart(text: systemPrompt)]
      ),
      tools: nil,
      generationConfig: nil,
      model: nil
    )
    request.httpBody = try JSONEncoder().encode(chatRequest)

    let response = try await geminiClient.performRequest(
      request,
      responseType: GeminiChatResponse.self,
      mode: "READ-ALOUD-REWRITE",
      withRetry: true
    )
    let combined = response.candidates.first?.content.parts.compactMap { $0.text }.joined() ?? ""
    let cleaned = combined.trimmingCharacters(in: .whitespacesAndNewlines)
    // If the model returns nothing useful, fall back to the original text — empty TTS would
    // surface as a confusing "Text is empty" error to the user.
    return cleaned.isEmpty ? text : cleaned
  }

  /// Multi-provider Read Aloud. Dispatches by the selected model's provider. All three providers
  /// emit raw PCM (s16le 24kHz mono), which is exactly what `MenuBarController.playTTSAudio`
  /// expects, so the returned `Data` is provider-independent.
  private func performTTS(text: String, voiceName: String? = nil) async throws -> Data {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let model = ReadAloudPreferences.model
    // No voice picker in the UI: nil → each provider's default voice (a name its API accepts).
    let voice = voiceName ?? model.defaultVoice

    DebugLogger.log("TTS: Starting text-to-speech (length: \(trimmedText.count) chars, voice: \(voice), model: \(model.displayName), provider: \(model.provider.displayName))")

    // ChunkTTSService handles splitting, parallelism, retry/rate-limit coordination, and
    // merging. Every provider returns raw PCM (s16le 24kHz mono), so the merged result feeds
    // `playTTSAudio` unchanged — we only supply a per-chunk synthesizer for the chosen provider.
    let synthesizeChunk: (String) async throws -> Data
    switch model.provider {
    case .gemini:
      guard let credential = await credentialProvider.getCredential() else {
        throw TranscriptionError.noGoogleAPIKey
      }
      synthesizeChunk = { [weak self] chunkText in
        guard let self else { throw TranscriptionError.networkError("Speech service was deallocated") }
        return try await self.synthesizeGeminiTTSChunk(text: chunkText, voice: voice, model: model, credential: credential)
      }
    case .openai:
      synthesizeChunk = { [weak self] chunkText in
        guard let self else { throw TranscriptionError.networkError("Speech service was deallocated") }
        return try await self.synthesizeOpenAITTS(text: chunkText, voice: voice, model: model)
      }
    case .xai:
      synthesizeChunk = { [weak self] chunkText in
        guard let self else { throw TranscriptionError.networkError("Speech service was deallocated") }
        return try await self.synthesizeXAITTS(text: chunkText, voice: voice, model: model)
      }
    }

    let chunkService = ChunkTTSService()
    chunkService.progressDelegate = chunkProgressDelegate
    return try await chunkService.synthesize(text: trimmedText, model: model, synthesizeText: synthesizeChunk)
  }

  // MARK: - Gemini TTS (Generative Language API) — synthesizes one chunk per call.
  private func synthesizeGeminiTTSChunk(text: String, voice: String, model: TTSModel, credential: GeminiCredential) async throws -> Data {
    let endpoint = model.apiEndpoint
    let (resolvedEndpoint, resolvedCredential) = GeminiAPIClient.resolveGenerateContentEndpoint(directEndpoint: endpoint, credential: credential)
    let credentialForRequest = await GeminiAPIClient.resolveCredentialForRequest(endpoint: resolvedEndpoint, resolvedCredential: resolvedCredential)
    var request = try geminiClient.createRequest(endpoint: resolvedEndpoint, credential: credentialForRequest)

    let ttsRequest = GeminiTTSRequest(
      contents: [GeminiTTSRequest.GeminiTTSContent(parts: [GeminiTTSRequest.GeminiTTSPart(text: "Say the following: \(text)")])],
      generationConfig: GeminiTTSRequest.GeminiTTSGenerationConfig(
        responseModalities: ["AUDIO"],
        speechConfig: GeminiTTSRequest.GeminiTTSSpeechConfig(
          voiceConfig: GeminiTTSRequest.GeminiTTSVoiceConfig(
            prebuiltVoiceConfig: GeminiTTSRequest.GeminiTTSPrebuiltVoiceConfig(voiceName: voice)
          )
        )
      )
    )
    request.httpBody = try JSONEncoder().encode(ttsRequest)

    let result = try await geminiClient.performRequest(
      request,
      responseType: GeminiChatResponse.self,
      mode: "TTS",
      withRetry: true
    )

    guard let base64Audio = result.candidates.first?.content.parts.first(where: { $0.inlineData != nil })?.inlineData?.data,
          let decoded = Data(base64Encoded: base64Audio) else {
      DebugLogger.logError("TTS: Failed to decode base64 audio from Gemini response")
      throw TranscriptionError.networkError("Failed to decode base64 audio data")
    }
    return decoded
  }

  /// OpenAI TTS — `response_format:"pcm"` returns raw s16le 24kHz mono PCM (no header).
  private func synthesizeOpenAITTS(text: String, voice: String, model: TTSModel) async throws -> Data {
    let token = (keychainManager.getOpenAIAPIKey() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      throw TranscriptionError.networkError("OpenAI API key is missing — add it in Settings → General.")
    }
    guard let url = URL(string: AppConstants.openAISpeechEndpoint) else { throw TranscriptionError.invalidRequest }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let body: [String: Any] = [
      "model": model.rawValue,
      "input": text,
      "voice": voice,
      "response_format": "pcm",
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, http) = try await Self.performWithRetryOn429(
      request: request, session: makeTranscriptionURLSession(), logPrefix: "TTS-OPENAI")
    guard http.statusCode == 200 else {
      let bodyText = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
      throw TranscriptionError.networkError("OpenAI TTS failed (HTTP \(http.statusCode)): \(bodyText)")
    }
    return data
  }

  /// xAI Grok TTS — `output_format:{codec:"pcm",sample_rate:24000}` returns raw s16le 24kHz mono PCM.
  /// The model id is implied by the endpoint; sending a `model` field returns "Invalid request format".
  private func synthesizeXAITTS(text: String, voice: String, model: TTSModel) async throws -> Data {
    let token = (keychainManager.getXAIAPIKey() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      throw TranscriptionError.networkError("xAI API key is missing — add it in Settings → General.")
    }
    guard let url = URL(string: AppConstants.xaiTTSEndpoint) else { throw TranscriptionError.invalidRequest }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let body: [String: Any] = [
      "text": text,
      "voice_id": voice,
      "language": "auto",
      "output_format": ["codec": "pcm", "sample_rate": 24000] as [String: Any],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, http) = try await Self.performWithRetryOn429(
      request: request, session: makeTranscriptionURLSession(), logPrefix: "TTS-XAI")
    guard http.statusCode == 200 else {
      let bodyText = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
      throw TranscriptionError.networkError("xAI TTS failed (HTTP \(http.statusCode)): \(bodyText)")
    }
    return data
  }

  // MARK: - OpenAI Transcription (cloud)

  private func transcribeWithOpenAI(audioURL: URL, modelID: String, dictationHint: String? = nil) async throws -> String {
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
      logPrefix: "OPENAI-TRANSCRIPTION",
      dictationHint: dictationHint
    )
  }

  // MARK: - xAI Grok Transcription (cloud, /v1/stt)

  /// Transcribes audio via xAI's hosted Speech-to-Text endpoint. The wire format is the same
  /// OpenAI-style multipart (`model`/`language`/`file`) the OpenAI path uses, and xAI ignores the
  /// extra `prompt` field gracefully — verified live — so we reuse the shared helper.
  private func transcribeWithXAI(audioURL: URL, dictationHint: String? = nil) async throws -> String {
    let token = (keychainManager.getXAIAPIKey() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      throw TranscriptionError.networkError("xAI API key is missing — add it in Settings → General.")
    }
    guard let endpoint = URL(string: AppConstants.xaiSTTEndpoint) else {
      throw TranscriptionError.invalidRequest
    }

    let audioData = try Data(contentsOf: audioURL)
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = mimeTypeForAudioExtension(fileExtension)

    let session = makeTranscriptionURLSession()
    return try await sendOpenAICompatibleTranscriptionRequest(
      url: endpoint,
      fieldName: "file",
      modelID: "grok-stt",
      audioData: audioData,
      fileExtension: fileExtension,
      mimeType: mimeType,
      bearerToken: token,
      extraHeaders: [],
      session: session,
      logPrefix: "XAI-TRANSCRIPTION",
      dictationHint: dictationHint
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
  /// `dictationHint` is a longer instruction string (e.g. the dictation system prompt) that
  /// `gpt-4o-transcribe`/`gpt-4o-mini-transcribe` accept via the same `prompt` field —
  /// OpenAI docs: "similarly to how you would prompt other GPT-4o models". When set, it is
  /// prepended to the glossary. Callers must NOT pass it for `whisper-1` (224-token limit).
  private func sendOpenAICompatibleTranscriptionRequest(
    url: URL, fieldName: String,
    modelID: String?,
    audioData: Data, fileExtension: String, mimeType: String,
    bearerToken: String?, extraHeaders: [[String: String]],
    session: URLSession,
    logPrefix: String,
    dictationHint: String? = nil
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
    let trimmedDictationHint = (dictationHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let combinedPrompt: String? = {
      switch (trimmedDictationHint.isEmpty, glossary.isEmpty) {
      case (true, true): return nil
      case (true, false): return glossary
      case (false, true): return trimmedDictationHint
      case (false, false): return trimmedDictationHint + "\n\n" + glossary
      }
    }()
    let savedLanguageString = UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperLanguage)
    let savedLanguage = WhisperLanguage(rawValue: savedLanguageString ?? WhisperLanguage.auto.rawValue) ?? WhisperLanguage.auto
    let languageCode = savedLanguage.languageCode

    DebugLogger.log("\(logPrefix): POST \(loggableURL(requestURL)) (field: \(fieldName), model: \(modelID ?? "-"), language: \(languageCode ?? "auto"), prompt: \(combinedPrompt == nil ? "none" : "\(combinedPrompt!.count) chars\(trimmedDictationHint.isEmpty ? "" : " (dictation+glossary)")"))")

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
      if let prompt = combinedPrompt {
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
      if result.isEmpty {
        DebugLogger.log("\(logPrefix): empty transcription (no speech detected)")
        throw TranscriptionError.noSpeechDetected
      }
      DebugLogger.logSuccess("\(logPrefix): \(result.count) chars")
      return result
    }
    if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
      DebugLogger.logSuccess("\(logPrefix): \(text.count) chars (plain text)")
      return text
    }
    throw TranscriptionError.noSpeechDetected
  }

  /// Shared session used for OpenAI-compatible multipart transcription and the
  /// OpenAI Dictate Prompt path. Reuses the same connection pool as the chat
  /// providers (`LLMHTTPSession.shared`), which is configured with identical
  /// 60s/300s timeouts.
  private func makeTranscriptionURLSession() -> URLSession {
    LLMHTTPSession.shared
  }

  /// POSTs `request` and retries once on HTTP 429 with exponential backoff. Returns the
  /// final response (data + HTTPURLResponse) without interpreting the status code —
  /// callers map non-2xx codes themselves. Mirrors the retry shape Gemini gets for free
  /// via `GeminiAPIClient.performRequest(withRetry: true)`.
  private static func performWithRetryOn429(
    request: URLRequest,
    session: URLSession,
    logPrefix: String
  ) async throws -> (Data, HTTPURLResponse) {
    var lastResponse: (Data, HTTPURLResponse)?
    for attempt in 1...Constants.maxRetryAttempts {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw TranscriptionError.networkError("Invalid response from server")
      }
      lastResponse = (data, http)
      if http.statusCode == 429, attempt < Constants.maxRetryAttempts {
        let delay = Constants.retryDelaySeconds * pow(2.0, Double(attempt - 1))
        DebugLogger.logWarning("\(logPrefix): HTTP 429 (attempt \(attempt)/\(Constants.maxRetryAttempts)), retrying in \(String(format: "%.1f", delay))s")
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        continue
      }
      return (data, http)
    }
    // Unreachable when `maxRetryAttempts >= 1` — the loop always returns or continues.
    if let lastResponse { return lastResponse }
    throw TranscriptionError.networkError("Exhausted retry attempts without a response")
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
    // For files >20MB, use Files API (resumable upload); inline base64 otherwise.
    else if audioSize > AppConstants.maxFileSizeBytes {
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
            .text(promptToUse.isEmpty ? "Transcribe this audio. Return only the transcribed text without any additional commentary or formatting." : promptToUse),
            .inline(mimeType: mimeType, data: base64Audio)
          ]
        )
      ],
      generationConfig: .thinkingDisabled
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

    // Step 2: Use file URI for transcription. Forward the original MIME type so the
    // server doesn't misinterpret non-WAV uploads (e.g. mp3/m4a/flac) as WAV.
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = geminiClient.getMimeType(for: fileExtension)
    let result = try await transcribeWithGeminiFileURI(fileURI: fileURI, mimeType: mimeType, credential: credential, model: model, promptOverride: promptOverride)
    
    let filesAPIElapsedTime = CFAbsoluteTimeGetCurrent() - filesAPIStartTime
    DebugLogger.logSpeech("SPEED: Gemini Files API transcription total time: \(String(format: "%.3f", filesAPIElapsedTime))s (\(String(format: "%.0f", filesAPIElapsedTime * 1000))ms)")
    
    return result
  }
  
  // File upload is now handled by GeminiAPIClient
  
  private func transcribeWithGeminiFileURI(fileURI: String, mimeType: String, credential: GeminiCredential, model: TranscriptionModel, promptOverride: String? = nil) async throws -> String {
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
            .text(promptToUse.isEmpty ? "Transcribe this audio. Return only the transcribed text without any additional commentary or formatting." : promptToUse),
            .file(uri: fileURI, mimeType: mimeType)
          ]
        )
      ],
      generationConfig: .thinkingDisabled
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



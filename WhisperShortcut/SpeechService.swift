import AVFoundation
import Foundation
import NaturalLanguage

// MARK: - Constants
private enum Constants {
  static let maxFileSize = 20 * 1024 * 1024  // 20MB - optimal für OpenAI's 25MB Limit
  static let requestTimeout: TimeInterval = 30.0
  static let resourceTimeout: TimeInterval = 120.0
  static let validationTimeout: TimeInterval = 10.0
  static let transcriptionEndpoint = "https://api.openai.com/v1/audio/transcriptions"
  static let chatEndpoint = "https://api.openai.com/v1/chat/completions"
  static let responsesEndpoint = "https://api.openai.com/v1/responses"  // New GPT-5 API
  static let modelsEndpoint = "https://api.openai.com/v1/models"

  // Text validation
  static let minimumTextLength = 3

  // Audio validation
  static let supportedAudioExtensions = ["wav", "mp3", "m4a", "flac", "ogg", "webm"]

  // Timing delays
  static let clipboardCopyDelay: UInt64 = 100_000_000  // 0.1 seconds in nanoseconds
  
  // Audio chunking constants - PRODUCTION VALUES
  static let maxChunkDuration: TimeInterval = 120.0  // 2 minutes per chunk
  static let maxChunkSize = 20 * 1024 * 1024  // 20MB per chunk - optimal  
  static let chunkOverlapDuration: TimeInterval = 3.0  // 3 seconds overlap
  static let minimumSilenceDuration: TimeInterval = 0.8  // 0.8 seconds minimum silence
  static let silenceThreshold: Float = -40.0  // dB threshold for silence detection
  
  // Retry configuration for robust chunking
  static let maxRetryAttempts = 2  // Maximum retry attempts per chunk (optimal balance)
  static let retryDelaySeconds: TimeInterval = 1.5  // Shorter delay for better UX
}

// MARK: - Transcription Model Enum
enum TranscriptionModel: String, CaseIterable {
  case gpt4oTranscribe = "gpt-4o-transcribe"
  case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"

  var displayName: String {
    switch self {
    case .gpt4oTranscribe:
      return "GPT-4o Transcribe"
    case .gpt4oMiniTranscribe:
      return "GPT-4o Mini Transcribe"
    }
  }

  var apiEndpoint: String {
    return Constants.transcriptionEndpoint
  }

  var isRecommended: Bool {
    switch self {
    case .gpt4oMiniTranscribe:
      return true
    case .gpt4oTranscribe:
      return false
    }
  }

  var costLevel: String {
    switch self {
    case .gpt4oMiniTranscribe:
      return "Low"
    case .gpt4oTranscribe:
      return "High"
    }
  }

  var description: String {
    switch self {
    case .gpt4oTranscribe:
      return "Highest accuracy and quality • Best for critical applications"
    case .gpt4oMiniTranscribe:
      return "Recommended • Great quality at lower cost • Best for everyday use"
    }
  }
}

// MARK: - Core Service
class SpeechService {

  // MARK: - Shared Infrastructure
  private let keychainManager: KeychainManaging
  private let ttsService: TTSService
  private let audioPlaybackService: AudioPlaybackService
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
  private var previousResponseId: String?            // Store previous response ID for conversation continuity
  private var previousResponseTimestamp: Date?       // Track when the last response was received

  init(
    keychainManager: KeychainManaging = KeychainManager.shared,
    clipboardManager: ClipboardManager? = nil
  ) {
    DebugLogger.logSpeech("🎤 SPEECH: SpeechService init called")
    self.keychainManager = keychainManager
    self.clipboardManager = clipboardManager
    self.ttsService = TTSService(keychainManager: keychainManager)
    self.audioPlaybackService = AudioPlaybackService.shared

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
    let selectedGPTModelString = UserDefaults.standard.string(forKey: modelKey) ?? "gpt-5-mini"
    let selectedGPTModel = GPTModel(rawValue: selectedGPTModelString) ?? .gpt5Mini
    return selectedGPTModel.displayName
  }
  
  func getVoiceResponseModelInfo() -> String {
    let modelKey = "selectedVoiceResponseModel"
    let selectedGPTModelString = UserDefaults.standard.string(forKey: modelKey) ?? "gpt-5-mini"
    let selectedGPTModel = GPTModel(rawValue: selectedGPTModelString) ?? .gpt5Mini
    return selectedGPTModel.displayName
  }

  // MARK: - Conversation Management
  func clearConversationHistory() {
    previousResponseId = nil
    previousResponseTimestamp = nil
  }

  internal func isConversationExpired(isVoiceResponse: Bool) -> Bool {
    guard let timestamp = previousResponseTimestamp else {
      return true  // No previous conversation
    }

    // Read per-mode timeout from settings
    let key = isVoiceResponse
      ? "voiceResponseConversationTimeoutMinutes" : "promptConversationTimeoutMinutes"

    // If not set, fall back to defaults (1 minute as requested)
    var timeoutMinutes = UserDefaults.standard.object(forKey: key) as? Double
    if timeoutMinutes == nil {
      // Fallback default per mode
      timeoutMinutes = 1.0
    }

    // Never: 0.0 means no expiry
    if let t = timeoutMinutes, t == 0.0 {
      return false
    }

    let effectiveMinutes = (timeoutMinutes ?? 1.0)
    let expirationTime = timestamp.addingTimeInterval(effectiveMinutes * 60)  // Convert to seconds
    let isExpired = Date() > expirationTime

    if isExpired {
      clearConversationHistory()
    }

    return isExpired
  }

  // MARK: - Shared Validation
  func validateAPIKey(_ key: String) async throws -> Bool {
    guard !key.isEmpty else {
      DebugLogger.logWarning("API key is empty")
      throw TranscriptionError.noAPIKey
    }

    let url = URL(string: Constants.modelsEndpoint)!
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = Constants.validationTimeout

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      DebugLogger.logWarning("Invalid response from API validation")
      throw TranscriptionError.networkError("Invalid response")
    }

    if httpResponse.statusCode != 200 {
      DebugLogger.logWarning("API validation failed with status \(httpResponse.statusCode)")
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    return true
  }

  // MARK: - Transcription Mode
  func transcribe(audioURL: URL) async throws -> String {
    DebugLogger.logSpeech("🎤 TRANSCRIPTION-MODE: Starting transcription for \(audioURL.lastPathComponent)")
    
    // TEMPORARY DEBUG: Log audio file details
    let audioDuration = getAudioDuration(audioURL)
    let audioSize = getAudioSize(audioURL)
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Audio file - Duration: \(audioDuration)s, Size: \(audioSize) bytes")
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Chunk limits - Max Duration: \(Constants.maxChunkDuration)s, Max Size: \(Constants.maxChunkSize) bytes")

    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      DebugLogger.logError("❌ TRANSCRIPTION-MODE: No API key available")
      throw TranscriptionError.noAPIKey
    }

    try validateAudioFile(at: audioURL)

    // SMART CHUNKING STRATEGY: Based on OpenAI API file size limits
    if audioSize <= Constants.maxFileSize {
      // File ≤25MB: Send to OpenAI directly with server-side chunking
      DebugLogger.logInfo("🔍 CHUNKING-STRATEGY: File ≤25MB, using OpenAI direct upload with server-side chunking (Duration: \(audioDuration)s, Size: \(audioSize) bytes)")
      
      let request = try createTranscriptionRequest(audioURL: audioURL, apiKey: apiKey)
      let (data, response) = try await session.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        DebugLogger.logError("❌ TRANSCRIPTION-MODE: Invalid response type")
        throw TranscriptionError.networkError("Invalid response")
      }

      if httpResponse.statusCode != 200 {
        DebugLogger.logError("❌ TRANSCRIPTION-MODE: HTTP error \(httpResponse.statusCode)")
        let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
        throw error
      }

      let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
      try validateSpeechText(result.text, mode: "TRANSCRIPTION-MODE")
      DebugLogger.logSpeech("✅ TRANSCRIPTION-MODE: Returning transcribed text")
      return result.text
      
    } else {
      // File >25MB: Use client-side chunking first, then send multiple requests
      DebugLogger.logInfo("🔍 CHUNKING-STRATEGY: File >25MB, using CLIENT-SIDE chunking (multiple API calls) (Duration: \(audioDuration)s, Size: \(audioSize) bytes)")
      
      let transcribedText = try await transcribeAudioChunked(audioURL)
      DebugLogger.logInfo("🔍 CHUNKING-STRATEGY: Client-side chunked transcription completed, result length: \(transcribedText.count) chars")
      try validateSpeechText(transcribedText, mode: "TRANSCRIPTION-MODE")
      DebugLogger.logSpeech("✅ TRANSCRIPTION-MODE: Returning transcribed text")
      return transcribedText
    }
  }

  // MARK: - Prompt Modes
  func executePrompt(audioURL: URL) async throws -> String {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      DebugLogger.logWarning("PROMPT-MODE: No API key available")
      throw TranscriptionError.noAPIKey
    }

    let spokenText = try await transcribe(audioURL: audioURL)
    try validateSpeechText(spokenText, mode: "PROMPT-MODE")

    let clipboardContext = getClipboardContext()
    return try await executeGPT5Prompt(
      userMessage: spokenText, clipboardContext: clipboardContext, apiKey: apiKey)
  }

  func executePromptWithVoiceResponse(audioURL: URL, clipboardContext: String? = nil) async throws
    -> String
  {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      DebugLogger.logWarning("VOICE-RESPONSE-MODE: No API key available")
      throw TranscriptionError.noAPIKey
    }

    let spokenText = try await transcribe(audioURL: audioURL)
    try validateSpeechText(spokenText, mode: "PROMPT-MODE")

    let contextToUse = clipboardContext ?? getClipboardContext()

    let response = try await executeGPT5PromptForVoiceResponse(
      userMessage: spokenText, clipboardContext: contextToUse, apiKey: apiKey)

    clipboardManager?.copyToClipboard(text: response)

    let playbackSpeed = UserDefaults.standard.double(forKey: "voiceResponsePlaybackSpeed")
    let speed = playbackSpeed > 0 ? playbackSpeed : 1.0

    NotificationCenter.default.post(
      name: NSNotification.Name("VoiceResponseReadyToSpeak"), object: nil)

    await MainActor.run {
      NotificationCenter.default.post(
        name: NSNotification.Name("VoicePlaybackStartedWithText"),
        object: nil,
        userInfo: ["responseText": response]
      )
    }

    try await playTextAsSpeechChunked(response, playbackType: .voiceResponse, speed: speed)

    return response
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

    if trimmedText.isEmpty || trimmedText.count < Constants.minimumTextLength {
      DebugLogger.logWarning("\(mode): No meaningful speech detected")
      throw TranscriptionError.noSpeechDetected
    }

    let defaultPrompt = AppConstants.defaultTranscriptionSystemPrompt
    if trimmedText.contains(defaultPrompt) || trimmedText.hasPrefix("context:") {
      DebugLogger.logWarning("\(mode): System prompt detected in transcription")
      throw TranscriptionError.noSpeechDetected
    }
  }

  private func sanitizeUserInput(_ input: String) -> String {
    let sanitized = input.trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.filter { char in
      let scalar = char.unicodeScalars.first!
      return !CharacterSet.controlCharacters.contains(scalar) || char == "\n" || char == "\t"
    }
  }

  // MARK: - Audio Chunking Helpers
  
  // MARK: - Audio Analysis Utilities
  private func getAudioDuration(_ audioURL: URL) -> TimeInterval {
    let asset = AVAsset(url: audioURL)
    return CMTimeGetSeconds(asset.duration)
  }
  
  private func getAudioSize(_ audioURL: URL) -> Int64 {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
      return attributes[.size] as? Int64 ?? 0
    } catch {
      DebugLogger.logWarning("STT-CHUNKING: Could not get audio file size: \(error)")
      return 0
    }
  }
  
  // MARK: - Silence Detection
  private func detectSilencePauses(_ audioURL: URL) -> [TimeInterval] {
    guard let audioFile = try? AVAudioFile(forReading: audioURL) else {
      DebugLogger.logWarning("STT-CHUNKING: Could not open audio file for silence detection")
      return []
    }
    
    let format = audioFile.processingFormat
    let frameCount = AVAudioFrameCount(audioFile.length)
    
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
      DebugLogger.logWarning("STT-CHUNKING: Could not create audio buffer")
      return []
    }
    
    do {
      try audioFile.read(into: buffer)
    } catch {
      DebugLogger.logWarning("STT-CHUNKING: Could not read audio file: \(error)")
      return []
    }
    
    guard let floatChannelData = buffer.floatChannelData else {
      DebugLogger.logWarning("STT-CHUNKING: No float channel data available")
      return []
    }
    
    let channelData = floatChannelData[0]
    let frameLength = Int(buffer.frameLength)
    let sampleRate = format.sampleRate
    
    var silenceBreaks: [TimeInterval] = []
    var silenceStart: TimeInterval? = nil
    
    // Analyze audio in 0.1 second windows
    let windowSize = Int(sampleRate * 0.1)
    
    for i in stride(from: 0, to: frameLength, by: windowSize) {
      let endIndex = min(i + windowSize, frameLength)
      var rms: Float = 0.0
      
      // Calculate RMS for this window
      for j in i..<endIndex {
        let sample = channelData[j]
        rms += sample * sample
      }
      rms = sqrt(rms / Float(endIndex - i))
      
      // Convert to dB
      let dB = 20 * log10(rms + 1e-10)  // Add small value to avoid log(0)
      let currentTime = TimeInterval(i) / sampleRate
      
      if dB < Constants.silenceThreshold {
        // Silence detected
        if silenceStart == nil {
          silenceStart = currentTime
        }
      } else {
        // Sound detected
        if let start = silenceStart {
          let silenceDuration = currentTime - start
          if silenceDuration >= Constants.minimumSilenceDuration {
            // Found meaningful silence - use middle point as break
            silenceBreaks.append(start + silenceDuration / 2)
          }
          silenceStart = nil
        }
      }
    }
    
    DebugLogger.logInfo("STT-CHUNKING: Detected \(silenceBreaks.count) silence breaks")
    return silenceBreaks
  }
  
  // MARK: - Audio Splitting
  private func splitAudioIntelligently(_ audioURL: URL) -> [URL] {
    let audioDuration = getAudioDuration(audioURL)
    let audioSize = getAudioSize(audioURL)
    
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: splitAudioIntelligently() called")
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Audio duration: \(audioDuration)s, size: \(audioSize) bytes")
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Limits - Duration: \(Constants.maxChunkDuration)s, Size: \(Constants.maxChunkSize) bytes")
    
    // Check if chunking is needed
    if audioDuration <= Constants.maxChunkDuration && audioSize <= Constants.maxChunkSize {
      DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Audio is small enough, no chunking needed")
      return [audioURL]
    }
    
    // 1. Try silence-based splitting first
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Attempting silence detection...")
    let silenceBreaks = detectSilencePauses(audioURL)
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Found \(silenceBreaks.count) silence breaks: \(silenceBreaks)")
    if !silenceBreaks.isEmpty {
      DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Using silence-based splitting")
      return splitAudioAtSilence(audioURL, breaks: silenceBreaks)
    }
    
    // 2. Fallback: Time-based splitting
    if audioDuration > Constants.maxChunkDuration {
      DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Using time-based splitting (duration \(audioDuration)s > \(Constants.maxChunkDuration)s)")
      return splitAudioByTime(audioURL)
    }
    
    // 3. Fallback: Size-based splitting
    if audioSize > Constants.maxChunkSize {
      DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Using size-based splitting (size \(audioSize) > \(Constants.maxChunkSize))")
      return splitAudioBySize(audioURL)
    }
    
    // Should not reach here, but return original as fallback
    return [audioURL]
  }
  
  private func splitAudioAtSilence(_ audioURL: URL, breaks: [TimeInterval]) -> [URL] {
    var chunkURLs: [URL] = []
    let audioDuration = getAudioDuration(audioURL)
    
    var startTime: TimeInterval = 0
    
    for breakTime in breaks {
      // Only create chunk if it's long enough and not too long
      let chunkDuration = breakTime - startTime
      if chunkDuration >= 10.0 && chunkDuration <= Constants.maxChunkDuration {
        if let chunkURL = extractAudioSegment(audioURL, start: startTime, duration: chunkDuration) {
          chunkURLs.append(chunkURL)
          startTime = max(0, breakTime - Constants.chunkOverlapDuration)  // Add overlap
        }
      } else if chunkDuration > Constants.maxChunkDuration {
        // Chunk too long, split by time
        let timeChunks = splitAudioByTimeRange(audioURL, start: startTime, end: breakTime)
        chunkURLs.append(contentsOf: timeChunks)
        startTime = max(0, breakTime - Constants.chunkOverlapDuration)
      }
    }
    
    // Handle remaining audio
    if startTime < audioDuration - 5.0 {  // At least 5 seconds remaining
      let remainingDuration = audioDuration - startTime
      if let finalChunk = extractAudioSegment(audioURL, start: startTime, duration: remainingDuration) {
        chunkURLs.append(finalChunk)
      }
    }
    
    return chunkURLs
  }
  
  private func splitAudioByTime(_ audioURL: URL) -> [URL] {
    let audioDuration = getAudioDuration(audioURL)
    var chunkURLs: [URL] = []
    var startTime: TimeInterval = 0
    
    while startTime < audioDuration {
      let remainingDuration = audioDuration - startTime
      let chunkDuration = min(Constants.maxChunkDuration, remainingDuration)
      
      if let chunkURL = extractAudioSegment(audioURL, start: startTime, duration: chunkDuration) {
        chunkURLs.append(chunkURL)
      }
      
      startTime += chunkDuration - Constants.chunkOverlapDuration  // Add overlap
      if startTime >= audioDuration - Constants.chunkOverlapDuration {
        break
      }
    }
    
    return chunkURLs
  }
  
  private func splitAudioByTimeRange(_ audioURL: URL, start: TimeInterval, end: TimeInterval) -> [URL] {
    var chunkURLs: [URL] = []
    var currentStart = start
    
    while currentStart < end {
      let remainingDuration = end - currentStart
      let chunkDuration = min(Constants.maxChunkDuration, remainingDuration)
      
      if let chunkURL = extractAudioSegment(audioURL, start: currentStart, duration: chunkDuration) {
        chunkURLs.append(chunkURL)
      }
      
      currentStart += chunkDuration - Constants.chunkOverlapDuration
      if currentStart >= end - Constants.chunkOverlapDuration {
        break
      }
    }
    
    return chunkURLs
  }
  
  private func splitAudioBySize(_ audioURL: URL) -> [URL] {
    // For size-based splitting, we estimate based on duration
    // This is a simplified approach - in practice, audio compression varies
    let audioDuration = getAudioDuration(audioURL)
    let audioSize = getAudioSize(audioURL)
    let bytesPerSecond = Double(audioSize) / audioDuration
    let maxDurationForSize = Double(Constants.maxChunkSize) / bytesPerSecond
    
    let effectiveMaxDuration = min(maxDurationForSize, Constants.maxChunkDuration)
    
    var chunkURLs: [URL] = []
    var startTime: TimeInterval = 0
    
    while startTime < audioDuration {
      let remainingDuration = audioDuration - startTime
      let chunkDuration = min(effectiveMaxDuration, remainingDuration)
      
      if let chunkURL = extractAudioSegment(audioURL, start: startTime, duration: chunkDuration) {
        chunkURLs.append(chunkURL)
      }
      
      startTime += chunkDuration - Constants.chunkOverlapDuration
      if startTime >= audioDuration - Constants.chunkOverlapDuration {
        break
      }
    }
    
    return chunkURLs
  }
  
  private func extractAudioSegment(_ audioURL: URL, start: TimeInterval, duration: TimeInterval) -> URL? {
    let tempDir = FileManager.default.temporaryDirectory
    let segmentURL = tempDir.appendingPathComponent("audio_chunk_\(UUID().uuidString).m4a")
    
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Extracting segment - start: \(start)s, duration: \(duration)s")
    
    let asset = AVAsset(url: audioURL)
    let assetDuration = CMTimeGetSeconds(asset.duration)
    
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Asset duration: \(assetDuration)s")
    
    // Use M4A preset for better compatibility with Whisper API
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      DebugLogger.logWarning("🔍 DEBUG-CHUNKING: Could not create export session")
      return nil
    }
    
    exportSession.outputURL = segmentURL
    exportSession.outputFileType = .m4a
    
    let startTime = CMTime(seconds: start, preferredTimescale: 1000)
    let endTime = CMTime(seconds: start + duration, preferredTimescale: 1000)
    exportSession.timeRange = CMTimeRange(start: startTime, end: endTime)
    
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Time range - start: \(startTime.seconds)s, end: \(endTime.seconds)s")
    
    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    
    exportSession.exportAsynchronously {
      success = exportSession.status == AVAssetExportSession.Status.completed
      if !success {
        DebugLogger.logError("🔍 DEBUG-CHUNKING: Export failed: \(exportSession.error?.localizedDescription ?? "Unknown error")")
        DebugLogger.logError("🔍 DEBUG-CHUNKING: Export status: \(exportSession.status.rawValue)")
      } else {
        DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Export successful: \(segmentURL.lastPathComponent)")
      }
      semaphore.signal()
    }
    
    semaphore.wait()
    
    return success ? segmentURL : nil
  }
  
  // MARK: - Chunked Transcription
  private func transcribeAudioChunked(_ audioURL: URL) async throws -> String {
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: transcribeAudioChunked() called")
    let chunks = splitAudioIntelligently(audioURL)
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: splitAudioIntelligently returned \(chunks.count) chunks")
    
    if chunks.count == 1 {
      DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Single chunk, using regular transcription")
      return try await transcribeSingleChunk(chunks[0])
    }
    
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Transcribing \(chunks.count) audio chunks")
    
    var transcriptions: [String] = []
    
    // Process chunks sequentially to maintain order
    for (index, chunkURL) in chunks.enumerated() {
      DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Processing chunk \(index + 1)/\(chunks.count)")
      DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Chunk URL: \(chunkURL.lastPathComponent)")
      
      let transcription = await transcribeChunkWithRetry(chunkURL, chunkIndex: index + 1, totalChunks: chunks.count)
      transcriptions.append(transcription)
      
      // Clean up temporary chunk file
      try? FileManager.default.removeItem(at: chunkURL)
    }
    
    // Merge transcriptions intelligently
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Merging \(transcriptions.count) transcriptions...")
    let mergedTranscription = mergeTranscriptions(transcriptions)
    DebugLogger.logSuccess("🔍 DEBUG-CHUNKING: Successfully merged \(chunks.count) transcriptions, final length: \(mergedTranscription.count) chars")
    
    return mergedTranscription
  }
  
  private func transcribeChunkWithRetry(_ audioURL: URL, chunkIndex: Int, totalChunks: Int) async -> String {
    var lastError: Error?
    
    for attempt in 1...Constants.maxRetryAttempts {
      do {
        let transcription = try await transcribeSingleChunk(audioURL)
        if attempt > 1 {
          DebugLogger.logSuccess("🔍 RETRY-CHUNKING: Chunk \(chunkIndex) succeeded on attempt \(attempt)")
        }
        return transcription
      } catch {
        lastError = error
        DebugLogger.logWarning("🔍 RETRY-CHUNKING: Chunk \(chunkIndex) attempt \(attempt) failed: \(error)")
        
        if attempt < Constants.maxRetryAttempts {
          DebugLogger.logInfo("🔍 RETRY-CHUNKING: Retrying chunk \(chunkIndex) in \(Constants.retryDelaySeconds)s...")
          try? await Task.sleep(nanoseconds: UInt64(Constants.retryDelaySeconds * 1_000_000_000))
        }
      }
    }
    
    // All retries failed
    DebugLogger.logError("🔍 RETRY-CHUNKING: Chunk \(chunkIndex) failed after \(Constants.maxRetryAttempts) attempts")
    return "[Transcription failed for segment \(chunkIndex) after \(Constants.maxRetryAttempts) attempts: \(lastError?.localizedDescription ?? "Unknown error")]"
  }
  
  private func transcribeSingleChunk(_ audioURL: URL) async throws -> String {
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: transcribeSingleChunk() called for: \(audioURL.lastPathComponent)")
    
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      DebugLogger.logError("🔍 DEBUG-CHUNKING: No API key available for chunk transcription")
      throw TranscriptionError.noAPIKey
    }
    
    // Detailed chunk file validation
    do {
      try validateAudioFile(at: audioURL)
      DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Chunk file validation passed")
    } catch {
      DebugLogger.logError("🔍 DEBUG-CHUNKING: Chunk file validation failed: \(error)")
      throw error
    }
    
    // Log chunk file details
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
    let audioDuration = getAudioDuration(audioURL)
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Chunk details - Size: \(fileSize) bytes, Duration: \(audioDuration)s")
    
    let request = try createTranscriptionRequest(audioURL: audioURL, apiKey: apiKey)
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Created transcription request for chunk")
    
    let (data, response) = try await session.data(for: request)
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Received response for chunk - Data size: \(data.count) bytes")
    
    guard let httpResponse = response as? HTTPURLResponse else {
      DebugLogger.logError("🔍 DEBUG-CHUNKING: Invalid response type for chunk")
      throw TranscriptionError.networkError("Invalid response")
    }
    
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: HTTP Status Code: \(httpResponse.statusCode)")
    
    if httpResponse.statusCode != 200 {
      DebugLogger.logError("🔍 DEBUG-CHUNKING: HTTP error \(httpResponse.statusCode) for chunk")
      
      // Log detailed error response
      if let errorString = String(data: data, encoding: .utf8) {
        DebugLogger.logError("🔍 DEBUG-CHUNKING: Error response body: \(errorString)")
      } else {
        DebugLogger.logError("🔍 DEBUG-CHUNKING: Error response body could not be decoded as UTF-8")
      }
      
      // Try to parse structured error
      if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
        DebugLogger.logError("🔍 DEBUG-CHUNKING: OpenAI Error - Type: \(errorResponse.error?.type ?? "unknown"), Message: \(errorResponse.error?.message ?? "unknown")")
      }
      
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }
    
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Successful response, attempting to decode JSON")
    
    do {
      let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
      DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Successfully decoded transcription result: '\(result.text.prefix(50))...'")
      return result.text
    } catch {
      DebugLogger.logError("🔍 DEBUG-CHUNKING: Failed to decode JSON response: \(error)")
      if let responseString = String(data: data, encoding: .utf8) {
        DebugLogger.logError("🔍 DEBUG-CHUNKING: Raw response: \(responseString)")
      }
      throw TranscriptionError.networkError("Failed to decode transcription response")
    }
  }
  
  private func mergeTranscriptions(_ transcriptions: [String]) -> String {
    guard !transcriptions.isEmpty else { return "" }
    
    if transcriptions.count == 1 {
      return transcriptions[0].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var merged = transcriptions[0].trimmingCharacters(in: .whitespacesAndNewlines)
    
    for i in 1..<transcriptions.count {
      let current = transcriptions[i].trimmingCharacters(in: .whitespacesAndNewlines)
      
      // Try to find overlap between end of merged and start of current
      let overlap = findTranscriptionOverlap(merged, current)
      
      if overlap.count > 5 {  // Meaningful overlap found
        // Remove overlap from current transcription
        let remainingCurrent = String(current.dropFirst(overlap.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainingCurrent.isEmpty {
          merged += " " + remainingCurrent
        }
      } else {
        // No meaningful overlap, just concatenate with space
        if !current.isEmpty {
          merged += " " + current
        }
      }
    }
    
    return merged
  }
  
  private func findTranscriptionOverlap(_ text1: String, _ text2: String) -> String {
    let words1 = text1.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    let words2 = text2.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    
    var maxOverlap = ""
    
    // Look for overlapping word sequences (minimum 2 words)
    for i in max(0, words1.count - 10)..<words1.count {
      for j in 0..<min(words2.count, 10) {
        let suffix = Array(words1[i...])
        let prefix = Array(words2[0...j])
        
        if suffix.count >= 2 && prefix.count >= 2 && suffix == prefix {
          let overlap = suffix.joined(separator: " ")
          if overlap.count > maxOverlap.count {
            maxOverlap = overlap
          }
        }
      }
    }
    
    return maxOverlap
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
    // Keep a small safety margin under provider limit for JSON overhead
    let maxLen = max(512, TTSService.maxAllowedTextLength - 64)
    let chunks = splitTextForTTS(text, maxLen: maxLen)
    if chunks.isEmpty { return }

    DebugLogger.logInfo("TTS-CHUNKING: Playing text in \(chunks.count) chunk(s)")

    for (index, chunk) in chunks.enumerated() {
      DebugLogger.logInfo(
        "TTS-CHUNKING: Generating audio for chunk \(index + 1)/\(chunks.count) (\(chunk.count) chars)")
    let audioData: Data
    do {
        audioData = try await ttsService.generateSpeech(text: chunk, speed: speed)
    } catch let ttsError as TTSError {
        DebugLogger.logError("TTS-CHUNKING: TTS error on chunk \(index + 1): \(ttsError.localizedDescription)")
      throw TranscriptionError.ttsError(ttsError)
    } catch {
        DebugLogger.logError("TTS-CHUNKING: Unexpected TTS error on chunk \(index + 1): \(error.localizedDescription)")
      throw TranscriptionError.networkError("Text-to-speech failed: \(error.localizedDescription)")
    }

      let result = try await audioPlaybackService.playAudio(data: audioData, playbackType: playbackType)
      switch result {
      case .completedSuccessfully:
        continue
      case .stoppedByUser:
        DebugLogger.logInfo("TTS-CHUNKING: Playback stopped by user at chunk \(index + 1)")
        return
      case .failed:
        DebugLogger.logError("TTS-CHUNKING: Audio playback failed at chunk \(index + 1)")
        throw TranscriptionError.networkError("Audio playback failed")
      }
    }
  }

  func readSelectedTextAsSpeech() async throws -> String {
    captureSelectedText()
    try await Task.sleep(nanoseconds: Constants.clipboardCopyDelay)

    guard let selectedText = getClipboardContext(), !selectedText.isEmpty else {
      DebugLogger.logWarning("SELECTED-TEXT-TTS: No text found in selection")
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
    guard let clipboardText = clipboardManager.getClipboardText() else { return nil }

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

  private func executeGPT5Prompt(userMessage: String, clipboardContext: String?, apiKey: String)
    async throws -> String
  {
    return try await executeGPT5Response(
      userMessage: userMessage, clipboardContext: clipboardContext, apiKey: apiKey,
      isVoiceResponse: false)
  }

  private func executeGPT5PromptForVoiceResponse(
    userMessage: String, clipboardContext: String?, apiKey: String
  )
    async throws -> String
  {
    return try await executeGPT5Response(
      userMessage: userMessage, clipboardContext: clipboardContext, apiKey: apiKey,
      isVoiceResponse: true)
  }

  private func executeGPT5Response(
    userMessage: String, clipboardContext: String?, apiKey: String, isVoiceResponse: Bool = false
  )
    async throws -> String
  {
    let modelKey = isVoiceResponse ? "selectedVoiceResponseModel" : "selectedPromptModel"
    let selectedGPTModelString =
      UserDefaults.standard.string(forKey: modelKey) ?? "gpt-5-mini"
    let selectedGPTModel = GPTModel(rawValue: selectedGPTModelString) ?? .gpt5Mini

    let url = URL(string: Constants.responsesEndpoint)!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let fullInput = buildPromptInput(
      userMessage: userMessage, clipboardContext: clipboardContext, isVoiceResponse: isVoiceResponse
    )

    let reasoningConfig: GPT5ResponseRequest.ReasoningConfig?
    if selectedGPTModel.supportsReasoning {
      let reasoningEffortKey =
        isVoiceResponse ? "voiceResponseReasoningEffort" : "promptReasoningEffort"
      let defaultReasoningEffort =
        isVoiceResponse
        ? SettingsDefaults.voiceResponseReasoningEffort.rawValue
        : SettingsDefaults.promptReasoningEffort.rawValue
      let savedReasoningEffort =
        UserDefaults.standard.string(forKey: reasoningEffortKey) ?? defaultReasoningEffort
      reasoningConfig = GPT5ResponseRequest.ReasoningConfig(effort: savedReasoningEffort)
      DebugLogger.logInfo(
        "PROMPT-MODE: Using reasoning effort '\(savedReasoningEffort)' for model \(selectedGPTModel.rawValue)"
      )
    } else {
      reasoningConfig = nil
      DebugLogger.logInfo(
        "PROMPT-MODE: Model \(selectedGPTModel.rawValue) does not support reasoning parameters")
    }

    let effectivePreviousResponseId = isConversationExpired(isVoiceResponse: isVoiceResponse)
      ? nil : previousResponseId

    let gpt5Request = GPT5ResponseRequest(
      model: selectedGPTModel.rawValue,
      input: fullInput,
      reasoning: reasoningConfig,
      text: GPT5ResponseRequest.TextConfig(verbosity: "medium"),
      previous_response_id: effectivePreviousResponseId
    )

    request.httpBody = try JSONEncoder().encode(gpt5Request)

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      DebugLogger.logWarning("PROMPT-MODE: Invalid response type from GPT-5")
      throw TranscriptionError.networkError("Invalid response")
    }

    if httpResponse.statusCode != 200 {
      DebugLogger.logWarning("PROMPT-MODE: GPT-5 HTTP error \(httpResponse.statusCode)")
      if let errorBody = String(data: data, encoding: .utf8) {
        DebugLogger.logWarning("PROMPT-MODE: Error response body: \(errorBody)")
      }
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    let result = try parseGPT5Response(data: data)
    return result
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

  private func parseGPT5Response(data: Data) throws -> String {
    do {
      let result = try JSONDecoder().decode(GPT5ResponseResponse.self, from: data)

      previousResponseId = result.id
      previousResponseTimestamp = Date()

      for output in result.output {
        if output.type == "message" {
          for content in output.content ?? [] {
            if content.type == "output_text" {
              return content.text
            }
          }
        }
      }

      if (try? JSONSerialization.jsonObject(with: data, options: [])) != nil {
        DebugLogger.logWarning(
          "PROMPT-MODE: Unexpected response structure, attempting fallback parsing")
      }

      throw TranscriptionError.networkError("Could not extract text from GPT-5 response")
    } catch {
      if (try? JSONSerialization.jsonObject(with: data, options: [])) != nil {
        DebugLogger.logWarning("PROMPT-MODE: Failed to decode response, raw structure available")
      }

      throw error
    }
  }

  // MARK: - Testing and Debugging
  func testGPT5Request() async throws -> String {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else {
      DebugLogger.logWarning("TEST: No API key available")
      throw TranscriptionError.noAPIKey
    }

    let testRequest = GPT5ResponseRequest(
      model: "gpt-5-chat-latest",
      input: "Hello, this is a test message.",
      reasoning: nil,
      text: nil,
      previous_response_id: nil
    )

    let url = URL(string: Constants.responsesEndpoint)!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    request.httpBody = try JSONEncoder().encode(testRequest)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      DebugLogger.logWarning("TEST: Invalid response type")
      throw TranscriptionError.networkError("Invalid response type")
    }

    if httpResponse.statusCode != 200 {
      DebugLogger.logWarning("TEST: HTTP error \(httpResponse.statusCode)")
      if let errorBody = String(data: data, encoding: .utf8) {
        DebugLogger.logWarning("TEST: Error body: \(errorBody)")
      }
      let error = try parseErrorResponse(data: data, statusCode: httpResponse.statusCode)
      throw error
    }

    let result = try JSONDecoder().decode(GPT5ResponseResponse.self, from: data)

    for output in result.output {
      if output.type == "message" {
        for content in output.content ?? [] {
          if content.type == "output_text" {
            return content.text
          }
        }
      }
    }

    throw TranscriptionError.networkError("Could not extract text from test response")
  }

  // MARK: - Shared Infrastructure Helpers
  private func validateAudioFile(at url: URL) throws {
    let fileExtension = url.pathExtension.lowercased()
    if !Constants.supportedAudioExtensions.contains(fileExtension) {
      DebugLogger.logWarning("Unsupported audio format: \(fileExtension)")
      throw TranscriptionError.fileError("Unsupported audio format: \(fileExtension)")
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let fileSize = attributes[.size] as? Int64 else {
      DebugLogger.logWarning("Cannot read file size")
      throw TranscriptionError.fileError("Cannot read file size")
    }

    if fileSize == 0 {
      DebugLogger.logWarning("Empty audio file")
      throw TranscriptionError.emptyFile
    }

    if fileSize > Constants.maxFileSize {
      DebugLogger.logWarning("File too large (\(fileSize) > \(Constants.maxFileSize))")
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
    DebugLogger.logInfo("🔍 SERVER-CHUNKING: Using auto chunking for optimal transcription quality")

    if selectedTranscriptionModel == .gpt4oTranscribe
      || selectedTranscriptionModel == .gpt4oMiniTranscribe
    {
      if let customPrompt = UserDefaults.standard.string(forKey: "customPromptText"),
        !customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        fields["prompt"] = customPrompt
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
    
    DebugLogger.logInfo("🔍 DEBUG-CHUNKING: Using content type: \(contentType), filename: \(filename)")
    
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

// MARK: - Models
struct WhisperResponse: Codable {
  let text: String
}

struct ChatCompletionRequest: Codable {
  let model: String
  let messages: [ChatMessage]
  let maxTokens: Int
  let temperature: Double

  enum CodingKeys: String, CodingKey {
    case model, messages, temperature
    case maxTokens = "max_tokens"
  }
}

struct ChatMessage: Codable {
  let role: String
  let content: String
}

struct ChatCompletionResponse: Codable {
  let choices: [ChatChoice]
}

struct ChatChoice: Codable {
  let message: ChatMessage
}

// GPT-5 Responses API Models (New)
struct GPT5ResponseRequest: Codable {
  let model: String
  let input: String
  let reasoning: ReasoningConfig?
  let text: TextConfig?
  let previous_response_id: String?

  struct ReasoningConfig: Codable {
    let effort: String
  }

  struct TextConfig: Codable {
    let verbosity: String
  }
}

struct GPT5ResponseResponse: Codable {
  let output: [GPT5Output]
  let id: String

  struct GPT5Output: Codable {
    let type: String
    let content: [GPT5Content]?

    struct GPT5Content: Codable {
      let type: String
      let text: String
    }
  }
}

struct TranscriptionPrompt {
  let text: String

  static let defaultPrompt = TranscriptionPrompt(
    text: AppConstants.defaultTranscriptionSystemPrompt)
}

struct OpenAIErrorResponse: Codable {
  let error: OpenAIError?
}

struct OpenAIError: Codable {
  let message: String?
  let type: String?
  let code: String?
}

// MARK: - Error Types
enum TranscriptionError: Error, Equatable {
  case noAPIKey
  case invalidAPIKey
  case incorrectAPIKey
  case countryNotSupported
  case invalidRequest
  case permissionDenied
  case notFound
  case rateLimited
  case quotaExceeded
  case serverError(Int)
  case serviceUnavailable
  case slowDown
  case networkError(String)
  case fileError(String)
  case fileTooLarge
  case emptyFile
  case noSpeechDetected
  case ttsError(TTSError)

  var title: String {
    switch self {
    case .noAPIKey: return "No API Key"
    case .invalidAPIKey: return "Invalid Authentication"
    case .incorrectAPIKey: return "Incorrect API Key"
    case .countryNotSupported: return "Country Not Supported"
    case .invalidRequest: return "Invalid Request"
    case .permissionDenied: return "Permission Denied"
    case .notFound: return "Not Found"
    case .rateLimited: return "Rate Limited"
    case .quotaExceeded: return "Quota Exceeded"
    case .serverError: return "Server Error"
    case .serviceUnavailable: return "Service Unavailable"
    case .slowDown: return "Slow Down"
    case .networkError: return "Network Error"
    case .fileError: return "File Error"
    case .fileTooLarge: return "File Too Large"
    case .emptyFile: return "Empty File"
    case .noSpeechDetected: return "No Speech Detected"
    case .ttsError: return "Text-to-Speech Error"
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

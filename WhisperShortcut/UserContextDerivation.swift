import Foundation

// MARK: - User Context Derivation
/// Service that analyzes interaction logs via Gemini to derive user context,
/// suggested system prompts, and difficult words.
class UserContextDerivation {

  private let maxEntriesPerMode = 50
  private let maxFieldChars = 2000
  private let maxTotalChars = 100_000
  private var analysisEndpoint: String { AppConstants.userContextDerivationEndpoint }

  // MARK: - Markers for parsing
  private let userContextMarker = "===USER_CONTEXT_START==="
  private let userContextEndMarker = "===USER_CONTEXT_END==="
  private let systemPromptMarker = "===SUGGESTED_SYSTEM_PROMPT_START==="
  private let systemPromptEndMarker = "===SUGGESTED_SYSTEM_PROMPT_END==="
  private let difficultWordsMarker = "===SUGGESTED_DIFFICULT_WORDS_START==="
  private let difficultWordsEndMarker = "===SUGGESTED_DIFFICULT_WORDS_END==="

  // MARK: - Main Entry Point

  /// Analyzes interaction logs and derives user context files.
  /// Throws if no API key or if the Gemini request fails.
  func updateContextFromLogs() async throws {
    guard let apiKey = KeychainManager.shared.getGoogleAPIKey(), !apiKey.isEmpty else {
      throw TranscriptionError.noGoogleAPIKey
    }

    DebugLogger.log("USER-CONTEXT-DERIVATION: Starting context update")

    // 1. Load and sample interaction logs
    let aggregatedText = try loadAndSampleLogs()
    guard !aggregatedText.isEmpty else {
      DebugLogger.logWarning("USER-CONTEXT-DERIVATION: No interaction logs found")
      throw TranscriptionError.networkError("No interaction logs found. Use the app for a while with logging enabled, then try again.")
    }

    DebugLogger.log("USER-CONTEXT-DERIVATION: Aggregated \(aggregatedText.count) chars of interaction data")

    // 2. Load current system prompt and existing user context so Gemini can refine them
    let currentPromptModeSystemPrompt = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptModeSystemPrompt)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentPromptAndReadSystemPrompt = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptAndReadSystemPrompt)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let existingUserContext = loadExistingUserContextFile()

    // 3. Call Gemini to analyze (with existing context so it can refine, not replace)
    let analysisResult = try await callGeminiForAnalysis(
      aggregatedText: aggregatedText,
      currentPromptModeSystemPrompt: currentPromptModeSystemPrompt,
      currentPromptAndReadSystemPrompt: currentPromptAndReadSystemPrompt,
      existingUserContext: existingUserContext,
      apiKey: apiKey
    )

    // 4. Parse and write output files
    try writeOutputFiles(analysisResult: analysisResult)

    DebugLogger.logSuccess("USER-CONTEXT-DERIVATION: Context update completed")
  }

  // MARK: - Load Existing Context (for refinement)

  /// Reads existing user-context.md so Gemini can refine it. Ignores the "include in prompt" toggle.
  private func loadExistingUserContextFile() -> String? {
    let url = UserContextLogger.shared.directoryURL.appendingPathComponent("user-context.md")
    guard FileManager.default.fileExists(atPath: url.path),
          let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  // MARK: - Log Loading & Sampling

  private func loadAndSampleLogs() throws -> String {
    let logFiles = UserContextLogger.shared.interactionLogFiles(lastDays: 30)
    guard !logFiles.isEmpty else { return "" }

    // Parse all entries
    var entriesByMode: [String: [InteractionLogEntry]] = [:]
    let decoder = JSONDecoder()

    for fileURL in logFiles {
      guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
      let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

      for line in lines {
        guard let data = line.data(using: .utf8) else { continue }
        guard let entry = try? decoder.decode(InteractionLogEntry.self, from: data) else { continue }
        entriesByMode[entry.mode, default: []].append(entry)
      }
    }

    // Sample max entries per mode (evenly spaced)
    var sampledEntries: [InteractionLogEntry] = []
    for (_, entries) in entriesByMode {
      if entries.count <= maxEntriesPerMode {
        sampledEntries.append(contentsOf: entries)
      } else {
        let step = Double(entries.count) / Double(maxEntriesPerMode)
        for i in 0..<maxEntriesPerMode {
          let index = Int(Double(i) * step)
          sampledEntries.append(entries[index])
        }
      }
    }

    // Build aggregated text with truncated fields
    var parts: [String] = []
    var totalChars = 0

    for entry in sampledEntries {
      var entryParts: [String] = ["mode: \(entry.mode)"]

      if let result = entry.result {
        entryParts.append("result: \(String(result.prefix(maxFieldChars)))")
      }
      if let selectedText = entry.selectedText {
        entryParts.append("selectedText: \(String(selectedText.prefix(maxFieldChars)))")
      }
      if let userInstruction = entry.userInstruction {
        entryParts.append("userInstruction: \(String(userInstruction.prefix(maxFieldChars)))")
      }
      if let modelResponse = entry.modelResponse {
        entryParts.append("modelResponse: \(String(modelResponse.prefix(maxFieldChars)))")
      }
      if let text = entry.text {
        entryParts.append("text: \(String(text.prefix(maxFieldChars)))")
      }

      let entryText = entryParts.joined(separator: " | ")

      if totalChars + entryText.count > maxTotalChars {
        break  // Drop oldest-last (we process in chronological order)
      }

      parts.append(entryText)
      totalChars += entryText.count
    }

    return parts.joined(separator: "\n---\n")
  }

  // MARK: - Gemini Analysis

  private func callGeminiForAnalysis(
    aggregatedText: String,
    currentPromptModeSystemPrompt: String?,
    currentPromptAndReadSystemPrompt: String?,
    existingUserContext: String?,
    apiKey: String
  ) async throws -> String {
    let geminiClient = GeminiAPIClient()

    var request = try geminiClient.createRequest(endpoint: analysisEndpoint, apiKey: apiKey)

    let systemPrompt = """
    You are analyzing a user's interaction history with a voice-to-text application called WhisperShortcut. \
    The app has these modes: transcription (speech-to-text), prompt (voice instructions that modify clipboard text), \
    promptAndRead (same as prompt but reads result aloud), and readAloud (text-to-speech).

    CRITICAL – How to treat transcription/dictation text:
    Entries with mode "transcription" (and the "result" field) are raw speech-to-text output. They often contain recognition errors: wrong words (e.g. "Jason" instead of "das Dateiende"), homophones, misspelled names or technical terms. Do NOT take these transcriptions literally. Use the surrounding context (topic, other interactions, language, typical usage) to infer what the user likely meant. When you derive user context, difficult words, or system prompt suggestions, reason about the most probable intended words and base your output on that interpretation, not on the literal transcription.

    Based on the interaction data below (and any existing user context / system prompt provided), produce three sections separated by markers. \
    Refine and build on existing context when it is provided; do not ignore it. Be concise and practical.

    Section 1: User Context (between \(userContextMarker) and \(userContextEndMarker))
    Write a brief user profile (max 500 words) covering:
    - What language(s) they use
    - Common topics they work with
    - Writing style preferences (formal/casual, etc.)
    - Frequent types of requests
    - Any domain-specific terminology patterns
    If existing user context was provided, extend and update it with new insights from the interactions; do not start from scratch.

    Section 2: Suggested System Prompt (between \(systemPromptMarker) and \(systemPromptEndMarker))
    Write a suggested system prompt for the prompt mode that would work well for this user. \
    If a current system prompt was provided, refine it based on the new interaction data (e.g. add instructions that match how the user actually uses the app); keep what still works and improve the rest. Keep the result under 300 words.

    Section 3: Suggested Difficult Words (between \(difficultWordsMarker) and \(difficultWordsEndMarker))
    List ONLY words where dictation likely went wrong. Rule: Look at "transcription" (dictation) results. If a word in the transcription makes NO or little sense in context, but a different (e.g. similar-sounding or homophone) word would make MUCH more sense, then the user probably said that other word – list that intended word (correct spelling). These are the words to add so future dictation gets them right. Do NOT list: words that already fit the context; common words; domain terms that were transcribed correctly; anything where you are not confident there was a recognition error. Only clear cases: wrong word in transcript + obvious intended word from context. One word/phrase per line. Max 30 entries. When in doubt, omit. Prefer a short, precise list over many guesses.
    """

    var userMessageParts: [String] = []

    if let existing = existingUserContext, !existing.isEmpty {
      userMessageParts.append("Existing user context (refine and extend this):\n\(existing)")
    }
    if let prompt = currentPromptModeSystemPrompt, !prompt.isEmpty {
      userMessageParts.append("Current Prompt Mode system prompt (refine based on new data):\n\(prompt)")
    }
    if let promptRead = currentPromptAndReadSystemPrompt, !promptRead.isEmpty, promptRead != currentPromptModeSystemPrompt {
      userMessageParts.append("Current Prompt & Read system prompt (refine based on new data):\n\(promptRead)")
    }

    userMessageParts.append("User's recent interactions:\n\n\(aggregatedText)")
    let userMessage = userMessageParts.joined(separator: "\n\n---\n\n")

    let systemInstruction = GeminiChatRequest.GeminiSystemInstruction(
      parts: [GeminiChatRequest.GeminiSystemPart(text: systemPrompt)]
    )

    let contents = [
      GeminiChatRequest.GeminiChatContent(
        role: "user",
        parts: [
          GeminiChatRequest.GeminiChatPart(text: userMessage, inlineData: nil, fileData: nil, url: nil)
        ]
      )
    ]

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
      mode: "USER-CONTEXT-DERIVATION",
      withRetry: true
    )

    guard let firstCandidate = result.candidates.first else {
      throw TranscriptionError.networkError("No candidates in Gemini response for context derivation")
    }

    var textContent = ""
    for part in firstCandidate.content.parts {
      if let text = part.text {
        textContent += text
      }
    }

    return textContent
  }

  // MARK: - Output File Writing

  private func writeOutputFiles(analysisResult: String) throws {
    let contextDir = UserContextLogger.shared.directoryURL

    // Parse user context
    if let userContext = extractSection(from: analysisResult, startMarker: userContextMarker, endMarker: userContextEndMarker) {
      let fileURL = contextDir.appendingPathComponent("user-context.md")
      try userContext.write(to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote user-context.md (\(userContext.count) chars)")
    }

    // Parse suggested system prompt
    if let suggestedPrompt = extractSection(from: analysisResult, startMarker: systemPromptMarker, endMarker: systemPromptEndMarker) {
      let fileURL = contextDir.appendingPathComponent("suggested-prompt-mode-system-prompt.txt")
      try suggestedPrompt.write(to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested system prompt (\(suggestedPrompt.count) chars)")
    }

    // Parse suggested difficult words
    if let suggestedWords = extractSection(from: analysisResult, startMarker: difficultWordsMarker, endMarker: difficultWordsEndMarker) {
      let fileURL = contextDir.appendingPathComponent("suggested-difficult-words.txt")
      try suggestedWords.write(to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested difficult words (\(suggestedWords.count) chars)")
    }
  }

  private func extractSection(from text: String, startMarker: String, endMarker: String) -> String? {
    guard let startRange = text.range(of: startMarker),
          let endRange = text.range(of: endMarker) else {
      return nil
    }
    let content = String(text[startRange.upperBound..<endRange.lowerBound])
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

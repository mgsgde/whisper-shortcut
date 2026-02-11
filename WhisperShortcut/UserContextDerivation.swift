import Foundation

// MARK: - User Context Derivation
/// Service that analyzes interaction logs via Gemini to derive user context,
/// suggested system prompts, and difficult words.
class UserContextDerivation {

  /// Per-field character cap per log entry; smaller = less payload and faster derivation.
  private let maxFieldChars = 1000
  private var analysisEndpoint: String { AppConstants.userContextDerivationEndpoint }

  /// Result of loading and sampling logs: aggregated text plus stats for UI feedback.
  struct LoadedLogs {
    let text: String
    let entryCount: Int
    let charCount: Int
  }

  // MARK: - Markers for parsing
  private let userContextMarker = "===USER_CONTEXT_START==="
  private let userContextEndMarker = "===USER_CONTEXT_END==="
  private let systemPromptMarker = "===SUGGESTED_SYSTEM_PROMPT_START==="
  private let systemPromptEndMarker = "===SUGGESTED_SYSTEM_PROMPT_END==="
  private let promptAndReadSystemPromptMarker = "===SUGGESTED_PROMPT_AND_READ_SYSTEM_PROMPT_START==="
  private let promptAndReadSystemPromptEndMarker = "===SUGGESTED_PROMPT_AND_READ_SYSTEM_PROMPT_END==="
  private let dictationPromptMarker = "===SUGGESTED_DICTATION_PROMPT_START==="
  private let dictationPromptEndMarker = "===SUGGESTED_DICTATION_PROMPT_END==="

  // MARK: - Main Entry Point

  /// Analyzes interaction logs and derives user context files.
  /// Returns loaded log stats (entry count, char count) for UI feedback. Throws if no API key or if the Gemini request fails.
  func updateContextFromLogs() async throws -> LoadedLogs {
    guard let apiKey = KeychainManager.shared.getGoogleAPIKey(), !apiKey.isEmpty else {
      throw TranscriptionError.noGoogleAPIKey
    }

    DebugLogger.log("USER-CONTEXT-DERIVATION: Starting context update")

    // 1. Load and sample interaction logs (tiered recency + char limit)
    let loaded = try loadAndSampleLogs()
    guard !loaded.text.isEmpty else {
      DebugLogger.logWarning("USER-CONTEXT-DERIVATION: No interaction logs found")
      throw TranscriptionError.networkError("No interaction logs found. Use the app for a while with logging enabled, then try again.")
    }

    DebugLogger.log("USER-CONTEXT-DERIVATION: Aggregated \(loaded.entryCount) entries, \(loaded.charCount) chars")

    // 2. Load current system prompt and existing user context so Gemini can refine them
    let currentPromptModeSystemPrompt = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptModeSystemPrompt)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentPromptAndReadSystemPrompt = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptAndReadSystemPrompt)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentDictationPrompt = (UserDefaults.standard.string(forKey: UserDefaultsKeys.customPromptText) ?? AppConstants.defaultTranscriptionSystemPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
    let existingUserContext = loadExistingUserContextFile()

    // 3. Call Gemini to analyze (with existing context so it can refine, not replace)
    let analysisResult = try await callGeminiForAnalysis(
      aggregatedText: loaded.text,
      currentPromptModeSystemPrompt: currentPromptModeSystemPrompt,
      currentPromptAndReadSystemPrompt: currentPromptAndReadSystemPrompt,
      currentDictationPrompt: currentDictationPrompt,
      existingUserContext: existingUserContext,
      apiKey: apiKey
    )

    // 4. Parse and write output files
    try writeOutputFiles(analysisResult: analysisResult)

    DebugLogger.logSuccess("USER-CONTEXT-DERIVATION: Context update completed")
    return loaded
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

  private func loadAndSampleLogs() throws -> LoadedLogs {
    let maxPerMode = UserDefaults.standard.object(forKey: UserDefaultsKeys.userContextMaxEntriesPerMode) as? Int
      ?? AppConstants.userContextDefaultMaxEntriesPerMode
    let maxChars = UserDefaults.standard.object(forKey: UserDefaultsKeys.userContextMaxTotalChars) as? Int
      ?? AppConstants.userContextDefaultMaxTotalChars

    let logFiles = UserContextLogger.shared.interactionLogFiles(lastDays: AppConstants.userContextTier3Days)
    guard !logFiles.isEmpty else { return LoadedLogs(text: "", entryCount: 0, charCount: 0) }

    // Parse all entries, grouped by mode
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

    // Sort each mode's entries by timestamp (chronological) for tier split and even sampling
    let now = Date()
    let tier1Cutoff = Calendar.current.date(byAdding: .day, value: -AppConstants.userContextTier1Days, to: now) ?? now
    let tier2Cutoff = Calendar.current.date(byAdding: .day, value: -AppConstants.userContextTier2Days, to: now) ?? now

    var sampledEntries: [InteractionLogEntry] = []
    for (_, entries) in entriesByMode {
      let sortedEntries = entries.sorted { $0.ts < $1.ts }
      let tier1 = sortedEntries.filter { parseDate($0.ts) >= tier1Cutoff }
      let tier2 = sortedEntries.filter { entry in
        let d = parseDate(entry.ts)
        return d < tier1Cutoff && d >= tier2Cutoff
      }
      let tier3 = sortedEntries.filter { parseDate($0.ts) < tier2Cutoff }

      let budget1 = Int(Double(maxPerMode) * AppConstants.userContextTier1Ratio)
      let budget2 = Int(Double(maxPerMode) * AppConstants.userContextTier2Ratio)
      let budget3 = maxPerMode - budget1 - budget2

      sampledEntries.append(contentsOf: evenSample(tier1, max: budget1))
      sampledEntries.append(contentsOf: evenSample(tier2, max: budget2))
      sampledEntries.append(contentsOf: evenSample(tier3, max: budget3))
    }

    // Sort by timestamp (oldest first) so when we hit char limit we drop oldest and keep newest
    sampledEntries.sort { $0.ts < $1.ts }

    // Build aggregated text with truncated fields; stop at maxChars (oldest dropped first)
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

      if totalChars + entryText.count > maxChars {
        break
      }

      parts.append(entryText)
      totalChars += entryText.count
    }

    let text = parts.joined(separator: "\n---\n")
    return LoadedLogs(text: text, entryCount: parts.count, charCount: totalChars)
  }

  private func evenSample(_ entries: [InteractionLogEntry], max count: Int) -> [InteractionLogEntry] {
    guard entries.count > count else { return entries }
    let step = Double(entries.count) / Double(count)
    return (0..<count).map { entries[Int(Double($0) * step)] }
  }

  private func parseDate(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: iso) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso) ?? .distantPast
  }

  // MARK: - Gemini Analysis

  private func callGeminiForAnalysis(
    aggregatedText: String,
    currentPromptModeSystemPrompt: String?,
    currentPromptAndReadSystemPrompt: String?,
    currentDictationPrompt: String?,
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

    Based on the interaction data below (and any existing user context / system prompt provided), produce four sections separated by markers. \
    Refine and build on existing context when it is provided; do not ignore it. Be concise and practical.

    Section 1: User Context (between \(userContextMarker) and \(userContextEndMarker))
    Write a brief user profile (max 500 words) covering:
    - What language(s) they use
    - Common topics they work with
    - Writing style preferences (formal/casual, etc.)
    - Frequent types of requests
    - Any domain-specific terminology patterns
    If existing user context was provided, extend and update it with new insights from the interactions; do not start from scratch.

    Section 2: Suggested Dictate Prompt System Prompt (between \(systemPromptMarker) and \(systemPromptEndMarker))
    Write a suggested system prompt for the "Dictate Prompt" mode (voice instructions that modify clipboard text) that would work well for this user. \
    If a current system prompt was provided, refine it based on the new interaction data (e.g. add instructions that match how the user actually uses the app); keep what still works and improve the rest. Keep the result under 300 words.

    Section 3: Suggested Prompt & Read System Prompt (between \(promptAndReadSystemPromptMarker) and \(promptAndReadSystemPromptEndMarker))
    Write a suggested system prompt for the "Dictate Prompt & Read" mode (same as Dictate Prompt but reads the result aloud). \
    This may differ from the Dictate Prompt system prompt because the output is spoken, so it should favour concise, natural-sounding text. \
    If a current Prompt & Read system prompt was provided, refine it. Keep the result under 300 words.

    Section 4: Suggested Dictation Prompt (between \(dictationPromptMarker) and \(dictationPromptEndMarker))
    Write a single combined system prompt for speech-to-text transcription. This prompt instructs the AI how to transcribe spoken audio. \
    It must include: (1) domain context, language(s), topics, and style tailored to this user; (2) ONE single block for all term/correction rules. \
    CRITICAL – use exactly ONE block for terms and corrections, not two. Do NOT create separate "Mandatory Corrections" and "Spelling reference" sections; they do the same thing (tell the model how to spell/write a term when heard). Use a single list, e.g. "Terms and corrections (use only if heard in audio):" followed by either explicit mappings "X → Y" for common mishearings (e.g. "Jason" → JSON) and/or comma-separated terms that must be spelled as written when heard (e.g. WhisperShortcut, EnBW). Each term appears at most once. End with: "CRITICAL: Transcribe ONLY what is spoken. Do NOT add terms from this list if not heard. Do NOT include this instruction in your output." \
    Infer difficult words from "transcription" results (recognition errors). If a current dictation prompt was provided, merge its two sections into one and remove duplicates. Keep the result under 400 words.
    """

    var userMessageParts: [String] = []

    if let existing = existingUserContext, !existing.isEmpty {
      userMessageParts.append("Existing user context (refine and extend this):\n\(existing)")
    }
    if let prompt = currentPromptModeSystemPrompt, !prompt.isEmpty {
      userMessageParts.append("Current Prompt Mode system prompt (refine based on new data):\n\(prompt)")
    }
    if let promptRead = currentPromptAndReadSystemPrompt, !promptRead.isEmpty {
      userMessageParts.append("Current Prompt & Read system prompt (refine based on new data):\n\(promptRead)")
    }
    if let dictation = currentDictationPrompt, !dictation.isEmpty {
      userMessageParts.append("Current dictation/transcription prompt (refine based on new data):\n\(dictation)")
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
      let fileURL = contextDir.appendingPathComponent("suggested-user-context.md")
      try userContext.write(to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested-user-context.md (\(userContext.count) chars)")
    }

    // Parse suggested system prompt (Dictate Prompt)
    if let suggestedPrompt = extractSection(from: analysisResult, startMarker: systemPromptMarker, endMarker: systemPromptEndMarker) {
      let fileURL = contextDir.appendingPathComponent("suggested-prompt-mode-system-prompt.txt")
      try suggestedPrompt.write(to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested Dictate Prompt system prompt (\(suggestedPrompt.count) chars)")
    }

    // Parse suggested system prompt (Prompt & Read)
    if let suggestedPromptAndRead = extractSection(from: analysisResult, startMarker: promptAndReadSystemPromptMarker, endMarker: promptAndReadSystemPromptEndMarker) {
      let fileURL = contextDir.appendingPathComponent("suggested-prompt-and-read-system-prompt.txt")
      try suggestedPromptAndRead.write(to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested Prompt & Read system prompt (\(suggestedPromptAndRead.count) chars)")
    }

    // Parse suggested dictation prompt (combined: domain context + spelling/difficult words)
    if let suggestedDictation = extractSection(from: analysisResult, startMarker: dictationPromptMarker, endMarker: dictationPromptEndMarker) {
      let fileURL = contextDir.appendingPathComponent("suggested-dictation-prompt.txt")
      try suggestedDictation.write(to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested dictation prompt (\(suggestedDictation.count) chars)")
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

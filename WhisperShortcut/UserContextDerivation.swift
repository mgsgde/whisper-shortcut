import Foundation

// MARK: - User Context Derivation
/// Service that analyzes interaction logs via Gemini to derive user context,
/// suggested system prompts, and difficult words.
class UserContextDerivation {

  private let maxEntriesPerMode = 50
  private let maxFieldChars = 2000
  private let maxTotalChars = 100_000
  private let analysisEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

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

    // 2. Call Gemini to analyze
    let analysisResult = try await callGeminiForAnalysis(aggregatedText: aggregatedText, apiKey: apiKey)

    // 3. Parse and write output files
    try writeOutputFiles(analysisResult: analysisResult)

    DebugLogger.logSuccess("USER-CONTEXT-DERIVATION: Context update completed")
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

  private func callGeminiForAnalysis(aggregatedText: String, apiKey: String) async throws -> String {
    let geminiClient = GeminiAPIClient()

    var request = try geminiClient.createRequest(endpoint: analysisEndpoint, apiKey: apiKey)

    let systemPrompt = """
    You are analyzing a user's interaction history with a voice-to-text application called WhisperShortcut. \
    The app has these modes: transcription (speech-to-text), prompt (voice instructions that modify clipboard text), \
    promptAndRead (same as prompt but reads result aloud), and readAloud (text-to-speech).

    Based on the interaction data below, produce three sections separated by markers. \
    Be concise and practical.

    Section 1: User Context (between \(userContextMarker) and \(userContextEndMarker))
    Write a brief user profile (max 500 words) covering:
    - What language(s) they use
    - Common topics they work with
    - Writing style preferences (formal/casual, etc.)
    - Frequent types of requests
    - Any domain-specific terminology patterns

    Section 2: Suggested System Prompt (between \(systemPromptMarker) and \(systemPromptEndMarker))
    Write a suggested system prompt for the prompt mode that would work well for this user. \
    Keep it under 300 words.

    Section 3: Suggested Difficult Words (between \(difficultWordsMarker) and \(difficultWordsEndMarker))
    List domain-specific words, names, or technical terms that appear frequently and might be \
    difficult for speech recognition. One word/phrase per line. Max 50 entries.
    """

    let userMessage = "Here are the user's recent interactions:\n\n\(aggregatedText)"

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

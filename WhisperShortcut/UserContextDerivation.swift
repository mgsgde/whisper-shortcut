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

  /// Result of focused load: primary (target mode) and secondary (user context + current prompt + other modes capped).
  private struct FocusedLoadResult {
    let primaryText: String
    let secondaryText: String
    let primaryEntryCount: Int
    let primaryCharCount: Int
    let secondaryCharCount: Int
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

  /// Analyzes interaction logs and derives the output for the given focus (one section only).
  /// Returns loaded log stats for UI feedback. Throws if no API key or if the Gemini request fails.
  func updateFromLogs(focus: GenerationKind) async throws -> LoadedLogs {
    guard let apiKey = KeychainManager.shared.getGoogleAPIKey(), !apiKey.isEmpty else {
      throw TranscriptionError.noGoogleAPIKey
    }

    DebugLogger.log("USER-CONTEXT-DERIVATION: Starting context update focus=\(focus)")

    let existingUserContext = loadExistingUserContextFile()
    let currentPromptModeSystemPrompt = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptModeSystemPrompt)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentPromptAndReadSystemPrompt = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptAndReadSystemPrompt)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentDictationPrompt = (UserDefaults.standard.string(forKey: UserDefaultsKeys.customPromptText) ?? AppConstants.defaultTranscriptionSystemPrompt).trimmingCharacters(in: .whitespacesAndNewlines)

    let loaded = try loadAndSampleLogs(focus: focus, existingUserContext: existingUserContext,
                                       currentPromptModeSystemPrompt: currentPromptModeSystemPrompt,
                                       currentPromptAndReadSystemPrompt: currentPromptAndReadSystemPrompt,
                                       currentDictationPrompt: currentDictationPrompt)

    let hasPrimary = !loaded.primaryText.isEmpty
    if focus == .userContext && !hasPrimary {
      DebugLogger.logWarning("USER-CONTEXT-DERIVATION: No interaction logs found")
      throw TranscriptionError.networkError("No interaction logs found. Use the app for a while with logging enabled, then try again.")
    }
    if hasPrimary {
      DebugLogger.log("USER-CONTEXT-DERIVATION: Primary \(loaded.primaryEntryCount) entries, \(loaded.primaryCharCount) chars; secondary \(loaded.secondaryCharCount) chars")
    } else {
      DebugLogger.log("USER-CONTEXT-DERIVATION: No primary interactions; using secondary only (\(loaded.secondaryCharCount) chars)")
    }

    let analysisResult = try await callGeminiForAnalysis(
      focus: focus,
      primaryText: loaded.primaryText,
      secondaryText: loaded.secondaryText,
      currentPromptModeSystemPrompt: currentPromptModeSystemPrompt,
      currentPromptAndReadSystemPrompt: currentPromptAndReadSystemPrompt,
      currentDictationPrompt: currentDictationPrompt,
      existingUserContext: existingUserContext,
      apiKey: apiKey
    )

    try writeOutputFile(analysisResult: analysisResult, focus: focus)

    DebugLogger.logSuccess("USER-CONTEXT-DERIVATION: Context update completed focus=\(focus)")
    return LoadedLogs(
      text: loaded.primaryText + (loaded.secondaryText.isEmpty ? "" : "\n\n" + loaded.secondaryText),
      entryCount: loaded.primaryEntryCount,
      charCount: loaded.primaryCharCount + loaded.secondaryCharCount
    )
  }

  /// Legacy entry point: full user-context derivation (same as updateFromLogs(focus: .userContext)).
  func updateContextFromLogs() async throws -> LoadedLogs {
    try await updateFromLogs(focus: .userContext)
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

  private static func primaryMode(for focus: GenerationKind) -> String? {
    switch focus {
    case .dictation: return "transcription"
    case .promptMode: return "prompt"
    case .promptAndRead: return "promptAndRead"
    case .userContext: return nil
    }
  }

  private func loadAndSampleLogs(
    focus: GenerationKind,
    existingUserContext: String?,
    currentPromptModeSystemPrompt: String?,
    currentPromptAndReadSystemPrompt: String?,
    currentDictationPrompt: String?
  ) throws -> FocusedLoadResult {
    let maxPerMode = UserDefaults.standard.object(forKey: UserDefaultsKeys.userContextMaxEntriesPerMode) as? Int
      ?? AppConstants.userContextDefaultMaxEntriesPerMode
    let maxChars = UserDefaults.standard.object(forKey: UserDefaultsKeys.userContextMaxTotalChars) as? Int
      ?? AppConstants.userContextDefaultMaxTotalChars

    let logFiles = UserContextLogger.shared.interactionLogFiles(lastDays: AppConstants.userContextTier3Days)
    guard !logFiles.isEmpty else {
      return FocusedLoadResult(primaryText: "", secondaryText: "", primaryEntryCount: 0, primaryCharCount: 0, secondaryCharCount: 0)
    }

    var entriesByMode: [String: [InteractionLogEntry]] = [:]
    let decoder = JSONDecoder()
    for fileURL in logFiles {
      guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
      let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
      for line in lines {
        guard let data = line.data(using: .utf8),
              let entry = try? decoder.decode(InteractionLogEntry.self, from: data) else { continue }
        entriesByMode[entry.mode, default: []].append(entry)
      }
    }

    let now = Date()
    let tier1Cutoff = Calendar.current.date(byAdding: .day, value: -AppConstants.userContextTier1Days, to: now) ?? now
    let tier2Cutoff = Calendar.current.date(byAdding: .day, value: -AppConstants.userContextTier2Days, to: now) ?? now

    if focus == .userContext {
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
      sampledEntries.sort { $0.ts < $1.ts }
      let (text, entryCount, charCount) = buildAggregatedText(from: sampledEntries, maxChars: maxChars)
      return FocusedLoadResult(primaryText: text, secondaryText: "", primaryEntryCount: entryCount, primaryCharCount: charCount, secondaryCharCount: 0)
    }

    guard let primaryMode = Self.primaryMode(for: focus) else {
      return FocusedLoadResult(primaryText: "", secondaryText: "", primaryEntryCount: 0, primaryCharCount: 0, secondaryCharCount: 0)
    }

    let primaryEntries = entriesByMode[primaryMode] ?? []
    let sortedPrimary = primaryEntries.sorted { $0.ts < $1.ts }
    let tier1 = sortedPrimary.filter { parseDate($0.ts) >= tier1Cutoff }
    let tier2 = sortedPrimary.filter { entry in
      let d = parseDate(entry.ts)
      return d < tier1Cutoff && d >= tier2Cutoff
    }
    let tier3 = sortedPrimary.filter { parseDate($0.ts) < tier2Cutoff }
    let budget1 = Int(Double(maxPerMode) * AppConstants.userContextTier1Ratio)
    let budget2 = Int(Double(maxPerMode) * AppConstants.userContextTier2Ratio)
    let budget3 = maxPerMode - budget1 - budget2
    var sampledPrimary: [InteractionLogEntry] = []
    sampledPrimary.append(contentsOf: evenSample(tier1, max: budget1))
    sampledPrimary.append(contentsOf: evenSample(tier2, max: budget2))
    sampledPrimary.append(contentsOf: evenSample(tier3, max: budget3))
    sampledPrimary.sort { $0.ts < $1.ts }
    let (primaryText, primaryEntryCount, primaryCharCount) = buildAggregatedText(from: sampledPrimary, maxChars: maxChars)

    var secondaryParts: [String] = []
    if let ctx = existingUserContext, !ctx.isEmpty {
      secondaryParts.append("Existing user context:\n\(ctx)")
    }
    switch focus {
    case .dictation:
      if let p = currentDictationPrompt, !p.isEmpty { secondaryParts.append("Current dictation prompt (refine based on new data):\n\(p)") }
    case .promptMode:
      if let p = currentPromptModeSystemPrompt, !p.isEmpty { secondaryParts.append("Current Dictate Prompt system prompt (refine based on new data):\n\(p)") }
    case .promptAndRead:
      if let p = currentPromptAndReadSystemPrompt, !p.isEmpty { secondaryParts.append("Current Prompt & Read system prompt (refine based on new data):\n\(p)") }
    case .userContext:
      break
    }

    let otherModes = entriesByMode.filter { $0.key != primaryMode }
    var otherEntries: [InteractionLogEntry] = []
    for (_, entries) in otherModes {
      otherEntries.append(contentsOf: entries)
    }
    otherEntries.sort { $0.ts < $1.ts }
    let (otherText, _, otherCharCount) = buildAggregatedText(from: otherEntries, maxChars: AppConstants.userContextSecondaryOtherModesMaxChars)
    if !otherText.isEmpty {
      secondaryParts.append("Other modes (for context only):\n\(otherText)")
    }

    let secondaryText = secondaryParts.joined(separator: "\n\n---\n\n")
    return FocusedLoadResult(
      primaryText: primaryText,
      secondaryText: secondaryText,
      primaryEntryCount: primaryEntryCount,
      primaryCharCount: primaryCharCount,
      secondaryCharCount: secondaryText.count
    )
  }

  private func buildAggregatedText(from entries: [InteractionLogEntry], maxChars: Int) -> (text: String, entryCount: Int, charCount: Int) {
    var parts: [String] = []
    var totalChars = 0
    for entry in entries {
      var entryParts: [String] = ["mode: \(entry.mode)"]
      if let result = entry.result { entryParts.append("result: \(String(result.prefix(maxFieldChars)))") }
      if let selectedText = entry.selectedText { entryParts.append("selectedText: \(String(selectedText.prefix(maxFieldChars)))") }
      if let userInstruction = entry.userInstruction { entryParts.append("userInstruction: \(String(userInstruction.prefix(maxFieldChars)))") }
      if let modelResponse = entry.modelResponse { entryParts.append("modelResponse: \(String(modelResponse.prefix(maxFieldChars)))") }
      if let text = entry.text { entryParts.append("text: \(String(text.prefix(maxFieldChars)))") }
      let entryText = entryParts.joined(separator: " | ")
      if totalChars + entryText.count > maxChars { break }
      parts.append(entryText)
      totalChars += entryText.count
    }
    let text = parts.joined(separator: "\n---\n")
    return (text, parts.count, totalChars)
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

  private func systemPromptForFocus(_ focus: GenerationKind) -> String {
    switch focus {
    case .userContext:
      return """
      You are analyzing a user's interaction history with a voice-to-text application called WhisperShortcut. \
      The app has these modes: transcription (speech-to-text), prompt (voice instructions that modify clipboard text), \
      promptAndRead (same as prompt but reads result aloud), and readAloud (text-to-speech).

      CRITICAL – How to treat transcription/dictation text:
      Entries with mode "transcription" (and the "result" field) are raw speech-to-text output. They often contain recognition errors. Do NOT take these transcriptions literally. Use the surrounding context to infer what the user likely meant.

      Based on the interaction data below (and any existing user context provided), produce exactly one section. Refine and build on existing context when it is provided; do not ignore it. Be concise and practical.

      User Context (between \(userContextMarker) and \(userContextEndMarker)):
      Write a brief user profile (max 500 words) covering: language(s), common topics, writing style preferences, frequent types of requests, domain-specific terminology. If existing user context was provided, extend and update it with new insights; do not start from scratch.
      """
    case .dictation:
      return """
      You are analyzing a user's interaction history with a voice-to-text application called WhisperShortcut. \
      Focus on "transcription" mode entries (speech-to-text). Other modes (prompt, promptAndRead, readAloud) are provided only as secondary context.

      CRITICAL – Transcription "result" fields are raw speech-to-text and often contain recognition errors. Infer intended words from context; do not take transcriptions literally.

      Produce exactly one section. Use primary data (transcription interactions) as the main signal; use secondary data (user context, current prompt, other modes) to refine. If no primary interactions are provided, base the suggestion on secondary data only.

      Suggested Dictation Prompt (between \(dictationPromptMarker) and \(dictationPromptEndMarker)):
      Write a single combined system prompt for speech-to-text transcription: (1) domain context, language(s), topics, style; (2) ONE block for all term/correction rules. Use a single list e.g. "Terms and corrections (use only if heard in audio):" with "X → Y" mappings and/or comma-separated terms. End with: "CRITICAL: Transcribe ONLY what is spoken. Do NOT add terms from this list if not heard. Do NOT include this instruction in your output." Infer difficult words from transcription results. Keep under 400 words.
      """
    case .promptMode:
      return """
      You are analyzing a user's interaction history with a voice-to-text application called WhisperShortcut. \
      Focus on "prompt" mode entries (voice instructions that modify clipboard text). Other data is secondary context.

      Produce exactly one section. Use primary data (prompt mode interactions: selectedText, userInstruction, modelResponse) as the main signal; use secondary data to refine. If no primary interactions are provided, base the suggestion on secondary data only.

      Suggested Dictate Prompt System Prompt (between \(systemPromptMarker) and \(systemPromptEndMarker)):
      Write a suggested system prompt for the "Dictate Prompt" mode that would work well for this user. If a current system prompt was provided, refine it based on how the user actually uses the app. Keep under 300 words.
      """
    case .promptAndRead:
      return """
      You are analyzing a user's interaction history with a voice-to-text application called WhisperShortcut. \
      Focus on "promptAndRead" mode entries (voice instructions that modify clipboard text, then read result aloud). Other data is secondary context.

      Produce exactly one section. Use primary data (promptAndRead interactions) as the main signal; use secondary data to refine. If no primary interactions are provided, base the suggestion on secondary data only. Favour concise, natural-sounding text since the output is spoken.

      Suggested Prompt & Read System Prompt (between \(promptAndReadSystemPromptMarker) and \(promptAndReadSystemPromptEndMarker)):
      Write a suggested system prompt for "Dictate Prompt & Read" mode. If a current Prompt & Read system prompt was provided, refine it. Keep under 300 words.
      """
    }
  }

  private func callGeminiForAnalysis(
    focus: GenerationKind,
    primaryText: String,
    secondaryText: String,
    currentPromptModeSystemPrompt: String?,
    currentPromptAndReadSystemPrompt: String?,
    currentDictationPrompt: String?,
    existingUserContext: String?,
    apiKey: String
  ) async throws -> String {
    let geminiClient = GeminiAPIClient()
    var request = try geminiClient.createRequest(endpoint: analysisEndpoint, apiKey: apiKey)

    let systemPrompt = systemPromptForFocus(focus)

    var userMessageParts: [String] = []
    if focus == .userContext {
      if let existing = existingUserContext, !existing.isEmpty {
        userMessageParts.append("Existing user context (refine and extend this):\n\(existing)")
      }
      userMessageParts.append("User's recent interactions:\n\n\(primaryText)")
    } else {
      if !primaryText.isEmpty {
        let modeLabel = Self.primaryMode(for: focus) ?? "primary"
        userMessageParts.append("Primary – \(modeLabel) interactions:\n\n\(primaryText)")
      } else {
        userMessageParts.append("No primary (\(Self.primaryMode(for: focus) ?? "target") mode) interactions found. Base the suggestion on secondary context below.")
      }
      if !secondaryText.isEmpty {
        userMessageParts.append("Secondary – user context and other context:\n\n\(secondaryText)")
      }
    }

    let userMessage = userMessageParts.joined(separator: "\n\n---\n\n")
    let systemInstruction = GeminiChatRequest.GeminiSystemInstruction(
      parts: [GeminiChatRequest.GeminiSystemPart(text: systemPrompt)]
    )
    let contents = [
      GeminiChatRequest.GeminiChatContent(
        role: "user",
        parts: [GeminiChatRequest.GeminiChatPart(text: userMessage, inlineData: nil, fileData: nil, url: nil)]
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
      if let text = part.text { textContent += text }
    }
    return textContent
  }

  // MARK: - Output File Writing

  private func writeOutputFile(analysisResult: String, focus: GenerationKind) throws {
    let contextDir = UserContextLogger.shared.directoryURL

    switch focus {
    case .userContext:
      if let userContext = extractSection(from: analysisResult, startMarker: userContextMarker, endMarker: userContextEndMarker) {
        let fileURL = contextDir.appendingPathComponent("suggested-user-context.md")
        try userContext.write(to: fileURL, atomically: true, encoding: .utf8)
        DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested-user-context.md (\(userContext.count) chars)")
      }
    case .dictation:
      if let suggested = extractSection(from: analysisResult, startMarker: dictationPromptMarker, endMarker: dictationPromptEndMarker) {
        let fileURL = contextDir.appendingPathComponent("suggested-dictation-prompt.txt")
        try suggested.write(to: fileURL, atomically: true, encoding: .utf8)
        DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested dictation prompt (\(suggested.count) chars)")
      }
    case .promptMode:
      if let suggested = extractSection(from: analysisResult, startMarker: systemPromptMarker, endMarker: systemPromptEndMarker) {
        let fileURL = contextDir.appendingPathComponent("suggested-prompt-mode-system-prompt.txt")
        try suggested.write(to: fileURL, atomically: true, encoding: .utf8)
        DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested Dictate Prompt system prompt (\(suggested.count) chars)")
      }
    case .promptAndRead:
      if let suggested = extractSection(from: analysisResult, startMarker: promptAndReadSystemPromptMarker, endMarker: promptAndReadSystemPromptEndMarker) {
        let fileURL = contextDir.appendingPathComponent("suggested-prompt-and-read-system-prompt.txt")
        try suggested.write(to: fileURL, atomically: true, encoding: .utf8)
        DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested Prompt & Read system prompt (\(suggested.count) chars)")
      }
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

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

      CRITICAL – Entries with mode "transcription" (field "result") are raw speech-to-text and often contain \
      recognition errors. Infer intended words from context; do not take them literally.

      IMPORTANT – Only include information that is clearly evidenced in the interaction data. Do not invent or \
      assume patterns that are not supported by the data.

      Your task: produce a concise user profile that helps the app's AI perform better for this specific user. \
      Focus on information that is actionable for transcription and text editing. Skip categories where the data \
      provides no clear signal.

      You MUST wrap your entire output in these markers exactly as shown:

      \(userContextMarker)
      [your content here]
      \(userContextEndMarker)

      Cover whichever of these are clearly evidenced (skip the rest):
      - Primary language(s) and any code-switching patterns
      - Domains and topics the user works with
      - Recurring terminology, names, or jargon (list them so the transcription model can recognize them)
      - Tone and formality level
      - Common types of requests or workflows

      If existing user context is provided, refine and extend it with new insights — do not start from scratch. \
      Remove items that are no longer supported by recent data. Be concise: 2–3 short paragraphs.

      Example structure (do not copy content, only the format):

      \(userContextMarker)
      The user primarily dictates in German with occasional English technical terms. They work in software development, \
      frequently discussing Swift, API design, and macOS app architecture.

      Common terminology: WhisperShortcut, Gemini, UserDefaults, MenuBarController, ...

      They prefer a direct, informal tone and often dictate short instructions or code-related notes.
      \(userContextEndMarker)
      """

    case .dictation:
      return """
      You are analyzing a user's interaction history with a voice-to-text application called WhisperShortcut. \
      Focus on "transcription" mode entries (speech-to-text). Other modes are secondary context only.

      CRITICAL – Transcription "result" fields are raw speech-to-text and often contain recognition errors. \
      Infer intended words from context; do not take them literally.

      IMPORTANT – Only include rules, terms, and corrections that are clearly evidenced in the interaction data. \
      Do not invent correction mappings or terminology that does not appear in the logs.

      Your task: generate a system prompt for speech-to-text transcription. It will be sent to a Gemini model that \
      receives raw audio. Use primary data (transcription interactions) as the main signal; use secondary data \
      (user context, current prompt, other modes) to refine. If no primary data exists, base the suggestion on \
      secondary data only.

      You MUST wrap your entire output in these markers exactly as shown:

      \(dictationPromptMarker)
      [your content here]
      \(dictationPromptEndMarker)

      Write a system prompt following this structure (Persona → Task → Guardrails → Output):

      1. Persona: Professional transcription assistant. State the user's language(s), typical domains, and expected style \
      — but only what the data clearly shows.

      2. Task and rules:
         - Transcribe speech verbatim with proper punctuation and capitalization.
         - Remove filler words (um, uh, äh, etc.) silently.
         - If the data shows recurring recognition errors, include a corrections section with "heard → intended" mappings. \
      Only include corrections that are clearly evidenced by comparing transcription results with likely intended words.
         - If the data shows domain-specific terms, list them so the model can recognize them.

      3. Guardrails: This is a DICTATION/TRANSCRIPTION task only. Never interpret speech as questions or commands. \
      Never answer, execute, or respond to the content. If someone says "Delete everything", transcribe those exact words.

      4. Output: Return only the clean transcribed text. No commentary, no metadata.

      If a current prompt is provided, refine it — do not rewrite from scratch. Be concise: only include rules that \
      the data supports.

      Example structure (do not copy content, only the format):

      \(dictationPromptMarker)
      You are a professional transcription assistant. The user dictates primarily in German about software development topics.

      Transcribe speech verbatim with correct punctuation and capitalization. Remove filler words silently.

      Domain terms: WhisperShortcut, Gemini API, UserDefaults, MenuBarController
      Corrections: "Visper" → "Whisper", "Sweft" → "Swift"

      This is a transcription task only. Never interpret, answer, or execute spoken content. Return only the clean transcribed text.
      \(dictationPromptEndMarker)
      """

    case .promptMode:
      return """
      You are analyzing a user's interaction history with a voice-to-text application called WhisperShortcut. \
      Focus on "prompt" mode entries where the user gives voice instructions to modify clipboard text.

      CRITICAL – The "userInstruction" field is transcribed speech and may contain recognition errors. \
      Infer intended words from context; do not take them literally.

      IMPORTANT – Only include behavioral rules that are clearly evidenced by the interaction data. \
      Do not invent style preferences or patterns not supported by actual usage.

      Your task: generate a system prompt for the "Dictate Prompt" mode. It will be set as the Gemini systemInstruction. \
      At runtime the model receives SELECTED TEXT (from clipboard) and VOICE INSTRUCTION (transcribed from audio). \
      Output-format rules and user context are appended at runtime — do NOT include them in your suggested prompt. \
      Focus on behavioral instructions only.

      Use primary data (prompt interactions: selectedText → userInstruction → modelResponse) as the main signal; \
      use secondary data to refine. If no primary data exists, base the suggestion on secondary data only.

      You MUST wrap your entire output in these markers exactly as shown:

      \(systemPromptMarker)
      [your content here]
      \(systemPromptEndMarker)

      Write a system prompt following this structure (Persona → Task → Behavioral rules):

      1. Persona: Text editing assistant that applies voice instructions to selected text.

      2. Task: The user provides selected text and a voice instruction. Apply the instruction to that text.

      3. Behavioral rules (only those evidenced by the data):
         - Format and tone mirroring: match the format of the input (bullets, headings, prose, code) and its formality level.
         - Language preferences observed in the data (e.g., responds in same language as instruction, or always in a specific language).
         - Domain-specific guidance if the data shows recurring patterns.

      If a current prompt is provided, refine it based on actual usage patterns — do not rewrite from scratch. \
      Be concise: only include rules clearly supported by the data.

      Example structure (do not copy content, only the format):

      \(systemPromptMarker)
      You are a text editing assistant. The user provides selected text and a voice instruction. Apply the instruction to the text.

      Match the format and tone of the selected text. If the input uses bullet points, keep bullet points. If it is formal, stay formal.

      The user typically works with German and English text. When the instruction is in German, respond in German.
      \(systemPromptEndMarker)
      """

    case .promptAndRead:
      return """
      You are analyzing a user's interaction history with a voice-to-text application called WhisperShortcut. \
      Focus on "promptAndRead" mode entries where voice instructions modify clipboard text and the result is read aloud via TTS.

      CRITICAL – The "userInstruction" field is transcribed speech and may contain recognition errors. \
      Infer intended words from context; do not take them literally.

      IMPORTANT – Only include behavioral rules that are clearly evidenced by the interaction data. \
      Do not invent style preferences or patterns not supported by actual usage.

      Your task: generate a system prompt for the "Dictate Prompt & Read" mode. It will be set as the Gemini systemInstruction. \
      Same as Dictate Prompt (selected text + voice instruction) but the output is spoken aloud via TTS. \
      Output-format rules and user context are appended at runtime — do NOT include them in your suggested prompt. \
      Focus on behavioral instructions only.

      Use primary data (promptAndRead interactions) as the main signal; use secondary data to refine. \
      If no primary data exists, base the suggestion on secondary data only.

      You MUST wrap your entire output in these markers exactly as shown:

      \(promptAndReadSystemPromptMarker)
      [your content here]
      \(promptAndReadSystemPromptEndMarker)

      Write a system prompt following this structure (Persona → Task → Behavioral rules):

      1. Persona: Text editing assistant whose output will be read aloud via text-to-speech.

      2. Task: The user provides selected text and a voice instruction. Apply the instruction to that text. \
      The output will be spoken by a TTS engine.

      3. Behavioral rules (only those evidenced by the data):
         - Format and tone mirroring: match the tone of the input.
         - TTS-specific rules: write numbers as words (e.g., "forty-two" not "42"), avoid parenthetical asides, \
      spell out abbreviations (e.g., "for example" not "e.g."), use simple sentence structures, avoid markdown or \
      formatting that is meaningless when spoken (no bullet points, no headers, no bold/italic).
         - Language preferences observed in the data.

      If a current prompt is provided, refine it based on actual usage patterns — do not rewrite from scratch. \
      Be concise: only include rules clearly supported by the data.

      Example structure (do not copy content, only the format):

      \(promptAndReadSystemPromptMarker)
      You are a text editing assistant whose output will be read aloud. The user provides selected text and a voice instruction. Apply the instruction to the text.

      Write for spoken delivery: use complete sentences, spell out numbers and abbreviations, avoid markdown formatting. \
      Keep a natural, conversational tone.

      The user typically gives instructions in German. Match the language of the instruction in your response.
      \(promptAndReadSystemPromptEndMarker)
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
      } else {
        DebugLogger.logWarning("USER-CONTEXT-DERIVATION: Markers not found in Gemini response for user context")
      }
    case .dictation:
      if let suggested = extractSection(from: analysisResult, startMarker: dictationPromptMarker, endMarker: dictationPromptEndMarker) {
        let fileURL = contextDir.appendingPathComponent("suggested-dictation-prompt.txt")
        try suggested.write(to: fileURL, atomically: true, encoding: .utf8)
        DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested dictation prompt (\(suggested.count) chars)")
      } else {
        DebugLogger.logWarning("USER-CONTEXT-DERIVATION: Markers not found in Gemini response for dictation prompt")
      }
    case .promptMode:
      if let suggested = extractSection(from: analysisResult, startMarker: systemPromptMarker, endMarker: systemPromptEndMarker) {
        let fileURL = contextDir.appendingPathComponent("suggested-prompt-mode-system-prompt.txt")
        try suggested.write(to: fileURL, atomically: true, encoding: .utf8)
        DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested Dictate Prompt system prompt (\(suggested.count) chars)")
      } else {
        DebugLogger.logWarning("USER-CONTEXT-DERIVATION: Markers not found in Gemini response for prompt mode")
      }
    case .promptAndRead:
      if let suggested = extractSection(from: analysisResult, startMarker: promptAndReadSystemPromptMarker, endMarker: promptAndReadSystemPromptEndMarker) {
        let fileURL = contextDir.appendingPathComponent("suggested-prompt-and-read-system-prompt.txt")
        try suggested.write(to: fileURL, atomically: true, encoding: .utf8)
        DebugLogger.log("USER-CONTEXT-DERIVATION: Wrote suggested Prompt & Read system prompt (\(suggested.count) chars)")
      } else {
        DebugLogger.logWarning("USER-CONTEXT-DERIVATION: Markers not found in Gemini response for prompt & read")
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

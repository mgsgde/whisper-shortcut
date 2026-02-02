import Foundation

/// Represents a single turn in the prompt conversation history.
struct PromptHistoryTurn {
  let selectedText: String?
  let userInstruction: String
  let modelResponse: String
  let timestamp: Date
}

/// Manages conversation history for Prompt Mode and Prompt & Read.
/// Separate histories are maintained for each mode to avoid context confusion.
final class PromptConversationHistory {
  static let shared = PromptConversationHistory()

  private var promptModeHistory: [PromptHistoryTurn] = []
  private var promptAndReadHistory: [PromptHistoryTurn] = []

  private var promptModeLastInteraction: Date?
  private var promptAndReadLastInteraction: Date?

  private init() {}

  // MARK: - Public API

  /// Returns the conversation history for the specified mode as Gemini API contents.
  /// Automatically clears history if inactivity timeout has elapsed.
  func getContentsForAPI(mode: PromptMode, maxTurns: Int = AppConstants.promptHistoryMaxTurns) -> [GeminiChatRequest.GeminiChatContent] {
    checkAndClearIfInactive(mode: mode)

    let history = getHistory(for: mode)
    let turnsToUse = history.suffix(maxTurns)

    var contents: [GeminiChatRequest.GeminiChatContent] = []

    for turn in turnsToUse {
      // Build user message (selectedText + instruction)
      var userText = ""
      if let selectedText = turn.selectedText, !selectedText.isEmpty {
        userText += "SELECTED TEXT FROM CLIPBOARD (apply the voice instruction to this text):\n\n\(selectedText)\n\n"
      }
      userText += "VOICE INSTRUCTION: \(turn.userInstruction)"

      let userContent = GeminiChatRequest.GeminiChatContent(
        role: "user",
        parts: [GeminiChatRequest.GeminiChatPart(text: userText, inlineData: nil, fileData: nil, url: nil)]
      )
      contents.append(userContent)

      // Build model response
      let modelContent = GeminiChatRequest.GeminiChatContent(
        role: "model",
        parts: [GeminiChatRequest.GeminiChatPart(text: turn.modelResponse, inlineData: nil, fileData: nil, url: nil)]
      )
      contents.append(modelContent)
    }

    return contents
  }

  /// Appends a new turn to the conversation history for the specified mode.
  func append(mode: PromptMode, selectedText: String?, userInstruction: String, modelResponse: String) {
    let turn = PromptHistoryTurn(
      selectedText: selectedText,
      userInstruction: userInstruction,
      modelResponse: modelResponse,
      timestamp: Date()
    )

    switch mode {
    case .togglePrompting:
      promptModeHistory.append(turn)
      promptModeLastInteraction = Date()
      // Trim to max turns
      if promptModeHistory.count > AppConstants.promptHistoryMaxTurns {
        promptModeHistory.removeFirst(promptModeHistory.count - AppConstants.promptHistoryMaxTurns)
      }
      DebugLogger.log("PROMPT-HISTORY: Added turn to Prompt Mode history (total: \(promptModeHistory.count))")
    case .promptAndRead:
      promptAndReadHistory.append(turn)
      promptAndReadLastInteraction = Date()
      // Trim to max turns
      if promptAndReadHistory.count > AppConstants.promptHistoryMaxTurns {
        promptAndReadHistory.removeFirst(promptAndReadHistory.count - AppConstants.promptHistoryMaxTurns)
      }
      DebugLogger.log("PROMPT-HISTORY: Added turn to Prompt & Read history (total: \(promptAndReadHistory.count))")
    }
  }

  /// Clears the conversation history for the specified mode.
  func clear(mode: PromptMode) {
    switch mode {
    case .togglePrompting:
      promptModeHistory.removeAll()
      promptModeLastInteraction = nil
      DebugLogger.log("PROMPT-HISTORY: Cleared Prompt Mode history")
    case .promptAndRead:
      promptAndReadHistory.removeAll()
      promptAndReadLastInteraction = nil
      DebugLogger.log("PROMPT-HISTORY: Cleared Prompt & Read history")
    }
  }

  /// Clears conversation history for all modes.
  func clearAll() {
    promptModeHistory.removeAll()
    promptAndReadHistory.removeAll()
    promptModeLastInteraction = nil
    promptAndReadLastInteraction = nil
    DebugLogger.log("PROMPT-HISTORY: Cleared all history")
  }

  /// Returns the number of turns in the history for the specified mode.
  func turnCount(for mode: PromptMode) -> Int {
    switch mode {
    case .togglePrompting:
      return promptModeHistory.count
    case .promptAndRead:
      return promptAndReadHistory.count
    }
  }

  /// Returns the total number of turns across all modes.
  func totalTurnCount() -> Int {
    return promptModeHistory.count + promptAndReadHistory.count
  }

  /// Returns true if the specified mode has an active (non-expired) conversation history.
  func hasActiveHistory(for mode: PromptMode) -> Bool {
    checkAndClearIfInactive(mode: mode)
    return turnCount(for: mode) > 0
  }

  // MARK: - Private Helpers

  private func getHistory(for mode: PromptMode) -> [PromptHistoryTurn] {
    switch mode {
    case .togglePrompting:
      return promptModeHistory
    case .promptAndRead:
      return promptAndReadHistory
    }
  }

  private func checkAndClearIfInactive(mode: PromptMode) {
    let timeout = AppConstants.promptHistoryInactivityTimeoutSeconds

    switch mode {
    case .togglePrompting:
      if let lastInteraction = promptModeLastInteraction {
        let elapsed = Date().timeIntervalSince(lastInteraction)
        if elapsed > timeout {
          DebugLogger.log("PROMPT-HISTORY: Prompt Mode history expired (inactive for \(String(format: "%.0f", elapsed))s > \(String(format: "%.0f", timeout))s timeout)")
          clear(mode: mode)
        }
      }
    case .promptAndRead:
      if let lastInteraction = promptAndReadLastInteraction {
        let elapsed = Date().timeIntervalSince(lastInteraction)
        if elapsed > timeout {
          DebugLogger.log("PROMPT-HISTORY: Prompt & Read history expired (inactive for \(String(format: "%.0f", elapsed))s > \(String(format: "%.0f", timeout))s timeout)")
          clear(mode: mode)
        }
      }
    }
  }
}

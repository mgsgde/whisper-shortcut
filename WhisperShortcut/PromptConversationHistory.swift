import Foundation

/// Represents a single turn in the prompt conversation history.
struct PromptHistoryTurn {
  let selectedText: String?
  let userInstruction: String
  let modelResponse: String
  let timestamp: Date
}

/// Manages conversation history for Dictate Prompt mode.
final class PromptConversationHistory {
  static let shared = PromptConversationHistory()

  private var promptModeHistory: [PromptHistoryTurn] = []

  private var promptModeLastInteraction: Date?

  private init() {}

  // MARK: - Public API

  /// Returns the conversation history for the specified mode as Gemini API contents.
  /// Automatically clears history if inactivity timeout has elapsed.
  func getContentsForAPI(mode: PromptMode, maxTurns: Int = AppConstants.promptHistoryMaxTurns) -> [GeminiChatRequest.GeminiChatContent] {
    checkAndClearIfInactive(mode: mode)

    let history = promptModeHistory
    let turnsToUse = history.suffix(maxTurns)

    var contents: [GeminiChatRequest.GeminiChatContent] = []

    for turn in turnsToUse {
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

      let modelContent = GeminiChatRequest.GeminiChatContent(
        role: "model",
        parts: [GeminiChatRequest.GeminiChatPart(text: turn.modelResponse, inlineData: nil, fileData: nil, url: nil)]
      )
      contents.append(modelContent)
    }

    return contents
  }

  /// Appends a new turn to the conversation history.
  func append(mode: PromptMode, selectedText: String?, userInstruction: String, modelResponse: String) {
    let turn = PromptHistoryTurn(
      selectedText: selectedText,
      userInstruction: userInstruction,
      modelResponse: modelResponse,
      timestamp: Date()
    )

    promptModeHistory.append(turn)
    promptModeLastInteraction = Date()
    if promptModeHistory.count > AppConstants.promptHistoryMaxTurns {
      promptModeHistory.removeFirst(promptModeHistory.count - AppConstants.promptHistoryMaxTurns)
    }
    DebugLogger.log("PROMPT-HISTORY: Added turn to Dictate Prompt history (total: \(promptModeHistory.count))")
  }

  /// Clears the conversation history.
  func clear(mode: PromptMode) {
    promptModeHistory.removeAll()
    promptModeLastInteraction = nil
    DebugLogger.log("PROMPT-HISTORY: Cleared Dictate Prompt history")
  }

  /// Clears conversation history for all modes.
  func clearAll() {
    promptModeHistory.removeAll()
    promptModeLastInteraction = nil
    DebugLogger.log("PROMPT-HISTORY: Cleared all history")
  }

  /// Returns the number of turns in the history.
  func turnCount(for mode: PromptMode) -> Int {
    promptModeHistory.count
  }

  /// Returns true if the conversation history is active (non-expired).
  func hasActiveHistory(for mode: PromptMode) -> Bool {
    checkAndClearIfInactive(mode: mode)
    return turnCount(for: mode) > 0
  }

  // MARK: - Private Helpers

  private func checkAndClearIfInactive(mode: PromptMode) {
    let timeout = AppConstants.promptHistoryInactivityTimeoutSeconds

    if let lastInteraction = promptModeLastInteraction {
      let elapsed = Date().timeIntervalSince(lastInteraction)
      if elapsed > timeout {
        DebugLogger.log("PROMPT-HISTORY: Dictate Prompt history expired (inactive for \(String(format: "%.0f", elapsed))s > \(String(format: "%.0f", timeout))s timeout)")
        clear(mode: mode)
      }
    }
  }
}

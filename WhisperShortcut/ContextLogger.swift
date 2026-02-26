import Foundation

// MARK: - Interaction Log Entry
struct InteractionLogEntry: Codable {
  let ts: String
  let mode: String
  let model: String?
  let result: String?
  let selectedText: String?
  let userInstruction: String?
  let modelResponse: String?
  let text: String?
  let voice: String?
}

// MARK: - System Prompt History Entry
struct SystemPromptHistoryEntry: Codable {
  let ts: String
  let source: String
  let previousLength: Int
  let newLength: Int
  let content: String
  /// Gemini model used for this improvement (e.g. "Gemini 3.1 Pro"). Optional for backward compatibility with existing JSONL lines.
  let model: String?
}

/// Single history file entry for any system prompt section (system-prompts-history.jsonl).
struct UnifiedSystemPromptHistoryEntry: Codable {
  let ts: String
  let section: String
  let source: String
  let previousLength: Int
  let newLength: Int
  let content: String
  let model: String?
}

// MARK: - Context Logger
/// Singleton service for opt-in JSONL interaction logging.
/// All public methods check the logging toggle and return early if disabled.
class ContextLogger {

  static let shared = ContextLogger()

  private let queue = DispatchQueue(label: "com.whisper-shortcut.contextlogger", qos: .utility)
  /// Directory name on disk; kept as "UserContext" for compatibility with existing installs.
  private let contextDirectoryName = "UserContext"
  private let rotationDays = 90

  private lazy var contextDirectoryURL: URL = {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(contextDirectoryName)
  }()

  private init() {
    ensureDirectoryExists()
    performRotation()
  }

  // MARK: - Directory Management

  private func ensureDirectoryExists() {
    let fm = FileManager.default
    if !fm.fileExists(atPath: contextDirectoryURL.path) {
      do {
        try fm.createDirectory(at: contextDirectoryURL, withIntermediateDirectories: true)
        DebugLogger.log("USER-CONTEXT: Created context directory at \(contextDirectoryURL.path)")
      } catch {
        DebugLogger.logError("USER-CONTEXT: Failed to create context directory: \(error.localizedDescription)")
      }
    }
  }

  /// Removes the entire UserContext directory (user-context.md, suggested prompts, interaction logs).
  /// The directory will be recreated on next use. Use for "Reset to Defaults".
  func deleteAllContextData() throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: contextDirectoryURL.path) else { return }
    try fm.removeItem(at: contextDirectoryURL)
    DebugLogger.log("USER-CONTEXT: Deleted all context data at \(contextDirectoryURL.path)")
  }

  // MARK: - Logging Guard

  private var isLoggingEnabled: Bool {
    // Default to true if key doesn't exist (for backward compatibility)
    UserDefaults.standard.object(forKey: UserDefaultsKeys.contextLoggingEnabled) == nil
      ? true
      : UserDefaults.standard.bool(forKey: UserDefaultsKeys.contextLoggingEnabled)
  }

  // MARK: - Public Logging Methods

  func logTranscription(result: String, model: String?) {
    guard isLoggingEnabled else { return }
    let entry = InteractionLogEntry(
      ts: iso8601Now(),
      mode: "transcription",
      model: model,
      result: result,
      selectedText: nil,
      userInstruction: nil,
      modelResponse: nil,
      text: nil,
      voice: nil
    )
    writeEntry(entry)
  }

  func logPrompt(mode: PromptMode, selectedText: String?, userInstruction: String, modelResponse: String) {
    guard isLoggingEnabled else { return }
    let modeString = mode == .togglePrompting ? "prompt" : "promptAndRead"
    let entry = InteractionLogEntry(
      ts: iso8601Now(),
      mode: modeString,
      model: nil,
      result: nil,
      selectedText: selectedText,
      userInstruction: userInstruction,
      modelResponse: modelResponse,
      text: nil,
      voice: nil
    )
    writeEntry(entry)
  }

  func logReadAloud(text: String, voice: String?) {
    guard isLoggingEnabled else { return }
    let entry = InteractionLogEntry(
      ts: iso8601Now(),
      mode: "readAloud",
      model: nil,
      result: nil,
      selectedText: nil,
      userInstruction: nil,
      modelResponse: nil,
      text: text,
      voice: voice
    )
    writeEntry(entry)
  }

  /// Logs one Open Gemini chat turn (user message + model response) when "Save usage data" is enabled.
  func logGeminiChat(userMessage: String, modelResponse: String, model: String?) {
    guard isLoggingEnabled else { return }
    let entry = InteractionLogEntry(
      ts: iso8601Now(),
      mode: "geminiChat",
      model: model,
      result: nil,
      selectedText: nil,
      userInstruction: userMessage,
      modelResponse: modelResponse,
      text: nil,
      voice: nil
    )
    writeEntry(entry)
  }

  // MARK: - Data Management

  func deleteAllData() {
    queue.async { [weak self] in
      guard let self else { return }
      let fm = FileManager.default
      do {
        let contents = try fm.contentsOfDirectory(at: self.contextDirectoryURL, includingPropertiesForKeys: nil)
        for fileURL in contents {
          try fm.removeItem(at: fileURL)
        }
        DebugLogger.log("USER-CONTEXT: Deleted all context data")
      } catch {
        DebugLogger.logError("USER-CONTEXT: Failed to delete context data: \(error.localizedDescription)")
      }
    }
  }

  func performRotation() {
    queue.async { [weak self] in
      guard let self else { return }
      let fm = FileManager.default
      let cutoffDate = Calendar.current.date(byAdding: .day, value: -self.rotationDays, to: Date()) ?? Date()
      let dateFormatter = DateFormatter()
      dateFormatter.dateFormat = "yyyy-MM-dd"

      do {
        let contents = try fm.contentsOfDirectory(at: self.contextDirectoryURL, includingPropertiesForKeys: nil)
        for fileURL in contents {
          let filename = fileURL.lastPathComponent
          // Only rotate interaction log files
          guard filename.hasPrefix("interactions-"), filename.hasSuffix(".jsonl") else { continue }

          // Extract date from filename: interactions-YYYY-MM-DD.jsonl
          let dateString = filename
            .replacingOccurrences(of: "interactions-", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")

          if let fileDate = dateFormatter.date(from: dateString), fileDate < cutoffDate {
            try fm.removeItem(at: fileURL)
            DebugLogger.log("USER-CONTEXT: Rotated old log file: \(filename)")
          }
        }
      } catch {
        DebugLogger.logError("USER-CONTEXT: Rotation error: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - User Context Loading (deprecated; User Context section removed)

  /// No longer used; User Context section was removed from system prompts. Returns nil.
  func loadUserContext() -> String? {
    nil
  }

  /// Appends one entry to the unified system prompts history (system-prompts-history.jsonl).
  func appendSystemPromptsHistory(section: SystemPromptSection, previousLength: Int, newLength: Int, content: String, model: String? = nil) {
    queue.async { [weak self] in
      guard let self else { return }
      let entry = UnifiedSystemPromptHistoryEntry(
        ts: self.iso8601Now(),
        section: section.rawValue,
        source: "auto",
        previousLength: previousLength,
        newLength: newLength,
        content: content,
        model: model
      )
      let fileURL = self.contextDirectoryURL.appendingPathComponent("system-prompts-history.jsonl")
      do {
        let data = try JSONEncoder().encode(entry)
        guard var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if FileManager.default.fileExists(atPath: fileURL.path) {
          let handle = try FileHandle(forWritingTo: fileURL)
          handle.seekToEndOfFile()
          if let lineData = line.data(using: .utf8) { handle.write(lineData) }
          try handle.close()
        } else {
          try line.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        DebugLogger.log("USER-CONTEXT: Appended system prompts history (\(section.rawValue))")
      } catch {
        DebugLogger.logError("USER-CONTEXT: Failed to append system prompts history: \(error.localizedDescription)")
      }
    }
  }

  /// Truncates at the last sentence or word boundary before maxChars so text is never cut mid-phrase.
  private static func truncateAtBoundary(_ text: String, maxChars: Int) -> String {
    let prefix = String(text.prefix(maxChars))
    let sentenceEnds: Set<Character> = [".", "!", "?", "\n"]
    if let i = prefix.lastIndex(where: { sentenceEnds.contains($0) }) {
      return String(prefix[...i]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let i = prefix.lastIndex(of: " ") {
      return String(prefix[..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - File Listing (for derivation)

  /// Returns true if there is interaction data at least `daysOld` days in the past (oldest log file is that old).
  /// Used to avoid showing auto-improvement suggestions before the user has enough usage history (e.g. 7 days).
  func hasInteractionDataAtLeast(daysOld: Int) -> Bool {
    let logFiles = interactionLogFiles(lastDays: 90)
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    var oldestDate: Date?
    for url in logFiles {
      let filename = url.lastPathComponent
      guard filename.hasPrefix("interactions-"), filename.hasSuffix(".jsonl") else { continue }
      let dateString = filename
        .replacingOccurrences(of: "interactions-", with: "")
        .replacingOccurrences(of: ".jsonl", with: "")
      if let fileDate = dateFormatter.date(from: dateString) {
        if oldestDate == nil || fileDate < oldestDate! {
          oldestDate = fileDate
        }
      }
    }
    guard let oldest = oldestDate else { return false }
    let daysSinceOldest = Calendar.current.dateComponents([.day], from: oldest, to: Date()).day ?? 0
    return daysSinceOldest >= daysOld
  }

  /// Returns URLs of all interaction log files from the last N days, sorted by date ascending.
  func interactionLogFiles(lastDays: Int = 30) -> [URL] {
    let fm = FileManager.default
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -lastDays, to: Date()) ?? Date()
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"

    do {
      let contents = try fm.contentsOfDirectory(at: contextDirectoryURL, includingPropertiesForKeys: nil)
      return contents
        .filter { url in
          let filename = url.lastPathComponent
          guard filename.hasPrefix("interactions-"), filename.hasSuffix(".jsonl") else { return false }
          let dateString = filename
            .replacingOccurrences(of: "interactions-", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
          if let fileDate = dateFormatter.date(from: dateString) {
            return fileDate >= cutoffDate
          }
          return false
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
      DebugLogger.logError("USER-CONTEXT: Failed to list log files: \(error.localizedDescription)")
      return []
    }
  }

  /// Returns the URL of the context directory.
  var directoryURL: URL {
    contextDirectoryURL
  }

  /// Removes the suggested system prompt file so it does not reappear after Apply.
  func deleteSuggestedSystemPromptFile() {
    let url = contextDirectoryURL.appendingPathComponent("suggested-prompt-mode-system-prompt.txt")
    try? FileManager.default.removeItem(at: url)
  }

  /// Removes the suggested user context file so it does not reappear after Apply.
  func deleteSuggestedUserContextFile() {
    let url = contextDirectoryURL.appendingPathComponent("suggested-user-context.md")
    try? FileManager.default.removeItem(at: url)
  }

  /// Removes the suggested dictation prompt file so it does not reappear after Apply.
  func deleteSuggestedDictationPromptFile() {
    let url = contextDirectoryURL.appendingPathComponent("suggested-dictation-prompt.txt")
    try? FileManager.default.removeItem(at: url)
  }

  /// Removes the suggested Prompt Read Mode system prompt file so it does not reappear after Apply.
  func deleteSuggestedPromptAndReadSystemPromptFile() {
    let url = contextDirectoryURL.appendingPathComponent("suggested-prompt-read-mode-system-prompt.txt")
    try? FileManager.default.removeItem(at: url)
  }

  /// Removes the suggested Gemini Chat system prompt file so it does not reappear after Apply.
  func deleteSuggestedGeminiChatSystemPromptFile() {
    let url = contextDirectoryURL.appendingPathComponent("suggested-gemini-chat-system-prompt.txt")
    try? FileManager.default.removeItem(at: url)
  }

  /// Appends one entry to the system prompt history JSONL (for Dictate (transcription), Prompt Mode, or Prompt Read Mode).
  /// File name: system-prompt-history-{suffix}.jsonl (e.g. dictation, prompt-mode, prompt-and-read).
  /// Called when auto-improvement applies a new system prompt. History is removed when context data is deleted.
  func appendSystemPromptHistory(historyFileSuffix: String, previousLength: Int, newLength: Int, content: String, model: String? = nil) {
    queue.async { [weak self] in
      guard let self else { return }
      let entry = SystemPromptHistoryEntry(
        ts: self.iso8601Now(),
        source: "auto",
        previousLength: previousLength,
        newLength: newLength,
        content: content,
        model: model
      )
      let filename = "system-prompt-history-\(historyFileSuffix).jsonl"
      let fileURL = self.contextDirectoryURL.appendingPathComponent(filename)

      do {
        let data = try JSONEncoder().encode(entry)
        guard var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        if FileManager.default.fileExists(atPath: fileURL.path) {
          let handle = try FileHandle(forWritingTo: fileURL)
          handle.seekToEndOfFile()
          if let lineData = line.data(using: .utf8) {
            handle.write(lineData)
          }
          try handle.close()
        } else {
          try line.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        DebugLogger.log("USER-CONTEXT: Appended system prompt history (\(historyFileSuffix))")
      } catch {
        DebugLogger.logError("USER-CONTEXT: Failed to append system prompt history: \(error.localizedDescription)")
      }
    }
  }

  /// Appends one entry to the user context history JSONL (user-context-history.jsonl).
  /// Same entry shape as system prompt history (ts, source, previousLength, newLength, content, model). Called when auto-improvement applies suggested user context. History is removed when context data is deleted.
  func appendUserContextHistory(previousLength: Int, newLength: Int, content: String, model: String? = nil) {
    queue.async { [weak self] in
      guard let self else { return }
      let entry = SystemPromptHistoryEntry(
        ts: self.iso8601Now(),
        source: "auto",
        previousLength: previousLength,
        newLength: newLength,
        content: content,
        model: model
      )
      let filename = "user-context-history.jsonl"
      let fileURL = self.contextDirectoryURL.appendingPathComponent(filename)

      do {
        let data = try JSONEncoder().encode(entry)
        guard var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        if FileManager.default.fileExists(atPath: fileURL.path) {
          let handle = try FileHandle(forWritingTo: fileURL)
          handle.seekToEndOfFile()
          if let lineData = line.data(using: .utf8) {
            handle.write(lineData)
          }
          try handle.close()
        } else {
          try line.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        DebugLogger.log("USER-CONTEXT: Appended user context history")
      } catch {
        DebugLogger.logError("USER-CONTEXT: Failed to append user context history: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Private Helpers

  private func iso8601Now() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
  }

  private func writeEntry(_ entry: InteractionLogEntry) {
    queue.async { [weak self] in
      guard let self else { return }
      let dateFormatter = DateFormatter()
      dateFormatter.dateFormat = "yyyy-MM-dd"
      let dateString = dateFormatter.string(from: Date())
      let filename = "interactions-\(dateString).jsonl"
      let fileURL = self.contextDirectoryURL.appendingPathComponent(filename)

      do {
        let data = try JSONEncoder().encode(entry)
        guard var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        if FileManager.default.fileExists(atPath: fileURL.path) {
          let handle = try FileHandle(forWritingTo: fileURL)
          handle.seekToEndOfFile()
          if let lineData = line.data(using: .utf8) {
            handle.write(lineData)
          }
          try handle.close()
        } else {
          try line.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        DebugLogger.log("USER-CONTEXT: Logged interaction (mode: \(entry.mode))")
      } catch {
        DebugLogger.logError("USER-CONTEXT: Failed to write log entry: \(error.localizedDescription)")
      }
    }
  }
}

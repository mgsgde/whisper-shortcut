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

// MARK: - User Context Logger
/// Singleton service for opt-in JSONL interaction logging.
/// All public methods check the logging toggle and return early if disabled.
class UserContextLogger {

  static let shared = UserContextLogger()

  private let queue = DispatchQueue(label: "com.whisper-shortcut.usercontextlogger", qos: .utility)
  private let contextDirectoryName = "UserContext"
  private let rotationDays = 90

  private lazy var contextDirectoryURL: URL = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport
      .appendingPathComponent("WhisperShortcut")
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

  // MARK: - Logging Guard

  private var isLoggingEnabled: Bool {
    UserDefaults.standard.bool(forKey: UserDefaultsKeys.userContextLoggingEnabled)
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

  // MARK: - User Context Loading

  /// Reads user-context.md and returns its content (truncated to AppConstants.userContextMaxChars).
  /// Truncation happens at sentence or word boundary so the model always sees complete text.
  /// Returns nil if the file is missing or userContextInPromptEnabled is false.
  func loadUserContext() -> String? {
    let enabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.userContextInPromptEnabled) == nil
      ? true  // Default to true when not explicitly set
      : UserDefaults.standard.bool(forKey: UserDefaultsKeys.userContextInPromptEnabled)
    guard enabled else { return nil }

    let fileURL = contextDirectoryURL.appendingPathComponent("user-context.md")
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

    do {
      let content = try String(contentsOf: fileURL, encoding: .utf8)
      let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let maxChars = AppConstants.userContextMaxChars
      if trimmed.count <= maxChars {
        return trimmed
      }
      return Self.truncateAtBoundary(trimmed, maxChars: maxChars)
    } catch {
      DebugLogger.logError("USER-CONTEXT: Failed to load user-context.md: \(error.localizedDescription)")
      return nil
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

  /// Removes the suggested difficult words file so it does not reappear after Apply.
  func deleteSuggestedDifficultWordsFile() {
    let url = contextDirectoryURL.appendingPathComponent("suggested-difficult-words.txt")
    try? FileManager.default.removeItem(at: url)
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

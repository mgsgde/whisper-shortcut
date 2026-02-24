//
//  SystemPromptsStore.swift
//  WhisperShortcut
//
//  Single file storage for all system prompts (Dictation, Dictate Prompt, Prompt & Read).
//  Reads/writes UserContext/system-prompts.md with section headers. Migrates from UserDefaults when missing.
//

import Foundation

/// Section identifiers for the unified system-prompts file.
enum SystemPromptSection: String, CaseIterable {
  case dictation = "dictation"
  case promptMode = "promptMode"
  case promptAndRead = "promptAndRead"

  var fileHeader: String {
    switch self {
    case .dictation: return "=== Dictation (Speech-to-Text) ==="
    case .promptMode: return "=== Dictate Prompt ==="
    case .promptAndRead: return "=== Prompt & Read ==="
    }
  }

  static func section(forHeader line: String) -> SystemPromptSection? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    for section in SystemPromptSection.allCases where trimmed == section.fileHeader {
      return section
    }
    return nil
  }
}

/// Reads and writes the single system-prompts.md file in UserContext.
final class SystemPromptsStore {
  static let shared = SystemPromptsStore()
  static let fileName = "system-prompts.md"

  private let queue = DispatchQueue(label: "com.whisper-shortcut.systempromptsstore", qos: .userInitiated)
  private var contextDirectoryURL: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL().appendingPathComponent("UserContext")
  }

  private var fileURL: URL {
    contextDirectoryURL.appendingPathComponent(Self.fileName)
  }

  /// URL of the system-prompts file (e.g. for opening in Finder or external editor).
  var systemPromptsFileURL: URL { fileURL }

  private init() {}

  // MARK: - Public read

  /// Dictation system prompt. Returns default if section missing or empty.
  func loadDictationPrompt() -> String {
    (loadSection(.dictation)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? AppConstants.defaultTranscriptionSystemPrompt
  }

  /// Dictate Prompt system prompt. Returns default if section missing or empty.
  func loadDictatePromptSystemPrompt() -> String {
    (loadSection(.promptMode)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? AppConstants.defaultPromptModeSystemPrompt
  }

  /// Prompt & Read system prompt. Returns default if section missing or empty.
  func loadPromptAndReadSystemPrompt() -> String {
    (loadSection(.promptAndRead)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? AppConstants.defaultPromptAndReadSystemPrompt
  }

  /// Load full file content for the editor. Returns default formatted content if file missing (after migration attempt).
  func loadFullContent() -> String {
    ensureDirectoryExists()
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      performMigration()
    }
    guard let data = try? Data(contentsOf: fileURL),
          let content = String(data: data, encoding: .utf8) else {
      return defaultFormattedContent()
    }
    return content
  }

  /// Recreate the system-prompts file with app defaults. Used after "Delete context data".
  func resetSystemPromptsToDefaults() {
    ensureDirectoryExists()
    let content = defaultFormattedContent()
    do {
      try content.write(to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log("SYSTEM-PROMPTS: Reset \(Self.fileName) to defaults")
      NotificationCenter.default.post(name: .userContextFileDidUpdate, object: nil)
    } catch {
      DebugLogger.logError("SYSTEM-PROMPTS: Failed to reset to defaults: \(error.localizedDescription)")
    }
  }

  /// Save full file content from the editor. Parses sections and rewrites so format is canonical.
  func saveFullContent(_ rawContent: String) {
    ensureDirectoryExists()
    let parsed = parseSections(from: rawContent)
    let toWrite = formatContent(parsed)
    do {
      try toWrite.write(to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log("SYSTEM-PROMPTS: Saved \(Self.fileName)")
    } catch {
      DebugLogger.logError("SYSTEM-PROMPTS: Failed to save: \(error.localizedDescription)")
    }
  }

  /// Update a single section (e.g. when Smart Improvement applies a suggestion). Writes the full file.
  func updateSection(_ section: SystemPromptSection, content: String) {
    ensureDirectoryExists()
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      performMigration()
    }
    var parsed = parseSections(from: (try? String(contentsOf: fileURL, encoding: .utf8)) ?? defaultFormattedContent())
    parsed[section] = content
    let toWrite = formatContent(parsed)
    do {
      try toWrite.write(to: fileURL, atomically: true, encoding: .utf8)
      NotificationCenter.default.post(name: .userContextFileDidUpdate, object: nil)
      DebugLogger.log("SYSTEM-PROMPTS: Updated section \(section.rawValue)")
    } catch {
      DebugLogger.logError("SYSTEM-PROMPTS: Failed to update section: \(error.localizedDescription)")
    }
  }

  /// Current content for a section (raw, for display or comparison). Used by Smart Improvement.
  func loadSection(_ section: SystemPromptSection) -> String? {
    ensureDirectoryExists()
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      performMigration()
    }
    guard let data = try? Data(contentsOf: fileURL),
          let content = String(data: data, encoding: .utf8) else { return nil }
    return parseSections(from: content)[section]
  }

  // MARK: - Private

  private func ensureDirectoryExists() {
    let fm = FileManager.default
    if !fm.fileExists(atPath: contextDirectoryURL.path) {
      try? fm.createDirectory(at: contextDirectoryURL, withIntermediateDirectories: true)
    }
  }

  private func defaultFormattedContent() -> String {
    formatContent([
      .dictation: AppConstants.defaultTranscriptionSystemPrompt,
      .promptMode: AppConstants.defaultPromptModeSystemPrompt,
      .promptAndRead: AppConstants.defaultPromptAndReadSystemPrompt,
    ])
  }

  private func formatContent(_ sections: [SystemPromptSection: String]) -> String {
    SystemPromptSection.allCases.map { section in
      let body = sections[section] ?? ""
      return section.fileHeader + "\n\n" + body
    }.joined(separator: "\n\n")
  }

  private func parseSections(from content: String) -> [SystemPromptSection: String] {
    var result: [SystemPromptSection: String] = [:]
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var i = 0
    while i < lines.count {
      let line = lines[i]
      if let section = SystemPromptSection.section(forHeader: line) {
        var bodyLines: [String] = []
        i += 1
        while i < lines.count {
          if SystemPromptSection.section(forHeader: lines[i]) != nil { break }
          bodyLines.append(lines[i])
          i += 1
        }
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        result[section] = body
      } else {
        i += 1
      }
    }
    return result
  }

  private func performMigration() {
    let dictation = UserDefaults.standard.string(forKey: UserDefaultsKeys.customPromptText)
      ?? AppConstants.defaultTranscriptionSystemPrompt
    let promptMode = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptModeSystemPrompt)
      ?? AppConstants.defaultPromptModeSystemPrompt
    let promptAndRead = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptAndReadSystemPrompt)
      ?? AppConstants.defaultPromptAndReadSystemPrompt
    let content = formatContent([
      .dictation: dictation,
      .promptMode: promptMode,
      .promptAndRead: promptAndRead,
    ])
    do {
      try content.write(to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log("SYSTEM-PROMPTS: Migrated to \(Self.fileName) from UserDefaults")
    } catch {
      DebugLogger.logError("SYSTEM-PROMPTS: Migration failed: \(error.localizedDescription)")
    }
  }
}

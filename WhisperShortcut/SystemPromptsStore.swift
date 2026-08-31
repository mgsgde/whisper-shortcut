//
//  SystemPromptsStore.swift
//  WhisperShortcut
//
//  Single file storage for all system prompts (Dictation, Dictate Prompt, Chat).
//  Reads/writes UserContext/system-prompts.md with section headers. Migrates from UserDefaults when missing.
//

import Foundation

/// Section identifiers for the unified system-prompts file.
enum SystemPromptSection: String, CaseIterable {
  case dictation = "dictation"
  case whisperGlossary = "whisperGlossary"
  case promptMode = "promptMode"
  case chat = "geminiChat"
  case readAloudRewrite = "readAloudRewrite"

  var fileHeader: String {
    switch self {
    case .dictation: return "=== Dictation (Speech-to-Text) ==="
    case .whisperGlossary: return "=== Whisper Glossary (Offline) ==="
    case .promptMode: return "=== Dictate Prompt ==="
    case .chat: return "=== Chat ==="
    case .readAloudRewrite: return "=== Read Aloud Rewrite ==="
    }
  }

  /// Legacy headers supported for backward compatibility when reading existing files.
  /// Legacy Prompt Read Mode headers are recognized but skipped (section removed).
  private static let legacyHeaders: [String: SystemPromptSection] = [
    "=== Prompt Mode ===": .promptMode,
    "=== Gemini Chat ===": .chat,
  ]

  /// Legacy headers for removed sections; recognized during parsing so their content is skipped cleanly.
  private static let removedHeaders: Set<String> = [
    "=== Prompt Read Mode ===",
    "=== Prompt & Read ===",
    "=== Prompt Voice Mode ===",
  ]

  static func section(forHeader line: String) -> SystemPromptSection? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    for section in SystemPromptSection.allCases where trimmed == section.fileHeader {
      return section
    }
    return legacyHeaders[trimmed]
  }

  static func isRemovedHeader(_ line: String) -> Bool {
    removedHeaders.contains(line.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// Reads and writes the single system-prompts.md file in UserContext.
final class SystemPromptsStore {
  static let shared = SystemPromptsStore()
  static let fileName = "system-prompts.md"

  private let queue = DispatchQueue(label: "com.whisper-shortcut.systempromptsstore", qos: .userInitiated)
  private var contextDirectoryURL: URL { AppSupportPaths.userContextURL() }

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

  /// Chat system prompt. Returns default if section missing or empty.
  func loadChatSystemPrompt() -> String {
    (loadSection(.chat)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? AppConstants.defaultChatSystemPrompt
  }

  /// Whisper Glossary: short vocabulary list for offline Whisper conditioning. Returns empty string if missing or empty (no conditioning).
  func loadWhisperGlossary() -> String {
    (loadSection(.whisperGlossary)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? AppConstants.defaultWhisperGlossary
  }

  // MARK: - Glossary Append

  /// What happened when a term was offered to the Glossary. The caller turns this into the popup
  /// the user sees, so every outcome carries the term it is talking about.
  enum GlossaryAppendResult: Equatable {
    case added(String)
    case duplicate(String)
    /// The selection was not a term: empty, a whole sentence, or an implausible length.
    case notATerm(String)
    /// Adding would push the conditioning text past what Whisper reads (see `glossaryCharBudget`).
    case budgetExceeded(String)

    var termIfAny: String? {
      switch self {
      case .added(let t), .duplicate(let t), .notATerm(let t), .budgetExceeded(let t): return t
      }
    }
  }

  /// Whisper conditions on at most 224 tokens and silently drops the rest, so an unbounded
  /// glossary quietly stops working from somewhere in the middle. ~1200 characters is a
  /// conservative stand-in for that budget (German compounds tokenize badly), and refusing a term
  /// with a message beats appending one that will never be read.
  static let glossaryCharBudget = 1_200

  /// The longest a selection may be and still be a vocabulary entry rather than prose.
  private static let maxTermCharacters = 60
  private static let maxTermWords = 5

  /// Adds a user-selected spelling to the Glossary, if it is a term and not already there.
  ///
  /// Deliberately dumb: no model, no fuzzy matching, no network. The user has told the app the
  /// correct spelling by selecting it — the app's job is to store it verbatim, which is also what
  /// makes this usable in Offline Mode, where every model-driven learning path is switched off.
  func appendToWhisperGlossary(_ raw: String) -> GlossaryAppendResult {
    let term = Self.normaliseTerm(raw)
    guard !term.isEmpty, term.count <= Self.maxTermCharacters,
      term.split(separator: " ").count <= Self.maxTermWords
    else {
      return .notATerm(term.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : term)
    }

    let existing = loadWhisperGlossary()
    if Self.glossaryContains(term, in: existing) { return .duplicate(term) }
    guard existing.count + term.count + 2 <= Self.glossaryCharBudget else {
      return .budgetExceeded(term)
    }

    let updated = existing.isEmpty ? term : existing + ", " + term
    updateSection(.whisperGlossary, content: updated)
    DebugLogger.log("GLOSSARY: Added \"\(term)\" (\(updated.count) chars total)")
    return .added(term)
  }

  /// Trims the selection to what belongs in a vocabulary list: no surrounding whitespace, no
  /// trailing sentence punctuation, no internal line breaks. Everything else is left alone —
  /// capitalisation and internal punctuation are part of the spelling the user is asserting.
  static func normaliseTerm(_ raw: String) -> String {
    let collapsed = raw.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]"))
  }

  /// Case- and separator-insensitive membership test. The glossary is comma-separated by
  /// convention but users write one term per line too, so both are treated as separators.
  static func glossaryContains(_ term: String, in glossary: String) -> Bool {
    let needle = term.lowercased()
    return glossary
      .components(separatedBy: CharacterSet(charactersIn: ",\n"))
      .map { normaliseTerm($0).lowercased() }
      .contains(needle)
  }

  /// Read Aloud rewrite prompt. Returns default if section missing or empty.
  func loadReadAloudRewritePrompt() -> String {
    (loadSection(.readAloudRewrite)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? AppConstants.defaultReadAloudRewritePrompt
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
      NotificationCenter.default.post(name: .contextFileDidUpdate, object: nil)
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
      NotificationCenter.default.post(name: .contextFileDidUpdate, object: nil)
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
    AppSupportPaths.ensureDirectoryExists(contextDirectoryURL)
  }

  private func defaultFormattedContent() -> String {
    formatContent([
      .dictation: AppConstants.defaultTranscriptionSystemPrompt,
      .whisperGlossary: AppConstants.defaultWhisperGlossary,
      .promptMode: AppConstants.defaultPromptModeSystemPrompt,
      .chat: AppConstants.defaultChatSystemPrompt,
      .readAloudRewrite: AppConstants.defaultReadAloudRewritePrompt,
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
          if SystemPromptSection.section(forHeader: lines[i]) != nil || SystemPromptSection.isRemovedHeader(lines[i]) { break }
          bodyLines.append(lines[i])
          i += 1
        }
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        result[section] = body
      } else if SystemPromptSection.isRemovedHeader(line) {
        i += 1
        while i < lines.count {
          if SystemPromptSection.section(forHeader: lines[i]) != nil || SystemPromptSection.isRemovedHeader(lines[i]) { break }
          i += 1
        }
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
    let content = formatContent([
      .dictation: dictation,
      .whisperGlossary: AppConstants.defaultWhisperGlossary,
      .promptMode: promptMode,
      .chat: AppConstants.defaultChatSystemPrompt,
      .readAloudRewrite: AppConstants.defaultReadAloudRewritePrompt,
    ])
    do {
      try content.write(to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log("SYSTEM-PROMPTS: Migrated to \(Self.fileName) from UserDefaults")
    } catch {
      DebugLogger.logError("SYSTEM-PROMPTS: Migration failed: \(error.localizedDescription)")
    }
  }
}

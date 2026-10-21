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
///
/// The file holds prompts users write by hand (a practice's whole documentation format can live in
/// the Dictate Prompt section), so the store treats it as user data, not cache:
/// - it never writes defaults over a file that exists but cannot be read (macOS App Data
///   protection answers EPERM when a build is not recognised as the container's owner — see
///   `Docs/data-directories.md`); it records `unreadableReason` and the runtime falls back to the
///   defaults for that launch only, without touching the file;
/// - before a write changes a section the user customized, the previous file is kept as
///   `system-prompts.md.bak` next to it (one rolling copy).
final class SystemPromptsStore {
  static let shared = SystemPromptsStore()
  static let fileName = "system-prompts.md"
  static let backupFileName = "system-prompts.md.bak"

  private let contextDirectoryOverride: URL?
  private var contextDirectoryURL: URL { contextDirectoryOverride ?? AppSupportPaths.userContextURL() }

  private var fileURL: URL {
    contextDirectoryURL.appendingPathComponent(Self.fileName)
  }

  /// URL of the system-prompts file (e.g. for opening in Finder or external editor).
  var systemPromptsFileURL: URL { fileURL }

  var backupFileURL: URL { contextDirectoryURL.appendingPathComponent(Self.backupFileName) }

  private let stateLock = NSLock()
  private var _unreadableReason: String?

  /// Set while the file exists but cannot be read (e.g. "EPERM (Operation not permitted)"). The
  /// prompts in use are then the app defaults, and every write is refused so the file survives.
  var unreadableReason: String? {
    stateLock.lock(); defer { stateLock.unlock() }
    return _unreadableReason
  }

  private init() { contextDirectoryOverride = nil }

  /// Tests only: a store rooted in a scratch directory instead of the real UserContext.
  init(contextDirectoryURL: URL) { contextDirectoryOverride = contextDirectoryURL }

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
  static let maxTermCharacters = 60
  /// Same cap the transcription prompt applies (`GlossaryDocument.maxTermWords`). This used
  /// to be 5 here and 3 in the prompt builder, so a 4- or 5-word term never reached the model.
  static let maxTermWords = GlossaryDocument.maxTermWords

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
    DebugLogger.log("GLOSSARY: Added \(DebugLogger.redacted(term)) (\(updated.count) chars total)")
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

  /// Membership test for "Add Selection to Glossary". Comma-separated lines and one term per
  /// line are both real; annotations are read, not compared as raw text. Matching is
  /// `GlossaryDocument.fold`, so "Gödde" is the term "Godde" and a rejected spelling inside
  /// `(not …)` — a lowercased split on commas used to miss both.
  static func glossaryContains(_ term: String, in glossary: String) -> Bool {
    let needle = GlossaryDocument.fold(normaliseTerm(term))
    guard !needle.isEmpty else { return false }
    if GlossaryDocument.parse(glossary).entries.contains(where: {
      GlossaryDocument.fold(normaliseTerm($0.term)) == needle
    }) {
      return true
    }
    // Rejected spellings are read off the line, not off the entries: an annotation with
    // no term beside it never becomes an entry, and it is still a spelling the user rejected.
    for line in glossary.components(separatedBy: .newlines) {
      for rejected in GlossaryDocument.rejectedSpellings(on: line)
        where GlossaryDocument.fold(normaliseTerm(rejected)) == needle
      {
        return true
      }
    }
    return false
  }

  /// Read Aloud rewrite prompt. Returns default if section missing or empty.
  func loadReadAloudRewritePrompt() -> String {
    (loadSection(.readAloudRewrite)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? AppConstants.defaultReadAloudRewritePrompt
  }

  /// Load full file content for the editor. Returns default formatted content if the file is missing
  /// (after migration attempt) or unreadable.
  func loadFullContent() -> String {
    guard case .contents(let content) = currentFile() else { return defaultFormattedContent() }
    return content
  }

  /// Recreate the system-prompts file with app defaults. Used after "Delete context data".
  func resetSystemPromptsToDefaults() {
    ensureDirectoryExists()
    if write(defaultFormattedContent(), reason: "reset to defaults") {
      NotificationCenter.default.post(name: .contextFileDidUpdate, object: nil)
    }
  }

  /// Save full file content from the editor. Parses sections and rewrites so format is canonical.
  @discardableResult
  func saveFullContent(_ rawContent: String) -> Bool {
    if case .unreadable = currentFile() { return refuseWrite("save") }
    return write(formatContent(parseSections(from: rawContent)), reason: "save")
  }

  /// Update a single section (e.g. when Smart Improvement applies a suggestion). Writes the full file.
  /// Returns false — and leaves the file alone — when the file exists but cannot be read, because the
  /// only thing to merge the section into would then be the defaults.
  @discardableResult
  func updateSection(_ section: SystemPromptSection, content: String) -> Bool {
    var parsed: [SystemPromptSection: String]
    switch currentFile() {
    case .contents(let existing): parsed = parseSections(from: existing)
    case .missing: parsed = parseSections(from: defaultFormattedContent())
    case .unreadable: return refuseWrite("update section \(section.rawValue)")
    }
    parsed[section] = content
    guard write(formatContent(parsed), reason: "update section \(section.rawValue)") else { return false }
    NotificationCenter.default.post(name: .contextFileDidUpdate, object: nil)
    return true
  }

  /// Current content for a section (raw, for display or comparison). Used by Smart Improvement.
  /// Nil when the section is absent or the file cannot be read (see `unreadableReason`).
  func loadSection(_ section: SystemPromptSection) -> String? {
    guard case .contents = currentFile() else { return nil }
    liftUnchangedDefaultsOnce()
    guard case .contents(let content) = readFile() else { return nil }
    return parseSections(from: content)[section]
  }

  /// One line per section — custom, default or empty, plus a character count — and one for the file
  /// itself. Called once at launch so the next "my prompt is gone" report can be answered from the
  /// log. Never logs prompt content.
  func logStartupSummary() {
    let state = currentFile()
    // The account's real home, not the sandbox's (which is the container itself), so the log shows
    // which physical file was read.
    let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) }
      ?? FileManager.default.homeDirectoryForCurrentUser.path
    let path = fileURL.path.replacingOccurrences(of: home, with: "~")
    switch state {
    case .missing:
      DebugLogger.logError("SYSTEM-PROMPTS: \(path) missing and could not be created — using defaults")
      return
    case .unreadable(let reason):
      DebugLogger.logError("SYSTEM-PROMPTS: \(path) exists but is unreadable (\(reason)) — using defaults, file left untouched")
      return
    case .contents:
      break
    }
    liftUnchangedDefaultsOnce()
    guard case .contents(let content) = readFile() else { return }
    let hasBackup = FileManager.default.fileExists(atPath: backupFileURL.path)
    DebugLogger.log("SYSTEM-PROMPTS: \(path) readable (\(content.count) chars, backup \(hasBackup ? "present" : "none"))")
    let parsed = parseSections(from: content)
    for section in SystemPromptSection.allCases {
      DebugLogger.log("SYSTEM-PROMPTS: section \(section.rawValue) = \(Self.describe(parsed[section], for: section))")
    }
  }

  /// "custom (1234 chars)", "default (812 chars)", "empty" or "missing" — no content.
  static func describe(_ body: String?, for section: SystemPromptSection) -> String {
    guard let body else { return "missing" }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "empty" }
    let kind = isCustomized(trimmed, for: section) ? "custom" : "default"
    return "\(kind) (\(trimmed.count) chars)"
  }

  /// True when the section holds text the user wrote: non-empty and not any default the app shipped.
  static func isCustomized(_ body: String, for section: SystemPromptSection) -> Bool {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && !SystemPromptDefaultsHistory.isShippedDefault(trimmed, for: section)
  }

  /// True when going from `old` to `new` changes at least one section the user had customized —
  /// the writes worth a backup.
  func changesCustomizedSection(from old: String, to new: String) -> Bool {
    let before = parseSections(from: old)
    let after = parseSections(from: new)
    return SystemPromptSection.allCases.contains { section in
      guard let previous = before[section], Self.isCustomized(previous, for: section) else { return false }
      return SystemPromptDefaultsHistory.normalized(previous)
        != SystemPromptDefaultsHistory.normalized(after[section] ?? "")
    }
  }

  private var didLiftUnchangedDefaults = false

  /// Once per launch: sections the user never edited — still equal to some default this app has
  /// shipped before — are rewritten to the current default. Without this, a default that changes
  /// in an update stays frozen at whatever wording was materialised on first launch (see
  /// `SystemPromptDefaultsHistory`). Edited sections are never touched.
  private func liftUnchangedDefaultsOnce() {
    guard !didLiftUnchangedDefaults else { return }
    guard case .contents(let content) = readFile() else { return }
    didLiftUnchangedDefaults = true
    var parsed = parseSections(from: content)
    let upgrades = SystemPromptDefaultsHistory.upgrades(for: parsed)
    guard !upgrades.isEmpty else { return }
    for (section, current) in upgrades { parsed[section] = current }
    let names = upgrades.keys.map(\.rawValue).sorted().joined(separator: ", ")
    if write(formatContent(parsed), reason: "lift unedited default(s): \(names)") {
      NotificationCenter.default.post(name: .contextFileDidUpdate, object: nil)
    }
  }

  // MARK: - File access

  enum FileState: Equatable {
    case missing
    case contents(String)
    /// The file exists (or its directory cannot be entered) but reading failed; carries the errno.
    case unreadable(String)
  }

  /// Reads the file, migrating defaults in only when it is genuinely absent (ENOENT). Records or
  /// clears `unreadableReason` and logs the transition into the unreadable state once.
  private func currentFile() -> FileState {
    ensureDirectoryExists()
    var state = readFile()
    if state == .missing {
      performMigration()
      state = readFile()
    }
    let reason: String? = { if case .unreadable(let r) = state { return r } else { return nil } }()
    stateLock.lock()
    let changed = reason != _unreadableReason
    _unreadableReason = reason
    stateLock.unlock()
    if changed, let reason {
      DebugLogger.logError("SYSTEM-PROMPTS: \(Self.fileName) exists but cannot be read: \(reason). Using defaults; the file will not be overwritten.")
    } else if changed {
      DebugLogger.log("SYSTEM-PROMPTS: \(Self.fileName) readable again")
    }
    return state
  }

  /// `stat` first, so "no such file" (migrate) is told apart from "not allowed to look" (EPERM /
  /// EACCES from App Data protection or permissions — never migrate, never overwrite).
  func readFile() -> FileState {
    var info = stat()
    if stat(fileURL.path, &info) != 0 {
      let code = errno
      return code == ENOENT ? .missing : .unreadable(Self.describeErrno(code))
    }
    do {
      let data = try Data(contentsOf: fileURL)
      guard let text = String(data: data, encoding: .utf8) else { return .unreadable("not valid UTF-8") }
      return .contents(text)
    } catch {
      let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
      if let underlying, underlying.domain == NSPOSIXErrorDomain {
        return .unreadable(Self.describeErrno(Int32(underlying.code)))
      }
      return .unreadable("read failed: \(error.localizedDescription)")
    }
  }

  private static func describeErrno(_ code: Int32) -> String {
    let name: String
    switch code {
    case EPERM: name = "EPERM"
    case EACCES: name = "EACCES"
    case ENOTDIR: name = "ENOTDIR"
    case EIO: name = "EIO"
    default: name = "errno \(code)"
    }
    return "\(name) (\(String(cString: strerror(code))))"
  }

  /// The editor autosaves every typing pause. Overwriting `.bak` on each of those saves would replace
  /// the original prompt with half-typed text seconds after the user started over-typing it, so a
  /// backup younger than this window is kept: it already holds the file from before the burst.
  static let backupBurstWindow: TimeInterval = 15 * 60

  private func backupIsFromCurrentEditBurst() -> Bool {
    guard let modified = (try? FileManager.default.attributesOfItem(atPath: backupFileURL.path))?[.modificationDate] as? Date
    else { return false }
    return Date().timeIntervalSince(modified) < Self.backupBurstWindow
  }

  /// Writes the whole file. If the write changes a section the user customized, the current file is
  /// first copied to `system-prompts.md.bak`; when that copy fails the write is abandoned.
  @discardableResult
  private func write(_ content: String, reason: String) -> Bool {
    if case .contents(let existing) = readFile() {
      if existing == content { return true }
      if changesCustomizedSection(from: existing, to: content), !backupIsFromCurrentEditBurst() {
        do {
          try existing.write(to: backupFileURL, atomically: true, encoding: .utf8)
        } catch {
          DebugLogger.logError("SYSTEM-PROMPTS: Backup before \(reason) failed, not writing: \(error.localizedDescription)")
          return false
        }
      }
    }
    do {
      try content.write(to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log("SYSTEM-PROMPTS: Wrote \(Self.fileName) (\(reason))")
      return true
    } catch {
      DebugLogger.logError("SYSTEM-PROMPTS: Failed to write (\(reason)): \(error.localizedDescription)")
      return false
    }
  }

  private func refuseWrite(_ action: String) -> Bool {
    DebugLogger.logError("SYSTEM-PROMPTS: Refused to \(action): \(Self.fileName) exists but cannot be read (\(unreadableReason ?? "unknown"))")
    return false
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

  /// First launch only: writes the defaults (or the pre-file UserDefaults prompts). Uses
  /// `.withoutOverwriting` (O_EXCL), so even a racing or mis-detected "missing" cannot replace an
  /// existing file.
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
      try Data(content.utf8).write(to: fileURL, options: .withoutOverwriting)
      DebugLogger.log("SYSTEM-PROMPTS: Created \(Self.fileName) (migrated from UserDefaults / defaults)")
    } catch {
      DebugLogger.logError("SYSTEM-PROMPTS: Creating \(Self.fileName) failed: \(error.localizedDescription)")
    }
  }
}

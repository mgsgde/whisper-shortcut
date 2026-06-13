//
//  ChatMemoryStore.swift
//  WhisperShortcut
//
//  Persistent, user-visible "memory" for Chat: a small curated list of durable facts about the
//  user (role, preferences, recurring context) that is injected into every chat system prompt.
//
//  Deliberately separate from SystemPromptsStore (UserContext/system-prompts.md): that file holds
//  user-authored config and is rewritten wholesale by Smart Improvement. Memory is model-written
//  and churns, so it lives in its own file to avoid cross-writes and keep the mental model clean.
//
//  Storage: UserContext/memory.md — a plain Markdown bullet list, one fact per line ("- fact").
//  Bounded by `maxFacts` / `maxFactLength` so the always-injected text stays small (token cost +
//  answer quality). No embeddings / RAG — a short curated list is the whole design.
//

import Foundation

/// Reads and writes UserContext/memory.md (the chat's persistent user-fact memory).
final class ChatMemoryStore {
  static let shared = ChatMemoryStore()
  static let fileName = "memory.md"

  /// Max number of facts retained; oldest are dropped when exceeded.
  private let maxFacts = 40
  /// Max characters per fact (longer facts are truncated) — keeps single entries from bloating.
  private let maxFactLength = 300

  private var fileURL: URL { AppSupportPaths.userContextURL().appendingPathComponent(Self.fileName) }

  /// URL of the memory file (e.g. for opening in Finder).
  var memoryFileURL: URL { fileURL }

  private init() {}

  // MARK: - Read

  /// The full memory as a Markdown bullet list, trimmed. Empty string when there is no memory
  /// (callers treat empty as "do not inject anything").
  func loadMemory() -> String {
    facts().map { "- \($0)" }.joined(separator: "\n")
  }

  /// Parsed list of facts (leading "- " stripped, blank lines dropped), oldest first.
  func facts() -> [String] {
    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
    return Self.parseFactLines(content)
  }

  /// Splits one-fact-per-line text into facts: strips a leading "- "/"-" bullet, trims, drops blanks.
  private static func parseFactLines(_ text: String) -> [String] {
    text
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { line in
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("- ") { s.removeFirst(2) }
        else if s.hasPrefix("-") { s.removeFirst(1) }
        return s.trimmingCharacters(in: .whitespaces)
      }
      .filter { !$0.isEmpty }
  }

  // MARK: - Write

  /// Adds a fact (deduped case-insensitively, newest wins). Returns false if empty or a duplicate.
  @discardableResult
  func addFact(_ rawFact: String) -> Bool {
    var fact = rawFact.trimmingCharacters(in: .whitespacesAndNewlines)
    // Collapse to a single line — memory is one fact per line.
    fact = fact.replacingOccurrences(of: "\n", with: " ")
    if fact.hasPrefix("- ") { fact.removeFirst(2) }
    guard !fact.isEmpty else { return false }
    if fact.count > maxFactLength { fact = String(fact.prefix(maxFactLength)) }

    var existing = facts()
    if existing.contains(where: { $0.caseInsensitiveCompare(fact) == .orderedSame }) {
      return false
    }
    existing.append(fact)
    if existing.count > maxFacts { existing.removeFirst(existing.count - maxFacts) }
    write(existing)
    DebugLogger.logSuccess("CHAT-MEMORY: Added fact (now \(existing.count))")
    return true
  }

  /// Removes every fact that contains `needle` (case-insensitive). Returns the number removed.
  @discardableResult
  func removeFacts(matching needle: String) -> Int {
    let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }
    let existing = facts()
    let kept = existing.filter { $0.range(of: trimmed, options: .caseInsensitive) == nil }
    let removed = existing.count - kept.count
    if removed > 0 {
      write(kept)
      DebugLogger.logSuccess("CHAT-MEMORY: Removed \(removed) fact(s) matching \"\(trimmed)\"")
    }
    return removed
  }

  /// Replaces the entire memory with the given multi-line text (one fact per line). Used by the
  /// Settings editor. Re-parses so the on-disk format stays canonical.
  func saveRawText(_ raw: String) {
    write(Array(Self.parseFactLines(raw).suffix(maxFacts)))
  }

  /// Clears all memory.
  func clear() {
    write([])
    DebugLogger.log("CHAT-MEMORY: Cleared")
  }

  // MARK: - Private

  private func write(_ facts: [String]) {
    AppSupportPaths.ensureDirectoryExists(AppSupportPaths.userContextURL())
    let body = facts.map { "- \($0)" }.joined(separator: "\n")
    do {
      try body.write(to: fileURL, atomically: true, encoding: .utf8)
      NotificationCenter.default.post(name: .chatMemoryDidUpdate, object: nil)
    } catch {
      DebugLogger.logError("CHAT-MEMORY: Failed to write \(Self.fileName): \(error.localizedDescription)")
    }
  }
}

//
//  WorkspaceMapStore.swift
//  WhisperShortcut
//
//  The chat's map of the user's shared folders: model-written notes about *where things live*
//  ("~/Notes/Journal — daily journal entries, one file per day"). Injected into the chat system
//  prompt whenever workspace folders are configured, so the model knows where to look before it
//  starts searching.
//
//  Deliberately separate from ChatMemoryStore (memory.md), for the same reason memory.md is
//  separate from system-prompts.md: different writer, different lifetime. Map entries are tied to
//  folders that can be un-shared — and when that happens the matching entries are dropped, which
//  would be wrong to do to durable personal facts.
//
//  Storage: UserContext/workspace-map.md — one entry per line, "path — note".
//  No index, no embeddings: a short curated list plus the on-demand search tools is the design.
//

import Foundation

/// Reads and writes UserContext/workspace-map.md (what the chat has learned about the user's files).
final class WorkspaceMapStore {
  static let shared = WorkspaceMapStore()
  static let fileName = "workspace-map.md"

  /// One learned location: where it is, and what is there.
  struct Entry {
    let path: String
    let note: String

    var line: String { "\(path) — \(note)" }
  }

  /// Max entries retained; oldest are dropped when exceeded. Bounded because this text is
  /// injected into every request once folders are shared.
  private let maxEntries = 40
  private let maxNoteLength = 200

  private var fileURL: URL { AppSupportPaths.userContextURL().appendingPathComponent(Self.fileName) }

  var mapFileURL: URL { fileURL }

  private init() {}

  // MARK: - Read

  /// The map as a Markdown bullet list, or "" when empty (callers treat empty as "inject nothing").
  func loadMap() -> String {
    entries().map { "- \($0.line)" }.joined(separator: "\n")
  }

  func entries() -> [Entry] {
    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
    return Self.parseEntryLines(content)
  }

  /// Parses "path — note" lines. The em dash is the canonical separator we write; a plain " - "
  /// is also accepted so a hand-edited file still round-trips. A line with no separator is kept
  /// as a path with an empty note rather than being dropped — silently deleting the user's edit
  /// would be worse than storing it verbatim.
  private static func parseEntryLines(_ text: String) -> [Entry] {
    text
      .split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap { rawLine in
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("- ") { line.removeFirst(2) }
        else if line.hasPrefix("-") { line.removeFirst(1) }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        for separator in [" — ", " – ", " - "] {
          if let range = line.range(of: separator) {
            let path = String(line[line.startIndex..<range.lowerBound])
              .trimmingCharacters(in: .whitespaces)
            let note = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            return Entry(path: path, note: note)
          }
        }
        return Entry(path: line, note: "")
      }
  }

  // MARK: - Write

  /// Records what lives at `path`. Re-recording a known path replaces its note (the model
  /// correcting itself must not leave both versions behind).
  @discardableResult
  func remember(path rawPath: String, note rawNote: String) -> Bool {
    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    var note = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: " ")
    guard !path.isEmpty, !note.isEmpty else { return false }
    if note.count > maxNoteLength { note = String(note.prefix(maxNoteLength)) }

    var existing = entries().filter { $0.path.caseInsensitiveCompare(path) != .orderedSame }
    existing.append(Entry(path: path, note: note))
    if existing.count > maxEntries { existing.removeFirst(existing.count - maxEntries) }
    write(existing)
    DebugLogger.logSuccess("WORKSPACE-MAP: Recorded \(path) (now \(existing.count))")
    return true
  }

  /// Removes entries whose path or note contains `needle` (case-insensitive). Returns the count.
  @discardableResult
  func forget(matching needle: String) -> Int {
    let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }
    let existing = entries()
    let kept = existing.filter {
      $0.path.range(of: trimmed, options: .caseInsensitive) == nil
        && $0.note.range(of: trimmed, options: .caseInsensitive) == nil
    }
    let removed = existing.count - kept.count
    if removed > 0 {
      write(kept)
      DebugLogger.logSuccess("WORKSPACE-MAP: Forgot \(removed) entr(ies) matching \"\(trimmed)\"")
    }
    return removed
  }

  /// Drops every entry that points inside `folderPath`. Called when a folder is un-shared: those
  /// notes describe files the chat can no longer reach, so keeping them would send the model
  /// hunting for paths that now fail.
  func forgetEntriesUnder(folderPath: String) {
    let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
    let existing = entries()
    let kept = existing.filter { entry in
      let expanded = (entry.path as NSString).expandingTildeInPath
      return expanded != folderPath && !expanded.hasPrefix(prefix)
    }
    guard kept.count != existing.count else { return }
    write(kept)
    DebugLogger.log(
      "WORKSPACE-MAP: Dropped \(existing.count - kept.count) entr(ies) under \(folderPath)")
  }

  /// Replaces the whole map with the given multi-line text. Used by the Settings editor.
  func saveRawText(_ raw: String) {
    write(Array(Self.parseEntryLines(raw).suffix(maxEntries)))
  }

  func clear() {
    write([])
    DebugLogger.log("WORKSPACE-MAP: Cleared")
  }

  // MARK: - Private

  private func write(_ entries: [Entry]) {
    AppSupportPaths.ensureDirectoryExists(AppSupportPaths.userContextURL())
    let body = entries.map { "- \($0.line)" }.joined(separator: "\n")
    do {
      try body.write(to: fileURL, atomically: true, encoding: .utf8)
      NotificationCenter.default.post(name: .workspaceMapDidUpdate, object: nil)
    } catch {
      DebugLogger.logError(
        "WORKSPACE-MAP: Failed to write \(Self.fileName): \(error.localizedDescription)")
    }
  }
}

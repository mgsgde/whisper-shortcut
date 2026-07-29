//
//  TranscriptionHistoryStore.swift
//  WhisperShortcut
//
//  The last few dictation results, so getting one back doesn't mean opening Finder.
//

import Foundation

/// Keeps the most recent dictation results available for one-click re-copying.
///
/// Before this existed, a transcription that got pasted into the wrong place — or overwritten on
/// the clipboard by the next copy — could only be recovered by navigating to
/// `~/Library/Containers/…/UserContext/interactions-<date>.jsonl` by hand. The interaction log is
/// the wrong tool for that: it is opt-in, keyed by date, holds every mode, and has no UI.
///
/// Deliberately separate from `ContextLogger`: that one feeds Smart Improvement analysis and can
/// be switched off, whereas this is a small user-facing convenience. It does respect the same
/// privacy intent, though — when interaction logging is off, entries live in memory for the
/// session only and never touch the disk.
final class TranscriptionHistoryStore {

  static let shared = TranscriptionHistoryStore()

  struct Entry: Codable {
    let ts: Date
    let text: String
  }

  /// Matches the number of rows in the "Recent Transcriptions" submenu. Small on purpose: this is
  /// a rescue hatch for "where did my last dictation go", not an archive.
  private static let maxEntries = 5

  private let fileName = "recent-transcriptions.json"
  private let queue = DispatchQueue(label: "com.whisper-shortcut.transcriptionhistory")
  /// Newest first.
  private var storage: [Entry] = []

  private lazy var fileURL: URL = {
    AppSupportPaths.whisperShortcutApplicationSupportURL().appendingPathComponent(fileName)
  }()

  private init() {
    storage = loadFromDisk()
  }

  // MARK: - Reading

  /// Newest first.
  var entries: [Entry] {
    queue.sync { storage }
  }

  var mostRecent: Entry? {
    queue.sync { storage.first }
  }

  // MARK: - Writing

  /// Records a dictation result. Ignores empty text and exact repeats of the newest entry, so a
  /// re-run that produces identical output doesn't push a useful older entry out of the list.
  func record(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    queue.async {
      if self.storage.first?.text == trimmed { return }
      self.storage.insert(Entry(ts: Date(), text: trimmed), at: 0)
      if self.storage.count > Self.maxEntries {
        self.storage.removeLast(self.storage.count - Self.maxEntries)
      }
      self.persistIfAllowed()
    }
  }

  func clear() {
    queue.async {
      self.storage = []
      try? FileManager.default.removeItem(at: self.fileURL)
    }
  }

  // MARK: - Persistence

  /// Mirrors `ContextLogger.isLoggingEnabled` (default on when the key was never written).
  private var persistenceAllowed: Bool {
    UserDefaults.standard.object(forKey: UserDefaultsKeys.contextLoggingEnabled) == nil
      ? true
      : UserDefaults.standard.bool(forKey: UserDefaultsKeys.contextLoggingEnabled)
  }

  /// Called on `queue`.
  private func persistIfAllowed() {
    guard persistenceAllowed else { return }
    do {
      // Don't depend on ContextLogger having initialized first — it is what normally creates the
      // Application Support folder, but it is lazy and may never run when logging is off.
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(storage).write(to: fileURL, options: .atomic)
    } catch {
      DebugLogger.logWarning("TRANSCRIPTION-HISTORY: Failed to persist: \(error.localizedDescription)")
    }
  }

  private func loadFromDisk() -> [Entry] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let decoded = try? decoder.decode([Entry].self, from: data) else {
      DebugLogger.logWarning("TRANSCRIPTION-HISTORY: Could not decode \(fileName); starting empty")
      return []
    }
    return Array(decoded.prefix(Self.maxEntries))
  }

  // MARK: - Display

  /// Single-line, length-capped form for a menu row.
  static func menuTitle(for entry: Entry, maxLength: Int = 44) -> String {
    let collapsed = entry.text
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    guard collapsed.count > maxLength else { return collapsed }
    return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
  }
}

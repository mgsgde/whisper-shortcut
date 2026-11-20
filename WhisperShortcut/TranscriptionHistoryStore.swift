//
//  TranscriptionHistoryStore.swift
//  WhisperShortcut
//
//  The last few dictation results, so getting one back doesn't mean opening Finder.
//

import Foundation

/// Keeps recent dictation, Dictate Prompt and template results for one-click re-copying and for
/// the problem report.
///
/// The status menu shows at most `menuEntries` rows. The store keeps more than that
/// (`maxEntries`) so a report can still reach a result that has scrolled off the menu, including
/// what the model returned before cleanup.
///
/// Before this existed, a transcription that got pasted into the wrong place — or overwritten on
/// the clipboard by the next copy — could only be recovered by navigating to
/// `~/Library/Containers/…/UserContext/interactions-<date>.jsonl` by hand. The interaction log is
/// the wrong tool for that: it is opt-in, keyed by date, holds every mode, and has no UI.
///
/// Deliberately separate from `ContextLogger`: that one is the opt-in usage log the Chat and AI apps read when asked to tune the app, and can
/// be switched off, whereas this is a small user-facing convenience. It does respect the same
/// privacy intent, though — when interaction logging is off, entries live in memory for the
/// session only and never touch the disk.
final class TranscriptionHistoryStore {

  static let shared = TranscriptionHistoryStore()

  struct Entry: Codable {
    let ts: Date
    let text: String
    /// What a "report a problem" window needs. All optional so files written before they
    /// existed still decode.
    var mode: String?
    var transcriptionModel: String?
    var transcriptionModelName: String?
    /// Tails the glossary-echo strip removed. Empty = ran, nothing removed; nil = unknown.
    var glossaryEchoRemoved: [String]?
    /// Model text before glossary-echo stripping, spoken punctuation or any other cleanup.
    var rawOutput: String? = nil
    var audioDurationSeconds: Double? = nil
    /// Set when a template produced this result.
    var templateName: String? = nil
    var templateID: UUID? = nil
    /// Size and hash of the prompt actually sent to the model. Nil when none was sent.
    var promptChars: Int? = nil
    var promptHash: String? = nil
    /// `ReportConfigFingerprint` at the time of the dictation.
    var configHash: String? = nil
    var appVersion: String? = nil
  }

  /// How many results are kept for the problem report. The status menu shows only `menuEntries`.
  private static let maxEntries = 10

  /// Rows in the "Recent Transcriptions" submenu.
  static let menuEntries = 5

  static let fileName = "recent-transcriptions.json"
  private let queue = DispatchQueue(label: "com.whisper-shortcut.transcriptionhistory")
  /// Newest first.
  private var storage: [Entry] = []
  /// Tests pass their own file so they never touch the user's history.
  private let fileURLOverride: URL?

  private var fileURL: URL {
    fileURLOverride
      ?? AppSupportPaths.whisperShortcutApplicationSupportURL().appendingPathComponent(Self.fileName)
  }

  private init() {
    fileURLOverride = nil
    storage = loadFromDisk()
  }

  /// A store that reads and writes only `fileURL`.
  init(fileURL: URL) {
    fileURLOverride = fileURL
    storage = loadFromDisk()
  }

  /// Waits until queued `record` calls have updated `entries`.
  func waitForPendingWrites() {
    queue.sync {}
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
  func record(
    _ text: String, mode: String? = nil, transcriptionModel: String? = nil,
    transcriptionModelName: String? = nil, glossaryEchoRemoved: [String]? = nil,
    rawOutput: String? = nil, audioDurationSeconds: Double? = nil,
    templateName: String? = nil, templateID: UUID? = nil,
    promptChars: Int? = nil, promptHash: String? = nil,
    configHash: String? = nil, appVersion: String? = nil
  ) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    queue.async {
      if self.storage.first?.text == trimmed { return }
      self.storage.insert(Entry(
        ts: Date(), text: trimmed, mode: mode, transcriptionModel: transcriptionModel,
        transcriptionModelName: transcriptionModelName, glossaryEchoRemoved: glossaryEchoRemoved,
        rawOutput: rawOutput, audioDurationSeconds: audioDurationSeconds,
        templateName: templateName, templateID: templateID,
        promptChars: promptChars, promptHash: promptHash,
        configHash: configHash, appVersion: appVersion), at: 0)
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

  /// Same gate as `ContextLogger`: the "Save usage data" preference, and Offline Mode over it.
  /// In Offline Mode the last transcripts stay in memory for the menu but are never written out.
  private var persistenceAllowed: Bool { ContextLoggingPreference.isEnabled }

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
      DebugLogger.logWarning("TRANSCRIPTION-HISTORY: Failed to persist: \(error.logDescription)")
    }
  }

  private func loadFromDisk() -> [Entry] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let decoded = try? decoder.decode([Entry].self, from: data) else {
      DebugLogger.logWarning("TRANSCRIPTION-HISTORY: Could not decode \(Self.fileName); starting empty")
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

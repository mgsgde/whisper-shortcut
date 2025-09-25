//
//  HistoryLogger.swift
//  WhisperShortcut
//
//  Stores a rolling history of recent prompts/transcriptions and can export
//  the last N entries to a temp file for quick viewing in an editor.
//

import Foundation
import AppKit

final class HistoryLogger {
  static let shared = HistoryLogger()

  private enum Constants {
    static let appSupportSubdirectory = "WhisperShortcut"
    static let historyFilename = "history.json"
    static let maxStoredEntries = 200
    static let exportFilename = "WhisperShortcut-Recent.txt"
    static let dateFormat = "yyyy-MM-dd HH:mm:ss"
  }

  enum EventType: String, Codable {
    case prompt
    case transcription
    case voiceResponse
    case readingText
  }

  struct Entry: Codable {
    let timestamp: Date
    let type: EventType
    let text: String
  }

  private let ioQueue = DispatchQueue(
    label: "com.magnusgoedde.whispershortcut.history",
    qos: .background
  )

  private var entries: [Entry] = []

  private init() {
    loadFromDisk()
  }

  // MARK: - Public API
  func log(type: EventType, text: String) {
    let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let entry = Entry(timestamp: Date(), type: type, text: cleanText)
    ioQueue.async { [weak self] in
      guard let self = self else { return }
      self.entries.append(entry)
      if self.entries.count > Constants.maxStoredEntries {
        self.entries.removeFirst(self.entries.count - Constants.maxStoredEntries)
      }
      self.saveToDisk()
      NSLog("🧠 HistoryLogger: Logged entry type=\(type.rawValue) (total=\(self.entries.count))")
    }
  }

  func exportRecentToTempFile(limit: Int = 50) -> URL? {
    var snapshot: [Entry] = []
    ioQueue.sync { snapshot = Array(entries.suffix(limit).reversed()) }

    let formatter = DateFormatter()
    formatter.dateFormat = Constants.dateFormat

    var lines: [String] = []
    lines.append("WhisperShortcut – Recent History (last \(snapshot.count))")
    lines.append("Generated: \(formatter.string(from: Date()))")
    lines.append(String(repeating: "-", count: 64))
    for (index, entry) in snapshot.enumerated() {
      let dateStr = formatter.string(from: entry.timestamp)
      lines.append("#\(index + 1) [\(entry.type.rawValue)] @ \(dateStr)")
      lines.append(entry.text)
      lines.append("")
    }
    let content = lines.joined(separator: "\n")

    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let fileURL = tempDir.appendingPathComponent(Constants.exportFilename)

    do {
      try content.write(to: fileURL, atomically: true, encoding: .utf8)
      NSLog("🧠 HistoryLogger: Exported recent history to \(fileURL.path)")
      return fileURL
    } catch {
      NSLog("🧠 HistoryLogger: Failed to export recent history – \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Persistence
  private func appSupportDirectory() -> URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let dir = base.appendingPathComponent(Constants.appSupportSubdirectory, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    } catch {
      NSLog("🧠 HistoryLogger: Failed to create app support directory – \(error.localizedDescription)")
      return nil
    }
  }

  private func historyFileURL() -> URL? {
    guard let dir = appSupportDirectory() else { return nil }
    return dir.appendingPathComponent(Constants.historyFilename)
  }

  private func saveToDisk() {
    guard let url = historyFileURL() else { return }
    do {
      let data = try JSONEncoder().encode(entries)
      try data.write(to: url, options: .atomic)
    } catch {
      NSLog("🧠 HistoryLogger: Failed to save – \(error.localizedDescription)")
    }
  }

  private func loadFromDisk() {
    guard let url = historyFileURL(), FileManager.default.fileExists(atPath: url.path) else {
      entries = []
      return
    }
    do {
      let data = try Data(contentsOf: url)
      let decoded = try JSONDecoder().decode([Entry].self, from: data)
      entries = decoded
      if entries.count > Constants.maxStoredEntries {
        entries = Array(entries.suffix(Constants.maxStoredEntries))
      }
      NSLog("🧠 HistoryLogger: Loaded \(entries.count) entries from disk")
    } catch {
      entries = []
      NSLog("🧠 HistoryLogger: Failed to load – \(error.localizedDescription)")
    }
  }
}


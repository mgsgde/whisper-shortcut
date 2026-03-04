import Foundation
import Combine

/// A single transcript chunk with timestamp (seconds from meeting start).
struct LiveMeetingChunk: Identifiable, Sendable {
  let id: UUID
  let startTime: TimeInterval
  let text: String

  init(id: UUID = UUID(), startTime: TimeInterval, text: String) {
    self.id = id
    self.startTime = startTime
    self.text = text
  }

  /// Display timestamp string, e.g. "[02:15]"
  var timestampString: String {
    let minutes = Int(startTime) / 60
    let seconds = Int(startTime) % 60
    return String(format: "[%02d:%02d]", minutes, seconds)
  }
}

/// In-memory store for live meeting transcript chunks. Used by the meeting window (live transcript panel)
/// and for building chat context (summary + last N minutes). Cleared when a new meeting starts.
final class LiveMeetingTranscriptStore: ObservableObject {
  static let shared = LiveMeetingTranscriptStore()

  /// Transcript chunks (newest appended). Bounded by `maxChunks` to limit RAM for long meetings.
  @Published private(set) var chunks: [LiveMeetingChunk] = []

  /// Rolling summary text, updated periodically during the meeting. Empty until first summary update.
  @Published private(set) var summary: String = ""

  /// True while a meeting is recording; false after session ends or before any meeting.
  @Published private(set) var isSessionActive: Bool = false

  /// Current transcript filename without extension (e.g. "Meeting-2026-03-04-201119"). Set by MenuBarController when recording starts; cleared when session ends. Used as default in "End Meeting" name dialog.
  @Published var currentMeetingFilenameStem: String?

  /// User-entered name for the current live meeting; used as pre-fill when ending the meeting. Cleared on new meeting or end session.
  @Published var preferredMeetingName: String?

  /// Max chunks to retain (oldest dropped). ~90 min at 15s chunks ≈ 360.
  private let maxChunks: Int = 500

  private let queue = DispatchQueue(label: "com.magnusgoedde.whispershortcut.liveMeetingStore", qos: .userInitiated)

  private init() {}

  /// Generates a timestamp-based filename stem (e.g. "Meeting-2026-03-04-201119").
  /// Used as the meeting's unique ID for both transcript files and chat store scope.
  static func generateStem() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return "Meeting-\(formatter.string(from: Date()))"
  }

  /// Call when a new meeting session starts. Clears previous data.
  /// Generates a stem if one was not already set (e.g. when starting via global shortcut without "New Meeting").
  func startSession() {
    queue.async { [weak self] in
      guard let self else { return }
      DispatchQueue.main.async {
        if self.currentMeetingFilenameStem == nil {
          self.currentMeetingFilenameStem = Self.generateStem()
        }
        self.chunks = []
        self.summary = ""
        self.isSessionActive = true
        DebugLogger.log("LIVE-MEETING-STORE: Session started, store cleared (stem: \(self.currentMeetingFilenameStem ?? "nil"))")
      }
    }
  }

  /// Append a transcribed chunk. Call from main thread or from the same place as appendToTranscript.
  func appendChunk(startTime: TimeInterval, text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }

    let chunk = LiveMeetingChunk(startTime: startTime, text: trimmed)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.chunks.append(chunk)
      if self.chunks.count > self.maxChunks {
        self.chunks.removeFirst(self.chunks.count - self.maxChunks)
      }
    }
  }

  /// Call when the meeting session ends. Keeps chunks, summary, and name so the meeting window can keep showing them.
  func endSession() {
    DispatchQueue.main.async { [weak self] in
      self?.isSessionActive = false
      DebugLogger.log("LIVE-MEETING-STORE: Session ended, data retained for display")
    }
  }

  /// Clears store for a new meeting without starting recording. Used when user taps "New Meeting".
  /// Generates a fresh stem so the meeting has a unique ID from the start (used as chat scope).
  func clearForNewMeeting() {
    let stem = Self.generateStem()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.chunks = []
      self.summary = ""
      self.isSessionActive = false
      self.currentMeetingFilenameStem = stem
      self.preferredMeetingName = nil
      DebugLogger.log("LIVE-MEETING-STORE: Cleared for new meeting (stem: \(stem))")
    }
  }

  /// Returns transcript text for chunks from the given index to the end. Used for rolling summary (merge new content).
  func chunkTexts(fromIndex startIndex: Int) -> String {
    guard startIndex >= 0, startIndex < chunks.count else { return "" }
    return chunks[startIndex...]
      .map { "\($0.timestampString) \($0.text)" }
      .joined(separator: "\n")
  }

  /// Returns transcript text for the last N minutes (by chunk startTime). Used for chat context.
  func lastMinutesTranscript(minutes: Int) -> String {
    let cutoff = chunks.last.map { $0.startTime - TimeInterval(minutes * 60) } ?? 0
    return chunks
      .filter { $0.startTime >= cutoff }
      .map { "\($0.timestampString) \($0.text)" }
      .joined(separator: "\n")
  }

  /// Context string for the meeting chat system instruction: summary (if any) plus recent transcript. Call on main thread.
  func meetingContextForChat(lastMinutes: Int = 5) -> String {
    var parts: [String] = []
    if !summary.isEmpty {
      parts.append("Current meeting summary:\n\(summary)")
    }
    let recent = lastMinutesTranscript(minutes: lastMinutes)
    if !recent.isEmpty {
      parts.append("Recent transcript (last \(lastMinutes) minutes):\n\(recent)")
    }
    if parts.isEmpty {
      return ""
    }
    return "Use the following meeting context to answer the user's questions.\n\n" + parts.joined(separator: "\n\n")
  }

  /// Snapshot of current chunks (e.g. for display after session ended). Returns a copy.
  func snapshotChunks() -> [LiveMeetingChunk] {
    chunks
  }

  /// Update the rolling summary (called after a Gemini merge). Main thread.
  func updateSummary(_ newSummary: String) {
    assert(Thread.isMainThread)
    summary = newSummary
  }
}

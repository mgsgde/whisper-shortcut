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

/// One append-only live note: what happened in one segment of the meeting, as 1–2 short bullets.
///
/// Notes are never rewritten — each covers a fixed span of transcript and is appended once. That is
/// the whole point: the old rolling summary re-generated the *entire* summary on every update, which
/// cost more the longer the meeting ran, took 60–100 s per call, and quietly drifted as the model
/// re-wrote its own earlier wording. Appending is O(1) per segment, reads chronologically, and can
/// therefore be shown inline in the chat as "what has been discussed".
struct LiveMeetingNote: Identifiable, Sendable {
  let id: UUID
  /// Elapsed seconds from meeting start of the first chunk this note covers.
  let startTime: TimeInterval
  let bullets: [String]
  /// True for a marker the user set by hotkey during the meeting, false for a generated note.
  let isMarker: Bool

  init(id: UUID = UUID(), startTime: TimeInterval, bullets: [String], isMarker: Bool = false) {
    self.id = id
    self.startTime = startTime
    self.bullets = bullets
    self.isMarker = isMarker
  }

  var timestampString: String {
    let minutes = Int(startTime) / 60
    let seconds = Int(startTime) % 60
    return String(format: "[%02d:%02d]", minutes, seconds)
  }

  /// Plain-text rendering used for chat context and for the clipboard.
  var plainText: String {
    bullets.map { "\(timestampString) \($0)" }.joined(separator: "\n")
  }
}

/// In-memory store for live meeting transcript chunks and live notes. Used by the meeting view and
/// for building chat context (live notes + full transcript). Cleared when a new meeting starts.
final class LiveMeetingTranscriptStore: ObservableObject {
  static let shared = LiveMeetingTranscriptStore()

  /// Transcript chunks (newest appended). Bounded by `maxChunks` to limit RAM for long meetings.
  @Published private(set) var chunks: [LiveMeetingChunk] = []

  /// Append-only live notes for the running meeting, oldest first.
  @Published private(set) var liveNotes: [LiveMeetingNote] = []

  /// Final summary text of an ended (or rehydrated) meeting. No longer written during recording —
  /// `liveNotes` covers the live case, and writing a partial summary to `.summary.md` mid-meeting
  /// used to defeat the "regenerate when the summary file is missing" recovery path.
  @Published private(set) var summary: String = ""

  /// True while a meeting is recording; false after session ends or before any meeting.
  @Published private(set) var isSessionActive: Bool = false

  /// True between "stop this meeting" and the session actually being finished. Stopping has to drain
  /// the last chunk through a transcription round trip, so it is not instant; a UI that only knows
  /// `isSessionActive` shows "Recording" for those seconds and the stop looks like it did nothing.
  @Published private(set) var isFinishing: Bool = false

  /// Cuts the audio still sitting in the recorder and waits briefly for its transcript. Installed by
  /// `MenuBarController`, which owns the session; nil in previews and tests. The meeting chat calls it
  /// before a turn goes out so a question about the last few seconds can be answered from them.
  var pendingAudioFlush: (@MainActor () async -> Void)?

  /// Current transcript filename without extension (e.g. "Meeting-2026-03-04-201119"). Set by MenuBarController when recording starts; cleared when session ends. Used as default in "End Meeting" name dialog.
  @Published var currentMeetingFilenameStem: String?

  /// User-entered name for the current live meeting; used as pre-fill when ending the meeting. Cleared on new meeting or end session.
  @Published var preferredMeetingName: String?

  /// Max chunks to retain (oldest dropped). At 60s chunks with dual-source, ~250 min of meeting.
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
  /// Must be called on the main thread (state mutations are synchronous so callers can read
  /// `currentMeetingFilenameStem` immediately after this returns, avoiding stem races).
  func startSession() {
    assert(Thread.isMainThread, "LiveMeetingTranscriptStore.startSession must be called on main thread")
    if self.currentMeetingFilenameStem == nil {
      self.currentMeetingFilenameStem = Self.generateStem()
    }
    self.chunks = []
    self.liveNotes = []
    self.summary = ""
    self.isSessionActive = true
    self.isFinishing = false
    DebugLogger.log("LIVE-MEETING-STORE: Session started, store cleared (stem: \(self.currentMeetingFilenameStem ?? "nil"))")
  }

  /// Resume a previously stopped session. Keeps existing chunks and summary.
  /// Must be called on the main thread (synchronous so the stem is stable when callers
  /// read `currentMeetingFilenameStem` immediately after).
  func resumeSession() {
    assert(Thread.isMainThread, "LiveMeetingTranscriptStore.resumeSession must be called on main thread")
    self.isSessionActive = true
    self.isFinishing = false
    DebugLogger.log("LIVE-MEETING-STORE: Session resumed, data retained (stem: \(self.currentMeetingFilenameStem ?? "nil"), chunks: \(self.chunks.count))")
  }

  /// Re-loads a previously-ended meeting's stem, transcript chunks, and summary into the
  /// store so resuming genuinely continues THAT meeting: the correct file is appended to,
  /// the prior transcript stays visible, and new chunks' timestamps continue monotonically.
  /// Call on the main thread before `startLiveMeeting(resuming:)`.
  func rehydrateForResume(
    stem: String, chunks: [LiveMeetingChunk], summary: String, notes: [LiveMeetingNote]
  ) {
    assert(Thread.isMainThread, "LiveMeetingTranscriptStore.rehydrateForResume must be called on main thread")
    self.currentMeetingFilenameStem = stem
    self.chunks = chunks
    self.summary = summary
    self.liveNotes = notes
    DebugLogger.log(
      "LIVE-MEETING-STORE: Rehydrated for resume (stem: \(stem), chunks: \(chunks.count), notes: \(notes.count))")
  }

  /// Matches a "[mm:ss]" timestamp marker (minutes may exceed two digits for long meetings).
  private static let timestampRegex = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2})\]"#)

  /// Parses a transcript file (as written by `appendToTranscript`: "[mm:ss] text" blocks
  /// separated by blank lines) back into chunks. Used to rehydrate a resumed meeting.
  static func parseTranscript(_ text: String) -> [LiveMeetingChunk] {
    let ns = text as NSString
    let matches = timestampRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    var result: [LiveMeetingChunk] = []
    for (i, m) in matches.enumerated() {
      let minutes = Int(ns.substring(with: m.range(at: 1))) ?? 0
      let seconds = Int(ns.substring(with: m.range(at: 2))) ?? 0
      let start = TimeInterval(minutes * 60 + seconds)
      let bodyStart = m.range.location + m.range.length
      let bodyEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
      let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !body.isEmpty {
        result.append(LiveMeetingChunk(startTime: start, text: body))
      }
    }
    return result
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

  /// Call when the user asks to stop: recording has ended but the session is still draining its last
  /// chunk. `isSessionActive` stays true — the meeting is not over yet — so the UI can say
  /// "finishing" instead of either lying about recording or claiming the meeting has ended.
  func beginFinishing() {
    if Thread.isMainThread {
      self.isFinishing = true
    } else {
      DispatchQueue.main.async { [weak self] in self?.isFinishing = true }
    }
    DebugLogger.log("LIVE-MEETING-STORE: Finishing (draining last chunk)")
  }

  /// Call when the meeting session ends. Keeps chunks, summary, and name so the meeting window can keep showing them.
  func endSession() {
    if Thread.isMainThread {
      self.isSessionActive = false
      self.isFinishing = false
      DebugLogger.log("LIVE-MEETING-STORE: Session ended, data retained for display")
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.isSessionActive = false
        self?.isFinishing = false
        DebugLogger.log("LIVE-MEETING-STORE: Session ended, data retained for display")
      }
    }
  }

  /// Bridges the meeting chat to the running session's audio flush. No-op when nothing is recording.
  @MainActor
  func flushPendingAudio() async {
    await pendingAudioFlush?()
  }

  /// Clears store for a new meeting without starting recording. Used when user taps "New Meeting".
  /// Generates a fresh stem so the meeting has a unique ID from the start (used as chat scope).
  /// Must be called on the main thread so the new stem is visible to the next
  /// `startSession` / `createTranscriptFile` call synchronously (avoids stem races).
  func clearForNewMeeting() {
    assert(Thread.isMainThread, "LiveMeetingTranscriptStore.clearForNewMeeting must be called on main thread")
    let stem = Self.generateStem()
    self.chunks = []
    self.liveNotes = []
    self.summary = ""
    self.isSessionActive = false
    self.isFinishing = false
    self.currentMeetingFilenameStem = stem
    self.preferredMeetingName = nil
    DebugLogger.log("LIVE-MEETING-STORE: Cleared for new meeting (stem: \(stem))")
  }

  /// Returns the chunks appearing strictly after the chunk with the given ID. If `afterID` is nil
  /// or no longer present (chunk trimming), returns everything.
  func chunks(afterID: UUID?) -> [LiveMeetingChunk] {
    guard !chunks.isEmpty else { return [] }
    guard let afterID, let i = chunks.firstIndex(where: { $0.id == afterID }) else { return chunks }
    guard i + 1 < chunks.count else { return [] }
    return Array(chunks[(i + 1)...])
  }

  /// The whole transcript accumulated so far, timestamped.
  func fullTranscriptText() -> String {
    chunks.map { "\($0.timestampString) \($0.text)" }.joined(separator: "\n")
  }

  /// Elapsed meeting time covered by the transcript, in seconds.
  var elapsedSeconds: TimeInterval { chunks.last?.startTime ?? 0 }

  /// Context string for the meeting chat system instruction: the live notes plus the FULL transcript.
  ///
  /// This used to be "rolling summary + last 5 minutes", which meant the chat could not answer
  /// "what did we say about X earlier?" while the meeting was still running — the only thing it knew
  /// about the first hour was whatever survived into a lossy summary. A 90-minute meeting is on the
  /// order of 10–15k tokens, so the whole thing fits comfortably; `meetingContextMaxChars` still
  /// bounds pathological cases by keeping the most recent text. Call on main thread.
  func meetingContextForChat() -> String {
    var parts: [String] = []
    if !liveNotes.isEmpty {
      let notes = liveNotes.map { $0.plainText }.joined(separator: "\n")
      parts.append("Live notes taken so far (chronological):\n\(notes)")
    }
    var transcript = fullTranscriptText()
    if transcript.count > MeetingListService.meetingContextMaxChars {
      transcript = String(transcript.suffix(MeetingListService.meetingContextMaxChars))
    }
    if !transcript.isEmpty {
      parts.append("Full transcript of the meeting so far:\n\(transcript)")
    }
    if parts.isEmpty {
      return ""
    }
    return """
      This chat is attached to a meeting that is being transcribed live. Everything said so far is \
      below — answer the user's questions from it, and quote timestamps like [12:34] when it helps \
      them find the moment.

      """ + parts.joined(separator: "\n\n")
  }

  // MARK: - Live notes

  /// Appends one generated note. Main thread.
  func appendNote(_ note: LiveMeetingNote) {
    assert(Thread.isMainThread)
    liveNotes.append(note)
  }

  /// Appends a user marker and returns it. Pass the recorder's live elapsed time when available —
  /// `elapsedSeconds` only knows about transcribed chunks and so trails the actual moment by up to
  /// one chunk. Notes stay sorted because a marker is always at or after the newest chunk.
  /// Main thread.
  @discardableResult
  func appendMarker(text: String, at elapsed: TimeInterval? = nil) -> LiveMeetingNote {
    assert(Thread.isMainThread)
    let startTime = max(elapsed ?? elapsedSeconds, elapsedSeconds)
    let note = LiveMeetingNote(startTime: startTime, bullets: [text], isMarker: true)
    liveNotes.append(note)
    return note
  }

  /// Markers the user set since the given note, used to bias the final summary.
  var markerTexts: [String] {
    liveNotes.filter { $0.isMarker }.flatMap { $0.bullets }
  }

  // MARK: - Live notes serialization
  //
  // Notes live next to the transcript as a plain `.notes.md` file so they survive an app restart,
  // a resumed meeting, and reopening the meeting weeks later — and so the folder stays readable
  // without the app.

  /// Renders notes as the Markdown persisted in `<stem>.notes.md`.
  static func notesMarkdown(_ notes: [LiveMeetingNote]) -> String {
    notes.map { note in
      let header = note.isMarker ? "## ★ \(note.timestampString)" : "## \(note.timestampString)"
      let body = note.bullets.map { "- \($0)" }.joined(separator: "\n")
      return "\(header)\n\(body)"
    }.joined(separator: "\n\n") + "\n"
  }

  private static let noteHeaderRegex = try! NSRegularExpression(
    pattern: #"^##\s+(★\s+)?\[(\d+):(\d{2})\]\s*$"#)

  /// Parses a `.notes.md` file back into notes. Unrecognized lines are ignored.
  static func parseNotes(_ text: String) -> [LiveMeetingNote] {
    var result: [LiveMeetingNote] = []
    var currentStart: TimeInterval? = nil
    var currentIsMarker = false
    var currentBullets: [String] = []

    func flush() {
      guard let start = currentStart, !currentBullets.isEmpty else { return }
      result.append(
        LiveMeetingNote(startTime: start, bullets: currentBullets, isMarker: currentIsMarker))
      currentBullets = []
    }

    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      let range = NSRange(line.startIndex..., in: line)
      if let match = noteHeaderRegex.firstMatch(in: line, range: range) {
        flush()
        let markerRange = match.range(at: 1)
        currentIsMarker = markerRange.location != NSNotFound
        let minutes = Range(match.range(at: 2), in: line).flatMap { Int(line[$0]) } ?? 0
        let seconds = Range(match.range(at: 3), in: line).flatMap { Int(line[$0]) } ?? 0
        currentStart = TimeInterval(minutes * 60 + seconds)
      } else if line.hasPrefix("- "), currentStart != nil {
        let bullet = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if !bullet.isEmpty { currentBullets.append(bullet) }
      }
    }
    flush()
    return result
  }

}
